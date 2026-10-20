import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';

String timestamp(Object? value) {
  final time = DateTime.tryParse('$value')?.toLocal();
  return time == null ? '—' : time.toString().substring(0, 19);
}

String duration(Object? value) =>
    value is num ? '${(value * 1000).toStringAsFixed(1)} мс' : '—';
Map<String, dynamic> mapOf(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> mapsOf(Object? value) =>
    value is List ? value.map(mapOf).toList() : [];

class EmptyState extends StatelessWidget {
  const EmptyState(this.title, this.detail, {super.key});
  final String title, detail;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.6),
            ),
          ],
        ),
      ),
    ),
  );
}

class LogsView extends StatelessWidget {
  const LogsView({
    super.key,
    required this.app,
    required this.endpoint,
    required this.search,
  });
  final AppController app;
  final TextEditingController endpoint;
  final TextEditingController search;
  @override
  Widget build(BuildContext context) {
    final rows = app.visibleSessions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: search,
                  onChanged: app.setSearch,
                  decoration: const InputDecoration(
                    labelText: 'Поиск в загруженных сессиях',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: endpoint,
                  onSubmitted: (v) => app.setFilters(v, app.errorsOnly),
                  decoration: const InputDecoration(
                    labelText: 'Эндпоинт (точно)',
                  ),
                ),
              ),
              FilterChip(
                label: const Text('Только ошибки'),
                selected: app.errorsOnly,
                onSelected: app.refreshing
                    ? null
                    : (v) => app.setFilters(endpoint.text, v),
              ),
              OutlinedButton(
                onPressed: app.refreshing
                    ? null
                    : () => app.setFilters(endpoint.text, app.errorsOnly),
                child: const Text('Применить'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: rows.isEmpty
              ? const EmptyState(
                  'Сессий пока нет',
                  'Выполните запрос к вашему API и обновите список. Проверьте фильтры и включённое логирование на сервере.',
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    return Scrollbar(
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: box.maxWidth),
                            child: DataTable(
                              showCheckboxColumn: false,
                              headingRowHeight: 44,
                              dataRowMinHeight: 52,
                              dataRowMaxHeight: 64,
                              columns: const [
                                DataColumn(label: Text('Состояние')),
                                DataColumn(label: Text('Время')),
                                DataColumn(label: Text('Метод')),
                                DataColumn(
                                  label: Text('Длительность'),
                                  numeric: true,
                                ),
                                DataColumn(label: Text('SQL'), numeric: true),
                                DataColumn(label: Text('Сервер')),
                              ],
                              rows: rows.map((info) {
                                final s = mapOf(info['sessionLogEntry']);
                                final failed = s['error'] != null;
                                final open = s['isOpen'] == true;
                                return DataRow(
                                  onSelectChanged: (_) => showDialog<void>(
                                    context: context,
                                    builder: (_) => SessionDetails(info: info),
                                  ),
                                  cells: [
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            failed
                                                ? Icons.error_outline
                                                : open
                                                ? Icons.timelapse
                                                : Icons.check_circle_outline,
                                            size: 17,
                                            color: failed
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .error
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            failed
                                                ? 'Ошибка'
                                                : open
                                                ? 'Открыта'
                                                : s['slow'] == true
                                                ? 'Медленная'
                                                : 'Завершена',
                                          ),
                                        ],
                                      ),
                                    ),
                                    DataCell(Text(timestamp(s['time']))),
                                    DataCell(
                                      SizedBox(
                                        width: 230,
                                        child: Text(
                                          '${s['endpoint'] ?? '—'}.${s['method'] ?? '—'}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    DataCell(Text(duration(s['duration']))),
                                    DataCell(
                                      Text(
                                        '${s['numQueries'] ?? mapsOf(info['queries']).length}',
                                      ),
                                    ),
                                    DataCell(Text('${s['serverId'] ?? '—'}')),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton.icon(
            onPressed: app.refreshing || app.exhausted
                ? null
                : () => app.refresh(older: true),
            icon: const Icon(Icons.expand_more),
            label: Text(
              app.exhausted
                  ? 'Все доступные сессии загружены'
                  : 'Загрузить более ранние',
            ),
          ),
        ),
      ],
    );
  }
}

class SessionDetails extends StatelessWidget {
  const SessionDetails({super.key, required this.info});
  final Map<String, dynamic> info;
  @override
  Widget build(BuildContext context) {
    final s = mapOf(info['sessionLogEntry']);
    final queries = mapsOf(info['queries']);
    final logs = mapsOf(info['logs']);
    final messages = mapsOf(info['messages']);
    return Dialog(
      child: SizedBox(
        width: 920,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Сессия #${s['id'] ?? '—'}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                '${s['endpoint'] ?? '—'}.${s['method'] ?? '—'} · ${duration(s['duration'])} · ${timestamp(s['time'])}',
                style: const TextStyle(height: 1.6),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: DefaultTabController(
                  length: 4,
                  child: Column(
                    children: [
                      TabBar(
                        isScrollable: true,
                        tabs: [
                          const Tab(text: 'Сессия'),
                          Tab(text: 'SQL (${queries.length})'),
                          Tab(text: 'Логи (${logs.length})'),
                          Tab(text: 'Сообщения (${messages.length})'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: SelectableText(
                                const JsonEncoder.withIndent('  ').convert(s),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  height: 1.6,
                                ),
                              ),
                            ),
                            detailsList(
                              queries,
                              'query',
                              'Запросов SQL в этой сессии нет',
                            ),
                            detailsList(logs, 'message', 'Сообщений логов нет'),
                            detailsList(
                              messages,
                              'messageName',
                              'Потоковых сообщений нет',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget detailsList(
    List<Map<String, dynamic>> entries,
    String field,
    String empty,
  ) => entries.isEmpty
      ? EmptyState(empty, 'Список содержит только то, что сохранил сервер.')
      : ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          separatorBuilder: (_, index) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
          itemBuilder: (context, i) {
            final e = entries[i];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (e['duration'] != null)
                  Text(
                    '${duration(e['duration'])} · строк: ${e['numRows'] ?? '—'}',
                  ),
                const SizedBox(height: 8),
                SelectableText(
                  '${e[field] ?? '—'}',
                  style: const TextStyle(fontFamily: 'monospace', height: 1.6),
                ),
                if (e['error'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(
                      '${e['error']}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (e['stackTrace'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(
                      '${e['stackTrace']}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        height: 1.6,
                      ),
                    ),
                  ),
              ],
            );
          },
        );
}

class HealthView extends StatelessWidget {
  const HealthView({super.key, required this.data});
  final Map<String, dynamic>? data;
  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return const EmptyState(
        'Метрики не загружены',
        'Нажмите «Обновить». Данные запрашиваются за последний час.',
      );
    }
    final metrics = mapsOf(data!['metrics']);
    final connections = mapsOf(data!['connectionInfos']);
    if (metrics.isEmpty && connections.isEmpty) {
      return const EmptyState(
        'Метрик за последний час нет',
        'Serverpod сохраняет показатели периодически. Подождите и обновите данные.',
      );
    }
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final metric in metrics) {
      grouped
          .putIfAbsent('${metric['serverId']} / ${metric['name']}', () => [])
          .add(metric);
    }
    for (final values in grouped.values) {
      values.sort((a, b) => '${a['timestamp']}'.compareTo('${b['timestamp']}'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const Text(
          'История за последний час · исходные единицы сервера',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (final entry in grouped.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.key,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Icon(
                          entry.value.last['isHealthy'] == true
                              ? Icons.check_circle_outline
                              : Icons.warning_amber,
                          size: 20,
                          color: entry.value.last['isHealthy'] == true
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${entry.value.last['value']}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 130,
                      child: Semantics(
                        label:
                            'График ${entry.key}, ${entry.value.length} точек',
                        child: CustomPaint(
                          painter: MetricPainter(
                            entry.value,
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${timestamp(entry.value.first['timestamp'])}  —  ${timestamp(entry.value.last['timestamp'])}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'Значения и время',
                        style: TextStyle(fontSize: 12),
                      ),
                      children: [
                        SelectableText(
                          entry.value
                              .map(
                                (m) =>
                                    '${timestamp(m['timestamp'])}   ${m['value']}   ${m['isHealthy'] == true ? 'OK' : 'Внимание'}',
                              )
                              .join('\n'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (connections.isNotEmpty) ...[
          Text(
            'Соединения с базой данных',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          for (final server
              in connections.map((e) => '${e['serverId']}').toSet())
            Builder(
              builder: (context) {
                final values =
                    connections
                        .where((e) => '${e['serverId']}' == server)
                        .toList()
                      ..sort(
                        (a, b) =>
                            '${a['timestamp']}'.compareTo('${b['timestamp']}'),
                      );
                final c = values.last;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(server),
                  subtitle: Text(
                    'Активные: ${c['active']} · Ожидают: ${c['idle']} · Закрываются: ${c['closing']}\n${timestamp(c['timestamp'])}',
                  ),
                );
              },
            ),
        ],
      ],
    );
  }
}

class MetricPainter extends CustomPainter {
  MetricPainter(this.values, this.color);
  final List<Map<String, dynamic>> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final valid = values
        .where(
          (v) =>
              v['value'] is num &&
              (v['value'] as num).isFinite &&
              DateTime.tryParse('${v['timestamp']}') != null,
        )
        .toList();
    if (valid.isEmpty) return;
    final numbers = valid.map((e) => (e['value'] as num).toDouble()).toList();
    final minValue = numbers.reduce(math.min),
        maxValue = numbers.reduce(math.max);
    final range = maxValue - minValue;
    final start = DateTime.parse('${valid.first['timestamp']}')
        .millisecondsSinceEpoch;
    final end = DateTime.parse('${valid.last['timestamp']}')
        .millisecondsSinceEpoch;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    final positions = <Offset>[];
    for (var i = 0; i < valid.length; i++) {
      final time = DateTime.parse('${valid[i]['timestamp']}')
          .millisecondsSinceEpoch;
      final x = end == start
          ? size.width / 2
          : (time - start) / (end - start) * size.width;
      final y = range == 0
          ? size.height / 2
          : size.height -
                8 -
                (numbers[i] - minValue) / range * (size.height - 16);
      positions.add(Offset(x, y));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()..color = color.withValues(alpha: .2),
    );
    canvas.drawPath(path, paint);
    if (positions.length == 1) {
      canvas.drawCircle(positions.first, 3, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(MetricPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const labels = {
    'logAllSessions': 'Все сессии',
    'logFailedSessions': 'Сессии с ошибками',
    'logSlowSessions': 'Медленные сессии',
    'logAllQueries': 'Все SQL-запросы',
    'logFailedQueries': 'SQL-запросы с ошибками',
    'logSlowQueries': 'Медленные SQL-запросы',
    'logStreamingSessionsContinuously':
        'Непрерывное логирование потоковых сессий',
  };
  Map<String, dynamic>? draft;
  String? profileId;
  final slowSession = TextEditingController(),
      slowQuery = TextEditingController();
  bool dirty = false;
  String? validation;
  void load() {
    draft = widget.app.settings == null
        ? null
        : mapOf(jsonDecode(jsonEncode(widget.app.settings)));
    final log = mapOf(draft?['logSettings']);
    slowSession.text = '${log['slowSessionDuration'] ?? ''}';
    slowQuery.text = '${log['slowQueryDuration'] ?? ''}';
    profileId = widget.app.active?.id;
    dirty = false;
    validation = null;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (profileId != widget.app.active?.id ||
        (!dirty && widget.app.settings != null)) {
      load();
    }
  }

  @override
  void dispose() {
    slowSession.dispose();
    slowQuery.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final session = double.tryParse(slowSession.text.replaceAll(',', '.'));
    final query = double.tryParse(slowQuery.text.replaceAll(',', '.'));
    if (session == null ||
        query == null ||
        !session.isFinite ||
        !query.isFinite ||
        session < 0 ||
        query < 0) {
      setState(
        () => validation =
            'Пороги должны быть конечными неотрицательными числами (секунды).',
      );
      return;
    }
    // Preserve every server field and endpoint override not exposed in this MVP.
    final base = mapOf(jsonDecode(jsonEncode(widget.app.settings)));
    final log = mapOf(base['logSettings'])
      ..addAll(mapOf(draft!['logSettings']));
    log['slowSessionDuration'] = session;
    log['slowQueryDuration'] = query;
    base['logSettings'] = log;
    final id = widget.app.active?.id;
    final epoch = widget.app.connectionEpoch;
    final settingsSnapshot = jsonEncode(widget.app.settings);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Применить настройки на сервере?'),
        content: Text(
          'Изменится логирование «${widget.app.active?.name}». Запись всех SQL-запросов может увеличить нагрузку и сохранить чувствительные данные. Остальные настройки и overrides будут сохранены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (id != widget.app.active?.id ||
        epoch != widget.app.connectionEpoch ||
        settingsSnapshot != jsonEncode(widget.app.settings)) {
      setState(
        () => validation = 'Соединение или настройки изменились во время подтверждения. Обновите данные и повторите.',
      );
      return;
    }
    try {
      final saved = await widget.app.saveSettings(base);
      if (mounted && saved && id == widget.app.active?.id) {
        setState(load);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Настройки сохранены и перечитаны с сервера'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => validation = widget.app.safeError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (draft == null) {
      return const EmptyState(
        'Настройки не загружены',
        'Проверьте соединение и нажмите «Обновить».',
      );
    }
    final log = mapOf(draft!['logSettings']);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const Text(
          'Изменения применяются ко всему серверу. Пороги указаны в секундах.',
          style: TextStyle(height: 1.6),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 300,
            child: DropdownButtonFormField<int>(
              initialValue: (log['logLevel'] as int?) ?? 1,
              decoration: const InputDecoration(
                labelText: 'Минимальный уровень логирования',
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Debug')),
                DropdownMenuItem(value: 1, child: Text('Info')),
                DropdownMenuItem(value: 2, child: Text('Warning')),
                DropdownMenuItem(value: 3, child: Text('Error')),
                DropdownMenuItem(value: 4, child: Text('Fatal')),
              ],
              onChanged: widget.app.refreshing
                  ? null
                  : (v) => setState(() {
                      log['logLevel'] = v;
                      draft!['logSettings'] = log;
                      dirty = true;
                    }),
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final entry in labels.entries)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.value),
            value: log[entry.key] == true,
            onChanged: widget.app.refreshing
                ? null
                : (v) => setState(() {
                    log[entry.key] = v;
                    draft!['logSettings'] = log;
                    dirty = true;
                  }),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: 250,
              child: TextField(
                controller: slowSession,
                keyboardType: TextInputType.number,
                onChanged: (_) => dirty = true,
                decoration: const InputDecoration(
                  labelText: 'Медленная сессия, секунды',
                ),
              ),
            ),
            SizedBox(
              width: 250,
              child: TextField(
                controller: slowQuery,
                keyboardType: TextInputType.number,
                onChanged: (_) => dirty = true,
                decoration: const InputDecoration(
                  labelText: 'Медленный запрос, секунды',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Правил переопределения эндпоинтов: ${mapsOf(draft!['logSettingsOverrides']).length}. Они сохраняются без изменения.',
          style: const TextStyle(fontSize: 12),
        ),
        if (validation != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              validation!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: widget.app.refreshing ? null : save,
              icon: const Icon(Icons.check),
              label: const Text('Применить на сервере'),
            ),
            OutlinedButton(
              onPressed: widget.app.refreshing ? null : () => setState(load),
              child: const Text('Отменить изменения'),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
