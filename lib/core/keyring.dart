import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// Базовая ошибка хранилища секретов.
///
/// Наследники позволяют вызывающему коду отличить недоступный сервис,
/// заблокированную связку ключей и сбой конкретной операции. Текст ошибки
/// никогда не содержит значения секрета.
sealed class SecretVaultException implements Exception {
  const SecretVaultException(this.message);

  /// Понятное человеку описание проблемы.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Сервис `org.freedesktop.secrets` недоступен в сессионной шине D-Bus.
///
/// Обычно означает, что не запущен gnome-keyring (или совместимый Secret
/// Service) либо приложение не имеет доступа к сессионной шине.
class SecretVaultUnavailableException extends SecretVaultException {
  const SecretVaultUnavailableException(super.message);
}

/// Связка ключей заблокирована и не открывается без участия пользователя.
class SecretVaultLockedException extends SecretVaultException {
  const SecretVaultLockedException(super.message, {this.promptPath});

  /// Путь объекта `org.freedesktop.Secret.Prompt`, если сервис предложил
  /// интерактивную разблокировку.
  ///
  /// Prompt намеренно не запускается: разблокировать связку должен
  /// пользователь, после чего операцию нужно повторить.
  final String? promptPath;
}

/// Сервис секретов ответил ошибкой или неожиданным форматом данных.
class SecretVaultOperationException extends SecretVaultException {
  const SecretVaultOperationException(super.message);
}

/// Сервис секретов не ответил за отведённое время.
///
/// [outcomeUnknown] == true означает, что изменяющий вызов мог примениться:
/// результат неизвестен, и автоматически повторять такой вызов нельзя.
class SecretVaultTimeoutException extends SecretVaultException {
  const SecretVaultTimeoutException(
    super.message, {
    this.method,
    this.outcomeUnknown = false,
  });

  /// Имя метода D-Bus, на котором истекло ожидание.
  final String? method;

  /// `true`, если исход изменяющей операции остался неизвестным.
  final bool outcomeUnknown;
}

/// Хранилище секретов приложения поверх стандартного `org.freedesktop.secrets`.
///
/// Реализация работает напрямую с D-Bus API Secret Service: открывает
/// `plain`-сессию, использует коллекцию `default` (`ReadAlias`) и хранит
/// секреты как items с атрибутами `application` и `connection_id`.
/// libsecret и `secret-tool` не нужны.
///
/// Секреты никогда не пишутся в файлы, не логируются и не попадают в
/// тексты исключений. Если связка ключей заблокирована, выбрасывается
/// [SecretVaultLockedException]: разблокировать её должен пользователь.
class SecretVault {
  SecretVault();

  static const String _serviceName = 'org.freedesktop.secrets';
  static const String _serviceInterface = 'org.freedesktop.Secret.Service';
  static const String _collectionInterface =
      'org.freedesktop.Secret.Collection';
  static const String _itemInterface = 'org.freedesktop.Secret.Item';
  static const String _sessionInterface = 'org.freedesktop.Secret.Session';
  static const String _propertiesInterface = 'org.freedesktop.DBus.Properties';

  static const String _applicationAttribute = 'application';
  static const String _connectionIdAttribute = 'connection_id';
  static const String _itemLabelProperty = 'org.freedesktop.Secret.Item.Label';
  static const String _itemAttributesProperty =
      'org.freedesktop.Secret.Item.Attributes';
  static const String _applicationName = 'serverpod-insights-linux';
  static const String _defaultAlias = 'default';
  static const String _contentType = 'text/plain';
  static const String _lockedProperty = 'Locked';
  static const String _rootPath = '/';

  /// Предельное ожидание ответа на один вызов D-Bus.
  ///
  /// Защищает UI от вечного ожидания, если сервис принял соединение, но
  /// перестал отвечать.
  static const Duration _callTimeout = Duration(seconds: 10);

  /// Предельное ожидание при закрытии: dispose не должен задерживать выход.
  static const Duration _closeTimeout = Duration(seconds: 2);

  static const String _unavailableMessage =
      'Сервис секретов org.freedesktop.secrets недоступен в сессионной шине '
      'D-Bus. Запустите gnome-keyring (или совместимый Secret Service) и '
      'повторите попытку.';
  static const String _lockedMessage =
      'Связка ключей заблокирована. Разблокируйте её в системе и повторите '
      'попытку.';
  static const String _unlockFailedMessage =
      'Связка ключей не разблокирована: сервис секретов не подтвердил '
      'разблокировку. Разблокируйте её в системе и повторите попытку.';
  static const String _noDefaultCollectionMessage =
      'В связке ключей нет коллекции default. Создайте её (например, в '
      'приложении «Пароли и ключи») и повторите попытку.';
  static const String _corruptedSecretMessage =
      'Секрет в связке ключей повреждён: содержимое не является текстом '
      'UTF-8.';

  static final DBusObjectPath _servicePath = DBusObjectPath(
    '/org/freedesktop/secrets',
  );

  DBusClient? _client;
  String? _sessionPath;
  DBusObjectPath? _collectionPath;
  Future<void>? _initialization;
  bool _closed = false;

  /// Сохраняет [secret] под идентификатором подключения [id].
  ///
  /// Повторный вызов с тем же [id] перезаписывает секрет, а не создаёт
  /// второй item (`CreateItem` с `replace = true`).
  Future<void> put(String id, String secret) async {
    _validateId(id);
    final session = await _ensureReady();
    await _call<void>(() async {
      // CreateItem ожидает не «сырые» атрибуты, а свойства item: подпись
      // и атрибуты лежат под своими полными именами.
      final properties = DBusDict.stringVariant(<String, DBusValue>{
        _itemLabelProperty: const DBusString(_applicationName),
        _itemAttributesProperty: _attributes(id),
      });
      final secretValue = DBusStruct(<DBusValue>[
        DBusObjectPath(session.sessionPath),
        DBusArray.byte(const <int>[]),
        DBusArray.byte(utf8.encode(secret)),
        const DBusString(_contentType),
      ]);
      final response = await _bounded(
        session.client.callMethod(
          destination: _serviceName,
          path: session.collectionPath,
          interface: _collectionInterface,
          name: 'CreateItem',
          values: <DBusValue>[properties, secretValue, const DBusBoolean(true)],
          replySignature: DBusSignature('oo'),
        ),
        method: 'CreateItem',
        unknownOutcome: true,
      );
      _throwIfPromptRequired(response.returnValues[1].asObjectPath());
    });
  }

  /// Возвращает секрет для [id] или `null`, если записи нет.
  ///
  /// Если item заблокирован, выполняется попытка `Unlock`; при
  /// необходимости интерактивного prompt выбрасывается
  /// [SecretVaultLockedException], а не поддельный результат.
  Future<String?> get(String id) async {
    _validateId(id);
    final session = await _ensureReady();
    return _call<String?>(() async {
      final items = await _searchItems(
        session.client,
        session.collectionPath,
        id,
      );
      for (final item in items) {
        try {
          await _ensureUnlocked(session.client, _itemInterface, item);
          final response = await _bounded(
            session.client.callMethod(
              destination: _serviceName,
              path: item,
              interface: _itemInterface,
              name: 'GetSecret',
              values: <DBusValue>[DBusObjectPath(session.sessionPath)],
              replySignature: DBusSignature('(oayays)'),
            ),
            method: 'GetSecret',
          );
          final fields = response.returnValues[0].asStruct();
          final bytes = fields[2].asByteArray().toList(growable: false);
          try {
            return utf8.decode(bytes);
          } on FormatException {
            throw const SecretVaultOperationException(_corruptedSecretMessage);
          }
        } on DBusUnknownObjectException {
          // Item удалили между поиском и чтением — пробуем следующего.
          continue;
        }
      }
      return null;
    });
  }

  /// Удаляет секрет [id]. Отсутствующая запись не считается ошибкой.
  Future<void> remove(String id) async {
    _validateId(id);
    final session = await _ensureReady();
    await _call<void>(() async {
      final items = await _searchItems(
        session.client,
        session.collectionPath,
        id,
      );
      for (final item in items) {
        try {
          final response = await _bounded(
            session.client.callMethod(
              destination: _serviceName,
              path: item,
              interface: _itemInterface,
              name: 'Delete',
              replySignature: DBusSignature('o'),
            ),
            method: 'Delete',
            unknownOutcome: true,
          );
          _throwIfPromptRequired(response.returnValues[0].asObjectPath());
        } on DBusUnknownObjectException {
          // Item уже удалён — цель достигнута.
          continue;
        }
      }
    });
  }

  /// Закрывает сессию Secret Service и соединение с шиной.
  ///
  /// Повторный вызов безопасен. После закрытия операции бросают [StateError].
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _initialization = null;
    final client = _client;
    final sessionPath = _sessionPath;
    _client = null;
    _sessionPath = null;
    _collectionPath = null;
    if (client == null) {
      return;
    }
    try {
      if (sessionPath != null) {
        await _bounded(
          client.callMethod(
            destination: _serviceName,
            path: DBusObjectPath(sessionPath),
            interface: _sessionInterface,
            name: 'Close',
            noReplyExpected: true,
          ),
          method: 'Close',
          unknownOutcome: true,
          timeout: _closeTimeout,
        );
      }
    } on Object {
      // dispose не имеет права падать: сервис мог закрыть сессию сам или
      // зависнуть. Соединение в любом случае освобождаем ниже.
    } finally {
      await _closeClientQuietly(client);
    }
  }

  /// Ленивая инициализация: одна попытка на всех параллельных вызывающих.
  Future<_VaultSession> _ensureReady() async {
    if (_closed) {
      throw StateError('SecretVault уже закрыт');
    }
    final initialization = _initialization ??= _initialize();
    try {
      await initialization;
    } catch (_) {
      // Неудачную инициализацию не кешируем: после разблокировки связки
      // пользователь должен иметь возможность просто повторить операцию.
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
      rethrow;
    }
    final client = _client;
    final sessionPath = _sessionPath;
    final collectionPath = _collectionPath;
    if (client == null || sessionPath == null || collectionPath == null) {
      throw StateError('SecretVault не инициализирован');
    }
    if (_closed) {
      throw StateError('SecretVault уже закрыт');
    }
    return _VaultSession(
      client: client,
      sessionPath: sessionPath,
      collectionPath: collectionPath,
    );
  }

  Future<void> _initialize() async {
    final client = DBusClient.session();
    try {
      final _Initialized initialized = await _call<_Initialized>(() async {
        final sessionPath = await _openSession(client);
        final collectionPath = await _readDefaultCollection(client);
        await _ensureUnlocked(client, _collectionInterface, collectionPath);
        return (sessionPath: sessionPath, collectionPath: collectionPath);
      });
      if (_closed) {
        throw StateError('SecretVault закрыт во время инициализации');
      }
      _client = client;
      _sessionPath = initialized.sessionPath;
      _collectionPath = initialized.collectionPath;
    } catch (_) {
      // DBusClient после неудачного connect остаётся навсегда в состоянии
      // «подключаюсь», поэтому сломанный клиент нельзя переиспользовать —
      // закрываем его и создаём новый при следующей попытке.
      await _closeClientQuietly(client);
      rethrow;
    }
  }

  Future<String> _openSession(DBusClient client) async {
    final response = await _bounded(
      client.callMethod(
        destination: _serviceName,
        path: _servicePath,
        interface: _serviceInterface,
        name: 'OpenSession',
        values: <DBusValue>[
          const DBusString('plain'),
          DBusVariant(const DBusString('')),
        ],
        replySignature: DBusSignature('vo'),
      ),
      method: 'OpenSession',
    );
    return response.returnValues[1].asObjectPath().value;
  }

  Future<DBusObjectPath> _readDefaultCollection(DBusClient client) async {
    final response = await _bounded(
      client.callMethod(
        destination: _serviceName,
        path: _servicePath,
        interface: _serviceInterface,
        name: 'ReadAlias',
        values: <DBusValue>[const DBusString(_defaultAlias)],
        replySignature: DBusSignature('o'),
      ),
      method: 'ReadAlias',
    );
    final path = response.returnValues[0].asObjectPath();
    if (path.value == _rootPath) {
      throw const SecretVaultUnavailableException(_noDefaultCollectionMessage);
    }
    return path;
  }

  Future<List<DBusObjectPath>> _searchItems(
    DBusClient client,
    DBusObjectPath collectionPath,
    String id,
  ) async {
    final response = await _bounded(
      client.callMethod(
        destination: _serviceName,
        path: collectionPath,
        interface: _collectionInterface,
        name: 'SearchItems',
        values: <DBusValue>[_attributes(id)],
        replySignature: DBusSignature('ao'),
      ),
      method: 'SearchItems',
    );
    return response.returnValues[0].asObjectPathArray().toList(growable: false);
  }

  DBusDict _attributes(String id) {
    return DBusDict(DBusSignature('s'), DBusSignature('s'), {
      const DBusString(_applicationAttribute): const DBusString(
        _applicationName,
      ),
      const DBusString(_connectionIdAttribute): DBusString(id),
    });
  }

  Future<bool> _isLocked(
    DBusClient client,
    String interface,
    DBusObjectPath path,
  ) async {
    final response = await _bounded(
      client.callMethod(
        destination: _serviceName,
        path: path,
        interface: _propertiesInterface,
        name: 'Get',
        values: <DBusValue>[
          DBusString(interface),
          const DBusString(_lockedProperty),
        ],
        replySignature: DBusSignature('v'),
      ),
      method: 'Properties.Get',
    );
    return response.returnValues[0].asVariant().asBoolean();
  }

  Future<void> _ensureUnlocked(
    DBusClient client,
    String interface,
    DBusObjectPath path,
  ) async {
    if (!await _isLocked(client, interface, path)) {
      return;
    }
    await _unlock(client, <DBusObjectPath>[path]);
    if (await _isLocked(client, interface, path)) {
      throw const SecretVaultLockedException(_unlockFailedMessage);
    }
  }

  Future<void> _unlock(DBusClient client, List<DBusObjectPath> objects) async {
    final response = await _bounded(
      client.callMethod(
        destination: _serviceName,
        path: _servicePath,
        interface: _serviceInterface,
        name: 'Unlock',
        values: <DBusValue>[DBusArray.objectPath(objects)],
        replySignature: DBusSignature('aoo'),
      ),
      method: 'Unlock',
      unknownOutcome: true,
    );
    _throwIfPromptRequired(response.returnValues[1].asObjectPath());
    final unlocked = response.returnValues[0]
        .asObjectPathArray()
        .map((path) => path.value)
        .toSet();
    final stillLocked = objects
        .where((path) => !unlocked.contains(path.value))
        .length;
    if (stillLocked > 0) {
      throw const SecretVaultLockedException(_unlockFailedMessage);
    }
  }

  /// Prompt не запускаем: разблокировка — действие пользователя.
  void _throwIfPromptRequired(DBusObjectPath prompt) {
    if (prompt.value != _rootPath) {
      throw SecretVaultLockedException(
        _lockedMessage,
        promptPath: prompt.value,
      );
    }
  }

  void _validateId(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        'Идентификатор подключения не может быть пустым',
      );
    }
  }

  /// Переводит ошибки D-Bus в исключения этого файла.
  ///
  /// Тексты ошибок сервиса намеренно не включаются: они не нужны вызывающему
  /// коду и не должны разносить значения атрибутов или секретов по логам.
  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SecretVaultException {
      rethrow;
    } on DBusMethodResponseException catch (error) {
      throw _mapDbusError(error);
    } on DBusReplySignatureException catch (error) {
      throw SecretVaultOperationException(
        'Сервис секретов вернул неожиданный формат ответа в методе '
        '${error.methodName}.',
      );
    } on SocketException {
      throw const SecretVaultUnavailableException(_unavailableMessage);
    } on TimeoutException {
      // Страховка: каждый вызов уже ограничен в _bounded.
      throw const SecretVaultTimeoutException(
        'Сервис секретов не ответил за отведённое время.',
        outcomeUnknown: true,
      );
    }
  }

  SecretVaultException _mapDbusError(DBusMethodResponseException error) {
    switch (error.errorName) {
      case 'org.freedesktop.DBus.Error.ServiceUnknown':
      case 'org.freedesktop.DBus.Error.NameHasNoOwner':
        return const SecretVaultUnavailableException(_unavailableMessage);
      case 'org.freedesktop.Secret.Error.IsLocked':
        return const SecretVaultLockedException(_lockedMessage);
      default:
        return SecretVaultOperationException(
          'Сервис секретов вернул ошибку D-Bus: ${error.errorName}.',
        );
    }
  }

  /// Ограничивает ожидание ответа, чтобы зависший сервис не подвесил UI.
  ///
  /// Вызов не повторяется: при [unknownOutcome] исход изменяющей операции
  /// остаётся неизвестным, и решение о повторе принимает вызывающий код.
  Future<T> _bounded<T>(
    Future<T> call, {
    required String method,
    bool unknownOutcome = false,
    Duration timeout = _callTimeout,
  }) {
    return call.timeout(
      timeout,
      onTimeout: () => throw SecretVaultTimeoutException(
        unknownOutcome
            ? 'Сервис секретов не ответил на $method за ${timeout.inSeconds} с: '
                  'результат операции неизвестен, не считайте её выполненной.'
            : 'Сервис секретов не ответил на $method за ${timeout.inSeconds} с.',
        method: method,
        outcomeUnknown: unknownOutcome,
      ),
    );
  }

  /// Best effort закрытие соединения: не бросает и не тянет dispose.
  Future<void> _closeClientQuietly(DBusClient client) async {
    try {
      await client.close().timeout(_closeTimeout);
    } on Object {
      // Закрытие не должно подменять исходную ошибку операции или валить
      // dispose: сокет мог быть уже потерян.
    }
  }
}

/// Результат успешной инициализации: сессия и коллекция `default`.
typedef _Initialized = ({String sessionPath, DBusObjectPath collectionPath});

/// Открытая сессия Secret Service, готовая к вызовам.
class _VaultSession {
  const _VaultSession({
    required this.client,
    required this.sessionPath,
    required this.collectionPath,
  });

  final DBusClient client;

  /// Путь сессии, выданный `OpenSession`.
  final String sessionPath;

  /// Коллекция `default`, в которой лежат items приложения.
  final DBusObjectPath collectionPath;
}
