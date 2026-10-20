/// Transport layer for the Serverpod Insights service protocol.
///
/// Wraps the generated `Client` from `serverpod_service_client` 4.0.4 and adds:
///
/// * service-secret authentication through `ServiceAuthKeyProvider`
///   (`Authorization: Bearer <name>:<secret>`);
/// * strict base-URL validation: `https://` anywhere, `http://` only on
///   loopback, no credentials, query or fragment in the URL;
/// * redirects disabled at the HTTP layer, so a 3xx response can never replay
///   the service secret to another host;
/// * bounded session-log paging: `getSessionLog` is never called with a null
///   `numEntries`, because the server treats null as "no limit";
/// * error messages that never contain the secret or a URL with user info.
///
/// Only four Insights endpoints are used: `getRuntimeSettings`,
/// `setRuntimeSettings`, `getSessionLog` and `getHealthData`. Destructive
/// endpoints (`clearAllLogs`, `executeSql`, `runQueries`, bulk data export) are
/// intentionally not exposed here.
library;

import 'dart:async';
import 'dart:io' show IOException;

// `serverpod_service_client` re-exports the generated client and the protocol
// models, but not the client-side exception types, which are needed to turn
// transport failures into stable, secret-free messages. `serverpod_client` is a
// direct dependency pinned to 4.0.4, the same version the service client uses.
import 'package:http/http.dart' as http;
import 'package:serverpod_client/serverpod_client.dart' as spc;
import 'package:serverpod_service_client/serverpod_service_client.dart' as sp;

/// Name part of the `Bearer <name>:<secret>` service key.
///
/// The server ignores this name (it splits the decoded key on `:` and compares
/// only the second part against the configured `serviceSecret`), but the key
/// must contain the colon, so a non-empty name is required.
const String _serviceKeyName = 'insights-linux';

const int _minLogPageSize = 1;
const int _maxLogPageSize = 500;

const Duration _requestTimeout = Duration(seconds: 20);

/// Error raised by [InsightsApi] with a message safe to show in the UI.
///
/// It never carries the service secret, the full request URL or raw server
/// payloads.
class InsightsApiException implements Exception {
  /// Creates a new [InsightsApiException].
  InsightsApiException(this.message);

  /// Human readable, secret-free description of the failure.
  final String message;

  @override
  String toString() => 'InsightsApiException: $message';
}

/// Thin, validated client for a single Serverpod Insights server.
///
/// Every network method lazily calls [connect] when needed, so an explicit
/// [connect] is optional; call it early to surface configuration errors before
/// the first screen is rendered.
class InsightsApi {
  /// Validates [url] and [secret] eagerly and stores them for [connect].
  ///
  /// Throws [InsightsApiException] with a fixed, secret-free message when the
  /// URL or the secret cannot be used. The rejected value is never echoed.
  InsightsApi(String url, String secret)
    : _baseUrl = _normalizeBaseUrl(url),
      _secret = _validateSecret(secret);

  final String _baseUrl;
  final String _secret;

  sp.Client? _client;
  Future<void>? _connecting;
  bool _closed = false;

  /// True once [connect] succeeded and before [close].
  bool get isConnected => _client != null;

  /// Creates the underlying client and verifies the service secret.
  ///
  /// The handshake is a read-only `getRuntimeSettings` call: a wrong secret
  /// surfaces as [InsightsApiException] immediately instead of on the first
  /// real request. Calling this method again is a no-op.
  Future<void> connect() async {
    _ensureOpen();
    if (_client != null) return;

    final pending = _connecting;
    if (pending != null) {
      await pending;
      return;
    }

    final future = _connect();
    _connecting = future;
    try {
      await future;
    } finally {
      if (identical(_connecting, future)) _connecting = null;
    }
  }

  /// Reads the newest session logs, newest first.
  ///
  /// Rows are ordered by the server as `SessionLogEntry.id` descending, so new
  /// sessions arriving between two pages never shift an older page.
  ///
  /// [limit] is the page size and must stay within 1..500. It is always sent
  /// explicitly because the server maps a null `numEntries` to "no limit" and
  /// would return the whole session log table in one response.
  ///
  /// [beforeId] is the exact paging cursor and the recommended way to load the
  /// next page: pass the `sessionLogEntry.id` of the oldest row currently
  /// displayed. The server applies `id < beforeId` (strictly older), so no row
  /// is repeated or skipped, even when several sessions share the same start
  /// time.
  ///
  /// [before] is the legacy time cursor, kept for callers that only store the
  /// timestamp: it becomes an exclusive upper bound on the session start time
  /// (`time < before`). Sessions that started at exactly that instant and did
  /// not fit into the previous page are skipped, so prefer [beforeId]. The two
  /// cursors are mutually exclusive and must not be combined.
  ///
  /// [endpoint] restricts the page to one endpoint name; an empty or blank
  /// value means "any endpoint". [errorsOnly] keeps only sessions that ended
  /// with an exception (`SessionLogFilter.error`).
  ///
  /// Returns the wire JSON of `SessionLogResult.sessionLog`, i.e. a list of
  /// `serverpod.SessionLogInfo` maps with `sessionLogEntry`, `queries`, `logs`
  /// and `messages`.
  Future<List<Map<String, dynamic>>> logs({
    int limit = 100,
    DateTime? before,
    int? beforeId,
    String? endpoint,
    bool errorsOnly = false,
  }) async {
    if (limit < _minLogPageSize || limit > _maxLogPageSize) {
      throw InsightsApiException(
        'The log page size must be between $_minLogPageSize and '
        '$_maxLogPageSize.',
      );
    }
    if (before != null && beforeId != null) {
      throw InsightsApiException(
        'Pass either the "before" timestamp or the "beforeId" cursor, '
        'not both.',
      );
    }
    if (beforeId != null && beforeId < 1) {
      throw InsightsApiException('The "beforeId" log cursor is invalid.');
    }

    final client = await _ensureClient();
    final filter = sp.SessionLogFilter(
      endpoint: _normalizeOptionalText(endpoint),
      slow: false,
      error: errorsOnly,
      open: false,
      lastSessionLogId: beforeId,
      endTime: before?.toUtc(),
    );

    final result = await _guard(
      () => client.insights.getSessionLog(limit, filter),
      'load session logs',
    );

    return [for (final sessionLog in result.sessionLog) sessionLog.toJson()];
  }

  /// Reads stored health metrics for `[start, end]` (inclusive on both ends).
  ///
  /// The server applies `timestamp >= start AND timestamp <= end` and returns
  /// every stored sample, without a limit, so keep the window bounded in the
  /// UI (for example one day or less per request). The result is the wire JSON
  /// of `serverpod.ServerHealthResult` with `metrics` and `connectionInfos`.
  Future<Map<String, dynamic>> health(DateTime start, DateTime end) async {
    if (!start.isBefore(end)) {
      throw InsightsApiException(
        'The health window must start before it ends.',
      );
    }

    final client = await _ensureClient();
    final result = await _guard(
      () => client.insights.getHealthData(start.toUtc(), end.toUtc()),
      'load health data',
    );

    return result.toJson();
  }

  /// Reads the current runtime settings.
  ///
  /// Returns the wire JSON of `serverpod.RuntimeSettings`:
  /// `id`, `logSettings`, `logSettingsOverrides`, `logServiceCalls`,
  /// `logMalformedCalls`. The server reloads the settings from the database
  /// before answering.
  Future<Map<String, dynamic>> runtimeSettings() async {
    final client = await _ensureClient();
    final settings = await _guard(
      () => client.insights.getRuntimeSettings(),
      'load runtime settings',
    );

    return settings.toJson();
  }

  /// Writes runtime settings through `setRuntimeSettings`.
  ///
  /// [json] must be the map returned by [runtimeSettings] (or the same shape):
  /// it must contain `logSettings`, `logSettingsOverrides`, `logServiceCalls`
  /// and `logMalformedCalls`. The server applies the log settings immediately
  /// and persists the whole object, so always send a full object, never a
  /// patch. Prefer editing the map returned by [runtimeSettings] over building
  /// one from scratch.
  Future<void> saveRuntimeSettings(Map<String, dynamic> json) async {
    final payload = Map<String, dynamic>.from(json);
    for (final key in const [
      'logSettings',
      'logSettingsOverrides',
      'logServiceCalls',
      'logMalformedCalls',
    ]) {
      if (!payload.containsKey(key)) {
        throw InsightsApiException(
          'The runtime settings payload is incomplete: missing "$key".',
        );
      }
    }

    final sp.RuntimeSettings settings;
    try {
      settings = sp.RuntimeSettings.fromJson(payload);
    } on Object {
      throw InsightsApiException(
        'The runtime settings payload has an unsupported shape. '
        'Pass the map returned by runtimeSettings().',
      );
    }

    final client = await _ensureClient();
    await _guard(
      () => client.insights.setRuntimeSettings(settings),
      'save runtime settings',
    );
  }

  /// Closes the HTTP client and marks this instance as unusable.
  ///
  /// Calling it twice, or before [connect], is safe.
  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close();
    _client = null;
  }

  Future<void> _connect() async {
    final client = sp.Client(
      _baseUrl,
      connectionTimeout: _requestTimeout,
      httpClientOverride: _NoRedirectClient(http.Client()),
    );
    client.authKeyProvider = sp.ServiceAuthKeyProvider.withServiceSecret(
      _serviceKeyName,
      _secret,
    );

    try {
      // Read-only handshake: proves the secret is accepted before any other
      // request is attempted.
      await _guard(client.insights.getRuntimeSettings, 'authenticate');
    } catch (_) {
      client.close();
      rethrow;
    }

    if (_closed) {
      client.close();
      throw StateError('InsightsApi was closed during connect().');
    }

    _client = client;
  }

  Future<sp.Client> _ensureClient() async {
    _ensureOpen();
    final client = _client;
    if (client != null) return client;
    await connect();
    return _client!;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('InsightsApi is closed.');
    }
  }

  Future<T> _guard<T>(Future<T> Function() request, String action) async {
    try {
      return await request();
    } on spc.ServerpodClientUnauthorized {
      throw InsightsApiException(
        'Authentication failed while trying to $action. '
        'Check the service secret.',
      );
    } on spc.ServerpodClientForbidden {
      throw InsightsApiException(
        'The server denied access while trying to $action.',
      );
    } on spc.ServerpodClientNotFound {
      throw InsightsApiException(
        'The Insights endpoint was not found while trying to $action. '
        'Check the URL and that the Insights server is enabled.',
      );
    } on spc.ServerpodClientBadRequest {
      throw InsightsApiException(
        'The server rejected the request while trying to $action.',
      );
    } on spc.ServerpodClientHttpException catch (error) {
      if (error.statusCode >= 300 && error.statusCode < 400) {
        // Redirects are disabled in [_NoRedirectClient]; the response is
        // surfaced as an error instead of being followed with the secret.
        throw InsightsApiException(
          'The Insights server tried to redirect the request while trying to '
          '$action. Redirects are not allowed.',
        );
      }
      throw InsightsApiException(
        'The server answered HTTP ${error.statusCode} while trying to $action.',
      );
    } on spc.ServerpodClientNetworkException {
      throw InsightsApiException(
        'Could not reach the Insights server while trying to $action. '
        'Check the host, the port, the TLS certificate and that the server '
        'is running.',
      );
    } on spc.ServerpodClientException {
      throw InsightsApiException(
        'Unexpected response from the Insights server while trying to $action.',
      );
    } on IOException {
      throw InsightsApiException(
        'Network or TLS failure while trying to $action. Check the host, the '
        'port and the server certificate.',
      );
    } on TimeoutException {
      throw InsightsApiException(
        'The Insights server did not answer in time while trying to $action.',
      );
    } on Exception catch (error) {
      throw InsightsApiException(
        'Unexpected ${error.runtimeType} while trying to $action.',
      );
    } on Error catch (error) {
      // Protocol mismatches surface as TypeError; keep the type, drop details.
      throw InsightsApiException(
        'Internal error (${error.runtimeType}) while trying to $action.',
      );
    }
  }
}

/// Validates the base URL and returns it with a trailing slash so that the
/// generated client can append `insights/<method>`.
///
/// Every rejection uses a fixed message: the raw URL is never echoed back,
/// because it may contain credentials or internal host names.
String _normalizeBaseUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    throw InsightsApiException('The Insights server URL is empty.');
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw InsightsApiException(
      'The Insights server URL must be absolute, for example '
      'https://host:8080/.',
    );
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') {
    throw InsightsApiException(
      'The Insights server URL must use https://; http:// is allowed only on '
      'loopback.',
    );
  }

  if (uri.userInfo.isNotEmpty) {
    throw InsightsApiException(
      'The Insights server URL must not contain credentials '
      '(user:password@).',
    );
  }

  if (uri.hasQuery || uri.hasFragment) {
    throw InsightsApiException(
      'The Insights server URL must not contain a query string or a fragment.',
    );
  }

  if (scheme == 'http' && !_isLoopbackHost(uri.host)) {
    throw InsightsApiException(
      'Plain http:// is allowed only for 127.0.0.1, ::1 or localhost.',
    );
  }

  if (uri.pathSegments.any((segment) => segment == '.' || segment == '..')) {
    throw InsightsApiException(
      'The Insights server URL must not contain "." or ".." path segments.',
    );
  }

  final path = uri.path.isEmpty
      ? '/'
      : (uri.path.endsWith('/') ? uri.path : '${uri.path}/');

  return uri.replace(path: path).toString();
}

/// Validates the service secret before it is placed into an HTTP header.
///
/// Serverpod disables the Insights server unless the configured
/// `serviceSecret` is longer than 20 characters. The value must also be a
/// single printable ASCII token: the server splits the decoded key on `:` and
/// takes the second part, and a header value cannot contain spaces or control
/// characters.
///
/// Every rejection uses a fixed message and never echoes the secret.
String _validateSecret(String rawSecret) {
  final secret = rawSecret.trim();

  if (secret.isEmpty) {
    throw InsightsApiException('The service secret is empty.');
  }

  if (secret.length <= 20) {
    throw InsightsApiException(
      'The service secret must be longer than 20 characters, otherwise the '
      'server disables the Insights server.',
    );
  }

  if (secret.contains(':')) {
    throw InsightsApiException(
      'The service secret must not contain ":", the server would truncate it.',
    );
  }

  if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(secret)) {
    throw InsightsApiException(
      'The service secret must be printable ASCII without spaces or control '
      'characters.',
    );
  }

  return secret;
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]';
}

String? _normalizeOptionalText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// `http.Client` wrapper that refuses to follow redirects.
///
/// The Serverpod request delegate has no redirect switch, and every request
/// carries the service secret in the `Authorization` header. Passing this
/// client through `httpClientOverride` turns a 3xx response into a plain error
/// response, so the secret is never replayed to a `Location` target.
class _NoRedirectClient extends http.BaseClient {
  _NoRedirectClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
