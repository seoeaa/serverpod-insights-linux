import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'data_views.dart';
import 'secret_entry_dialog.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.app});
  final AppController app;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  int tab = 0;
  final endpoint = TextEditingController();
  final search = TextEditingController();
  AppController get app => widget.app;
  @override
  void dispose() {
    endpoint.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> addConnection() async {
    final profile = await showDialog<ConnectionProfile>(
      context: context,
      builder: (_) => ConnectionDialog(app: app),
    );
    if (profile != null) await app.connect(profile);
  }

  Future<void> enterSecret(ConnectionProfile profile) async {
    if (app.busy) return;
    final result = await showDialog<({String secret, bool remember})>(
      context: context,
      builder: (_) => SecretEntryDialog(profile: profile),
    );
    if (result != null && mounted) {
      await app.connect(
        profile,
        enteredSecret: result.secret,
        persistEnteredSecret: result.remember,
      );
    }
  }

  Widget sidebar() => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 18, 24),
          child: Row(
            children: [
              Icon(
                Icons.hub_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 30,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Insights',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Независимый Linux-клиент',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Подключения',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                onPressed: app.initialized ? addConnection : null,
                tooltip: 'Добавить подключение',
                icon: const Icon(Icons.add, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (app.profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Добавьте локальный сервер или HTTPS-адрес Insights.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              for (final p in app.profiles)
                ListTile(
                  selected: app.active?.id == p.id,
                  leading: Icon(
                    app.active?.id == p.id && app.connected
                        ? Icons.cloud_done_outlined
                        : Icons.dns_outlined,
                    size: 20,
                  ),
                  title: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    p.url,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: app.busy ? null : () => app.connect(p),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Действия подключения',
                    onSelected: (value) async {
                      if (value == 'secret') {
                        await enterSecret(p);
                        return;
                      }
                      if (value == 'delete') {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Удалить подключение?'),
                            content: Text(
                              '«${p.name}» и сохранённый сервисный секрет будут удалены. Сервер не изменится.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Удалить'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          try {
                            await app.removeProfile(p);
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(app.safeError(e))),
                              );
                            }
                          }
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'secret',
                        child: Text('Ввести секрет и подключиться'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить подключение'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.contrast),
          title: const Text('Сменить тему'),
          onTap: app.toggleTheme,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Text(
            'Протокол Serverpod 4.0.4\nСекреты — в системной связке ключей',
            style: TextStyle(fontSize: 11, height: 1.6),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 1000;
      return Scaffold(
        drawer: wide ? null : Drawer(child: sidebar()),
        body: Row(
          children: [
            if (wide)
              SizedBox(
                width: 280,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: sidebar(),
                ),
              ),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            if (!wide)
                              Builder(
                                builder: (context) => IconButton(
                                  tooltip: 'Подключения',
                                  onPressed: () =>
                                      Scaffold.of(context).openDrawer(),
                                  icon: const Icon(Icons.menu),
                                ),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    app.active?.name ?? 'Рабочее пространство',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    app.busy
                                        ? 'Подключаемся…'
                                        : app.connected
                                        ? 'Подключено · ${app.active?.url}'
                                        : 'Нет активного соединения',
                                    style: const TextStyle(fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (app.connected)
                              IconButton(
                                tooltip: 'Отключиться',
                                onPressed: app.disconnect,
                                icon: const Icon(Icons.power_settings_new),
                              ),
                            IconButton(
                              tooltip: 'Добавить подключение',
                              onPressed: app.initialized ? addConnection : null,
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (app.busy || app.refreshing || !app.initialized)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    const SizedBox(height: 2),
                  if (app.storageError != null || app.error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.error_outline, size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: SelectableText(
                                  app.storageError ?? app.error!,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!app.connected)
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 540),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.monitor_heart_outlined,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  'Ваш сервер.\nВсё важное — рядом.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Сессии, SQL-запросы, исключения и здоровье Serverpod в одном рабочем пространстве. Без прямого доступа к базе данных.',
                                  style: TextStyle(fontSize: 16, height: 1.6),
                                ),
                                const SizedBox(height: 24),
                                FilledButton.icon(
                                  onPressed: app.initialized
                                      ? addConnection
                                      : null,
                                  icon: const Icon(Icons.add),
                                  label: const Text('Добавить подключение'),
                                ),
                                const SizedBox(height: 20),
                                const Text(
                                  'Нужны адрес Insights и serviceSecret сервера версии 4.0.4. Для удалённого сервера используйте HTTPS или локальный SSH-туннель.',
                                  style: TextStyle(fontSize: 12, height: 1.6),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 20,
                        runSpacing: 12,
                        children: [
                          Text(
                            [
                              'Сессии и логи',
                              'Здоровье сервера',
                              'Настройки логирования',
                            ][tab],
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: app.autoRefresh,
                                onChanged: app.setAutoRefresh,
                              ),
                              const Text('Каждые 10 с'),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Обновить',
                                onPressed: app.refreshing
                                    ? null
                                    : () => app.refresh(),
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('Логи'),
                            icon: Icon(Icons.list_alt),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Метрики'),
                            icon: Icon(Icons.insights),
                          ),
                          ButtonSegment(
                            value: 2,
                            label: Text('Настройки'),
                            icon: Icon(Icons.tune),
                          ),
                        ],
                        selected: {tab},
                        onSelectionChanged: (v) =>
                            setState(() => tab = v.first),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: switch (tab) {
                        0 => LogsView(
                          app: app,
                          endpoint: endpoint,
                          search: search,
                        ),
                        1 => HealthView(data: app.healthData),
                        _ => SettingsView(app: app),
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
                      child: Text(
                        app.lastUpdated == null
                            ? 'Данные ещё не загружены'
                            : 'Обновлено ${app.lastUpdated!.toLocal().toString().substring(11, 19)} · ${app.sessions.length} сессий · время локальное',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key, required this.app});
  final AppController app;
  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final form = GlobalKey<FormState>();
  final connectionId = DateTime.now().microsecondsSinceEpoch.toString();
  final name = TextEditingController();
  final url = TextEditingController(text: 'http://localhost:8081/');
  final secret = TextEditingController();
  bool remember = false, saving = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    url.dispose();
    secret.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final p = await widget.app.addProfile(
        name.text,
        url.text,
        secret.text,
        remember,
        profileId: connectionId,
      );
      if (mounted) Navigator.pop(context, p);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = widget.app.safeError(e);
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новое подключение'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Подключение к Insights Serverpod 4.0.4. Адрес административного сервера, не основного API.',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  hintText: 'Например, локальная разработка',
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Укажите название' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: url,
                decoration: const InputDecoration(
                  labelText: 'Адрес Insights',
                  helperText:
                      'HTTPS или HTTP только localhost / 127.0.0.1 / ::1',
                ),
                validator: (v) =>
                    Uri.tryParse(v?.trim() ?? '')?.hasAuthority != true
                    ? 'Укажите полный адрес сервера'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: secret,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Сервисный секрет',
                  hintText: 'serviceSecret',
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Укажите сервисный секрет' : null,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Сохранить в связке ключей'),
                subtitle: const Text(
                  'Иначе секрет останется только в памяти до выхода',
                ),
                value: remember,
                onChanged: saving ? null : (v) => setState(() => remember = v),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Сохранение…' : 'Добавить и подключиться'),
      ),
    ],
  );
}
