import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/insights_api.dart';
import 'core/keyring.dart';

final appProvider = Provider<AppController>((ref) {
  final app = AppController();
  ref.onDispose(app.dispose);
  unawaited(app.initialize());
  return app;
});

class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.url,
    required this.rememberSecret,
  });
  final String id;
  final String name;
  final String url;
  final bool rememberSecret;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'rememberSecret': rememberSecret,
  };
  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      ConnectionProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        rememberSecret: json['rememberSecret'] == true,
      );
}

class AppController extends ChangeNotifier {
  final SecretVault _vault = SecretVault();
  final Map<String, String> _sessionSecrets = {};
  SharedPreferences? _prefs;
  InsightsApi? _api;
  Timer? _timer;
  bool _disposed = false;
  int _generation = 0;
  int get connectionEpoch => _generation;
  bool initialized = false;
  bool busy = false;
  bool refreshing = false;
  bool connected = false;
  bool autoRefresh = false;
  bool dark = false;
  String? error;
  String? storageError;
  DateTime? lastUpdated;
  ConnectionProfile? active;
  List<ConnectionProfile> profiles = [];
  List<Map<String, dynamic>> sessions = [];
  Map<String, dynamic>? healthData;
  Map<String, dynamic>? settings;
  bool exhausted = false;
  String endpoint = '';
  bool errorsOnly = false;
  String search = '';

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final values = jsonDecode(
        _prefs!.getString('insights.connections.v1') ?? '[]',
      ) as List;
      profiles = values
          .map(
            (e) =>
                ConnectionProfile.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      dark = _prefs!.getBool('insights.dark') ?? false;
    } catch (_) {
      storageError = 'Не удалось прочитать настройки. Сохранённые данные не перезаписаны. Перезапустите приложение или проверьте каталог настроек.';
    }
    initialized = true;
    _emit();
  }

  Future<void> _saveProfiles(List<ConnectionProfile> next) async {
    if (storageError != null || _prefs == null) {
      throw StateError(
        'Хранилище настроек недоступно. Подключения не сохранены.',
      );
    }
    final ok = await _prefs!.setString(
      'insights.connections.v1',
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
    if (!ok) throw StateError('Не удалось сохранить список подключений.');
    profiles = next;
  }

  Future<ConnectionProfile> addProfile(
    String name,
    String url,
    String secret,
    bool remember, {
    String? profileId,
  }) async {
    // Constructing the service validates the address without sending credentials.
    final probe = InsightsApi(url.trim(), secret);
    probe.close();
    if (name.trim().isEmpty || secret.isEmpty) {
      throw StateError('Укажите название и сервисный секрет.');
    }
    final id = profileId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final p = ConnectionProfile(
      id: id,
      name: name.trim(),
      url: url.trim(),
      rememberSecret: remember,
    );
    if (remember) await _vault.put(id, secret);
    try {
      await _saveProfiles([...profiles, p]);
    } catch (original) {
      if (remember) {
        try {
          await _vault.remove(id);
        } catch (_) {
          throw StateError(
            '${safeError(original)} Запись секрета не удалось удалить; проверьте запись Insights Linux в системной связке ключей.',
          );
        }
      }
      rethrow;
    }
    _sessionSecrets[id] = secret;
    _emit();
    return p;
  }

  Future<void> removeProfile(ConnectionProfile p) async {
    if (p.rememberSecret) await _vault.remove(p.id);
    await _saveProfiles(profiles.where((e) => e.id != p.id).toList());
    _sessionSecrets.remove(p.id);
    if (active?.id == p.id) disconnect();
    _emit();
  }

  Future<void> connect(
    ConnectionProfile p, {
    String? enteredSecret,
    bool persistEnteredSecret = false,
  }) async {
    if (busy) return;
    disconnect();
    active = p;
    final generation = _generation;
    busy = true;
    error = null;
    _emit();
    InsightsApi? candidate;
    try {
      final secret =
          enteredSecret ??
          _sessionSecrets[p.id] ??
          (p.rememberSecret ? await _vault.get(p.id) : null);
      if (_disposed || generation != _generation) return;
      if (secret == null || secret.isEmpty) {
        throw StateError(
          'Нужен сервисный секрет. Выберите «Ввести секрет и подключиться».',
        );
      }
      candidate = InsightsApi(p.url, secret);
      await candidate.connect();
      if (enteredSecret != null &&
          persistEnteredSecret &&
          p.rememberSecret &&
          generation == _generation &&
          !_disposed) {
        await _vault.put(p.id, secret);
      }
      if (_disposed || generation != _generation) {
        candidate.close();
        return;
      }
      _api = candidate;
      _sessionSecrets[p.id] = secret;
      connected = true;
      busy = false;
      _emit();
      await refresh();
    } catch (e) {
      candidate?.close();
      if (generation == _generation && !_disposed) {
        error = safeError(e);
        connected = false;
      }
    } finally {
      if (generation == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  void disconnect() {
    _generation++;
    _api?.close();
    _api = null;
    connected = false;
    busy = false;
    refreshing = false;
    sessions = [];
    healthData = null;
    settings = null;
    lastUpdated = null;
    exhausted = false;
    setAutoRefresh(false);
    _emit();
  }

  Future<void> refresh({bool older = false}) async {
    final api = _api;
    if (api == null || refreshing || !connected) return;
    final generation = _generation;
    refreshing = true;
    error = null;
    _emit();
    try {
      int? beforeId;
      if (older && sessions.isNotEmpty) {
        final entry = sessions.last['sessionLogEntry'] as Map?;
        beforeId = entry?['id'] as int?;
        if (beforeId == null) {
          throw StateError(
            'Сервер не вернул ID последней сессии. Дозагрузка недоступна.',
          );
        }
      }
      final logs = await api.logs(
        beforeId: beforeId,
        endpoint: endpoint.isEmpty ? null : endpoint,
        errorsOnly: errorsOnly,
      );
      if (_disposed || generation != _generation) return;
      final merged = older ? [...sessions, ...logs] : logs;
      final seen = <String>{};
      sessions = merged.where((e) {
        final s = e['sessionLogEntry'] as Map? ?? {};
        return seen.add('${s['id'] ?? jsonEncode(s)}');
      }).toList();
      exhausted = older
          ? sessions.length == merged.length - logs.length || logs.length < 100
          : logs.length < 100;
      lastUpdated = DateTime.now();
      if (!older) {
        final now = DateTime.now().toUtc();
        // Independent sections retain successful data even if another read fails.
        try {
          final data = await api.health(
            now.subtract(const Duration(hours: 1)),
            now,
          );
          if (generation == _generation && !_disposed) healthData = data;
        } catch (e) {
          if (generation == _generation) error = 'Метрики: ${safeError(e)}';
        }
        try {
          final data = await api.runtimeSettings();
          if (generation == _generation && !_disposed) settings = data;
        } catch (e) {
          if (generation == _generation) error = 'Настройки: ${safeError(e)}';
        }
      }
    } catch (e) {
      if (generation == _generation && !_disposed) error = safeError(e);
    } finally {
      if (generation == _generation) {
        refreshing = false;
        _emit();
      }
    }
  }

  Future<bool> saveSettings(Map<String, dynamic> next) async {
    final api = _api;
    if (api == null || !connected || refreshing) {
      throw StateError(
        'Сохранение не начато: соединение изменилось или выполняется другой запрос. Повторите после обновления.',
      );
    }
    final generation = _generation;
    refreshing = true;
    error = null;
    _emit();
    try {
      await api.saveRuntimeSettings(next);
      final data = await api.runtimeSettings();
      if (generation != _generation || _disposed) return false;
      settings = data;
      return true;
    } catch (e) {
      if (generation == _generation) {
        error =
            'Не удалось подтвердить сохранение. Настройки могли примениться; обновите их перед повтором. ${safeError(e)}';
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        refreshing = false;
        _emit();
      }
    }
  }

  void setAutoRefresh(bool value) {
    autoRefresh = value && connected;
    _timer?.cancel();
    _timer = autoRefresh
        ? Timer.periodic(
            const Duration(seconds: 10),
            (_) => unawaited(refresh()),
          )
        : null;
    _emit();
  }

  void setSearch(String value) {
    search = value;
    _emit();
  }

  void setFilters(String value, bool onlyErrors) {
    if (refreshing || !connected) return;
    endpoint = value.trim();
    errorsOnly = onlyErrors;
    exhausted = false;
    unawaited(refresh());
  }

  void toggleTheme() {
    dark = !dark;
    unawaited(_saveTheme());
    _emit();
  }

  Future<void> _saveTheme() async {
    try {
      final saved = await _prefs?.setBool('insights.dark', dark);
      if (saved == false) {
        error = 'Не удалось сохранить тему. Она изменена только до выхода.';
        _emit();
      }
    } catch (_) {
      error = 'Не удалось сохранить тему. Она изменена только до выхода.';
      _emit();
    }
  }

  List<Map<String, dynamic>> get visibleSessions => search.trim().isEmpty
      ? sessions
      : sessions
            .where(
              (e) =>
                  jsonEncode(e)
                      .toLowerCase()
                      .contains(search.trim().toLowerCase()),
            )
            .toList();

  String safeError(Object error) {
    // Never expose arbitrary server response bodies or platform exception values.
    if (error is StateError) return error.message;
    if (error is SecretVaultException) return error.message;
    if (error is InsightsApiException) return error.message;
    return 'Операция не выполнена. Проверьте адрес, сервисный секрет и доступность Insights Serverpod 4.0.4.';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _api?.close();
    _sessionSecrets.clear();
    unawaited(_vault.close());
    super.dispose();
  }
}
