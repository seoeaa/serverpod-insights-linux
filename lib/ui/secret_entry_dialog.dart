import 'package:flutter/material.dart';

import '../app_controller.dart';

class SecretEntryDialog extends StatefulWidget {
  const SecretEntryDialog({super.key, required this.profile});
  final ConnectionProfile profile;
  @override
  State<SecretEntryDialog> createState() => _SecretEntryDialogState();
}

class _SecretEntryDialogState extends State<SecretEntryDialog> {
  final controller = TextEditingController();
  bool remember = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    if (controller.text.isNotEmpty) {
      Navigator.pop(context, (secret: controller.text, remember: remember));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Подключиться: ${widget.profile.name}'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Сервисный секрет',
              helperText: 'По умолчанию только в памяти до выхода',
            ),
            onSubmitted: (_) => submit(),
          ),
          if (widget.profile.rememberSecret)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Обновить сохранённый секрет'),
              subtitle: const Text('После успешной проверки подключения'),
              value: remember,
              onChanged: (value) => setState(() => remember = value),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: submit, child: const Text('Подключиться')),
    ],
  );
}
