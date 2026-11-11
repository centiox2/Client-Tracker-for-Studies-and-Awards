import 'package:flutter/material.dart';

import '../../design/app_theme.dart';

/// The "?" help sheet: every keyboard shortcut the app supports.
Future<void> showShortcutsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ShortcutsDialog(),
);

const _shortcuts = <(String, String)>[
  ('Ctrl K', 'Quick search: pages, weeks and staff'),
  ('Ctrl 1 – 6', 'Overview, Weekly tracker, History, Staff, Reports, Settings'),
  ('/', 'Quick search'),
  ('N', 'Revenue: new payment · Weekly tracker, History: new week'),
  ('Ctrl N', 'New week'),
  ('Ctrl Z', 'Undo the last number you changed'),
  ('?', 'This list of shortcuts'),
  ('Enter', 'Weekly tracker: move to the next field'),
  ('Esc', 'Close a dialog'),
];

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (keys, action) in _shortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Dt.s4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            border: Border.all(color: scheme.outline),
                            borderRadius: BorderRadius.circular(Dt.rSm),
                          ),
                          child: Text(keys, style: theme.textTheme.labelSmall),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(action, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Dt.s12),
            Text(
              'Numbers save automatically as you type. Values are the running '
              'total for the day: typing 5 after 3 stores 5, not 8.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
