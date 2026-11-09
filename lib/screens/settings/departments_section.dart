import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';

/// Settings › Departments (admins only): the departments people report
/// under, and the measurable outputs each one records.
class DepartmentsSection extends ConsumerStatefulWidget {
  const DepartmentsSection({super.key});

  @override
  ConsumerState<DepartmentsSection> createState() => _DepartmentsSectionState();
}

class _DepartmentsSectionState extends ConsumerState<DepartmentsSection> {
  List<Department>? _departments;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final meta = await ref.read(dailyReportsProvider).meta();
      if (mounted) {
        setState(() {
          _departments = meta.departments;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeReportError(e));
    }
  }

  Future<void> _edit([Department? department]) async {
    final saved = await showDialog<Department>(
      context: context,
      builder: (_) => _DepartmentDialog(department: department),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${saved.name} saved')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    final departments = _departments;
    return AppPanel(
      title: 'Departments',
      icon: Icons.apartment_outlined,
      trailing: departments == null
          ? null
          : '${departments.where((d) => d.active).length} active',
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The departments people record daily reports under, and the '
              'numbers each one counts (applications submitted, visas '
              'lodged…). Set each person’s department in Users.',
              style: muted,
            ),
            const SizedBox(height: 10),
            if (departments == null)
              _error == null
                  ? const Center(child: CircularProgressIndicator())
                  : Text(_error!, style: muted)
            else
              for (final d in departments)
                Opacity(
                  opacity: d.active ? 1 : 0.55,
                  child: ListTile(
                    key: ValueKey('department-${d.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(d.active ? d.name : '${d.name} (switched off)'),
                    subtitle: Text(
                      d.outputs.isEmpty
                          ? 'No outputs'
                          : d.outputs.map((o) => o.label).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _edit(d),
                    ),
                  ),
                ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('add-department'),
                onPressed: departments == null ? null : () => _edit(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add department'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DepartmentDialog extends ConsumerStatefulWidget {
  const _DepartmentDialog({this.department});

  final Department? department;

  @override
  ConsumerState<_DepartmentDialog> createState() => _DepartmentDialogState();
}

class _DepartmentDialogState extends ConsumerState<_DepartmentDialog> {
  late final _name = TextEditingController(text: widget.department?.name);
  late final _outputs = TextEditingController(
    text: widget.department?.outputs.map((o) => o.label).join('\n'),
  );
  late bool _active = widget.department?.active ?? true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _outputs.dispose();
    super.dispose();
  }

  /// One output per line. A label kept as it was keeps its key, so totals
  /// already recorded under it carry on.
  List<OutputField> get _fields {
    final existing = {
      for (final o in widget.department?.outputs ?? const <OutputField>[])
        o.label.toLowerCase(): o.key,
    };
    final used = <String>{};
    final fields = <OutputField>[];
    for (final line in _outputs.text.split('\n')) {
      final label = line.trim();
      if (label.isEmpty || used.contains(label.toLowerCase())) continue;
      used.add(label.toLowerCase());
      var key = existing[label.toLowerCase()] ?? OutputField.keyFor(label);
      final base = key;
      for (var i = 2; fields.any((f) => f.key == key); i++) {
        key = '${base.length > 36 ? base.substring(0, 36) : base}_$i';
      }
      fields.add(OutputField(key, label));
    }
    return fields;
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(dailyReportsProvider)
          .saveDepartment(
            id: widget.department?.id,
            name: _name.text,
            outputs: _fields,
            active: _active,
          );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeReportError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.department == null ? 'Add department' : 'Edit department',
    ),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('department-name'),
            controller: _name,
            autofocus: widget.department == null,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('department-outputs'),
            controller: _outputs,
            enabled: !_busy,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Outputs counted (one per line)',
              hintText: 'Applications submitted\nOffers received\nCOEs issued',
              alignLabelWithHint: true,
            ),
          ),
          SwitchListTile(
            value: _active,
            onChanged: _busy ? null : (v) => setState(() => _active = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            subtitle: const Text(
              'Switched off: no longer offered, but its reports stay.',
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('department-save'),
        onPressed: _busy ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}
