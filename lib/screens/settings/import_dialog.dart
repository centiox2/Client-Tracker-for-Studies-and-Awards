import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/excel_import.dart';
import '../../services/file_delivery.dart';
import '../../state/app_state.dart';

/// Picks an .xlsx file in the old spreadsheet layout, shows what was found,
/// lets the admin match names to staff, and imports it.
Future<void> importFromExcel(BuildContext context, WidgetRef ref) async {
  final bytes = await openFileBytes(
    dialogTitle: 'Import from Excel',
    extensions: ['xlsx'],
  );
  if (bytes == null || !context.mounted) return;
  ExcelImport data;
  try {
    data = parseExcelImport(bytes);
  } on ExcelImportException catch (e) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Couldn’t read that file'),
        content: Text('$e'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) return;
  final outcome = await showDialog<ImportOutcome>(
    context: context,
    builder: (_) => ImportPreviewDialog(data: data),
  );
  if (outcome == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Imported ${outcome.days} ${outcome.days == 1 ? 'day' : 'days'} '
        '(${outcome.clients} clients)'
        '${outcome.kept == 0 ? '' : ' · ${outcome.kept} kept as they were'}',
      ),
    ),
  );
}

/// The import preview: what the file holds, who's who, and Import.
class ImportPreviewDialog extends ConsumerStatefulWidget {
  const ImportPreviewDialog({super.key, required this.data});

  final ExcelImport data;

  @override
  ConsumerState<ImportPreviewDialog> createState() =>
      _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends ConsumerState<ImportPreviewDialog> {
  late final Map<String, ImportTarget> _targets;
  bool _overwrite = false;

  static const _add = -1;
  static const _skip = -2;

  @override
  void initState() {
    super.initState();
    final staff = ref.read(staffListProvider);
    _targets = {for (final n in widget.data.names) n: suggestTarget(n, staff)};
  }

  int _valueOf(ImportTarget t) => switch (t) {
    MatchStaff(:final staffId) => staffId,
    AddFormerStaff() => _add,
    SkipName() => _skip,
  };

  ImportTarget _targetOf(int v) => switch (v) {
    _add => const AddFormerStaff(),
    _skip => const SkipName(),
    _ => MatchStaff(v),
  };

  void _import() {
    final outcome = applyExcelImport(
      ref.read(databaseProvider),
      widget.data,
      _targets,
      overwrite: _overwrite,
    );
    ref.read(dataVersionProvider.notifier).bump();
    Navigator.pop(context, outcome);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = widget.data;
    final staff = ref.watch(staffListProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    if (data.days.isEmpty) {
      return AlertDialog(
        title: const Text('Nothing to import'),
        content: SizedBox(
          width: 420,
          child: Text(
            'No days with staff numbers were found. The file should have a '
            'section per day headed like “Monday  05/10/2026”, with Staff, '
            'New and Existing columns — the layout of the old weekly '
            'spreadsheet.'
            '${data.warnings.isEmpty ? '' : '\n\n${data.warnings.take(5).join('\n')}'}',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      );
    }
    final first = data.days.first.date;
    final last = data.days.last.date;
    final unknown = _targets.values.whereType<AddFormerStaff>().length;

    return AlertDialog(
      title: const Text('Import from Excel'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Found ${data.days.length} days in ${data.weeks} '
                '${data.weeks == 1 ? 'week' : 'weeks'} '
                '(${DateFormat('d MMM y').format(first)} – '
                '${DateFormat('d MMM y').format(last)}), '
                '${data.total} clients in all.',
                style: theme.textTheme.bodyMedium,
              ),
              if (data.warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${data.warnings.length} '
                  '${data.warnings.length == 1 ? 'section was' : 'sections were'} '
                  'skipped: ${data.warnings.first}',
                  style: muted,
                ),
              ],
              const SizedBox(height: 16),
              Text('Staff in the file', style: microLabel(theme)),
              const SizedBox(height: 4),
              Text(
                unknown == 0
                    ? 'Everyone matches a staff member. Change any match '
                          'below if it’s wrong.'
                    : '$unknown ${unknown == 1 ? 'name doesn’t' : 'names don’t'} '
                          'match anyone and will be added as former '
                          '(inactive) staff, unless you pick someone.',
                style: muted,
              ),
              const SizedBox(height: 8),
              for (final name in data.names)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const Icon(Icons.arrow_forward, size: 14),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 230,
                        child: DropdownButtonFormField<int>(
                          initialValue: _valueOf(_targets[name]!),
                          isExpanded: true,
                          isDense: true,
                          decoration: const InputDecoration(isDense: true),
                          items: [
                            for (final s in staff)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.active ? s.name : '${s.name} (inactive)',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            const DropdownMenuItem(
                              value: _add,
                              child: Text('Add as former staff'),
                            ),
                            const DropdownMenuItem(
                              value: _skip,
                              child: Text('Don’t import'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => _targets[name] = _targetOf(v));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _overwrite,
                onChanged: (v) => setState(() => _overwrite = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Replace numbers already in the app'),
                subtitle: Text(
                  'Off: days that already have someone’s numbers keep them.',
                  style: muted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _import,
          icon: const Icon(Icons.file_download_done_outlined, size: 16),
          label: Text('Import ${data.days.length} days'),
        ),
      ],
    );
  }
}
