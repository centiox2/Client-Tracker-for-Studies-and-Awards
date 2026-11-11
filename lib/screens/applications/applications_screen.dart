import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/airtable_tags.dart';
import '../../design/app_theme.dart';
import '../../repositories/application_repository.dart';
import '../../services/airtable_sync_service.dart';
import '../../services/file_delivery.dart';
import '../../services/photo_text.dart' show photoDropSupported;
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import 'applications_quick_view.dart';
import 'applications_table.dart';

/// Applications: the Airtable "Applications Tracker", uploaded as its CSV
/// export. Shows where every application stands, grouped by status as in
/// Airtable, and what changed since the previous upload.
///
/// [canUpload]: the admin and the admin team load new CSVs; everyone else
/// sees the same, read-only.
class ApplicationsScreen extends ConsumerStatefulWidget {
  const ApplicationsScreen({super.key, required this.canUpload});

  final bool canUpload;

  @override
  ConsumerState<ApplicationsScreen> createState() => _ApplicationsScreenState();
}

class _ApplicationsScreenState extends ConsumerState<ApplicationsScreen> {
  final _search = TextEditingController();
  String? _status;
  String? _country;
  String? _assignee;
  String? _rto;
  bool _inProgressOnly = false;
  bool _offerOverdueOnly = false;
  _AppSort _sort = _AppSort.stage;
  bool _dragging = false;
  bool _busy = false;
  bool _syncing = false;

  /// The upload whose changes are shown (null: the latest).
  int? _importId;

  /// Quick view (what happened and what's happening), the full list
  /// grouped by status, or the table with every column.
  _View _view = _View.quick;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickCsv() async {
    final bytes = await openFileBytes(
      dialogTitle: 'Upload the Applications Tracker CSV',
      extensions: const ['csv'],
    );
    if (bytes == null || !mounted) return;
    await _load(bytes, '');
  }

  Future<void> _load(List<int> bytes, String fileName) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      final result = ref
          .read(applicationRepositoryProvider)
          .importCsv(text, fileName: fileName);
      ref.read(dataVersionProvider.notifier).bump();
      setState(() => _importId = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.first
                ? '${result.total} applications loaded'
                : result.added + result.changed + result.removed == 0
                ? 'No changes since the last upload (${result.total} applications)'
                : [
                    if (result.changed > 0) '${result.changed} updated',
                    if (result.added > 0) '${result.added} new',
                    if (result.removed > 0) '${result.removed} removed',
                  ].join(' · '),
          ),
        ),
      );
    } on ApplicationCsvException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Couldn’t read that file'),
          content: Text(
            '${e.message}\n\nIn Airtable: open the Applications Tracker, '
            'Grid view, then the view menu › Download CSV.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dataVersionProvider);
    final repo = ref.read(applicationRepositoryProvider);
    final apps = repo.all();
    final imports = repo.imports();

    final page = LayoutBuilder(
      builder: (context, viewport) {
        final phone = viewport.maxWidth < 600;
        final pad = clarityHPad(context);
        if (apps.isNotEmpty && _view == _View.table) {
          // The table scrolls by itself, both ways.
          return Padding(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context, imports, phone),
                const SizedBox(height: 12),
                Expanded(
                  child: ApplicationsTable(
                    apps: apps,
                    onOpen: (a) => showApplicationDetails(context, ref, a),
                  ),
                ),
              ],
            ),
          );
        }
        final items = apps.isEmpty
            ? [_empty(context)]
            : _content(context, apps, imports, phone);
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
          itemCount: items.length,
          itemBuilder: (context, i) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
              child: items[i],
            ),
          ),
        );
      },
    );

    if (!widget.canUpload || !photoDropSupported) return page;
    // Windows: drop the CSV onto the page.
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        final csv = details.files
            .where((f) => f.name.toLowerCase().endsWith('.csv'))
            .firstOrNull;
        if (csv == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Drop the .csv file from Airtable.')),
          );
          return;
        }
        await _load(await csv.readAsBytes(), csv.name);
      },
      child: Stack(
        children: [
          page,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.10),
                  alignment: Alignment.center,
                  child: Text(
                    'Drop the Applications Tracker CSV',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The Airtable sync is on: applications come in by themselves, and
  /// "Sync now" fetches what changed straight away. The CSV upload stays as
  /// a fallback (a smaller button).
  bool get _airtable =>
      ref.watch(airtableStatusProvider).value?.enabled ?? false;

  Future<void> _syncNow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncing = true);
    try {
      final r = await ref.read(airtableSyncProvider).syncNow();
      if (!mounted) return;
      setState(() => _importId = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.error != null
                ? describeAirtableError(r.error!)
                : r.skipped == 'busy'
                ? 'A sync is already running — the changes appear in a moment.'
                : r.skipped != null
                ? 'The Airtable sync is switched off.'
                : r.nothingChanged
                ? 'Up to date with Airtable (${r.total} applications)'
                : [
                    if (r.changed > 0) '${r.changed} updated',
                    if (r.added > 0) '${r.added} new',
                    if (r.removed > 0) '${r.removed} removed',
                  ].join(' · '),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(describeAirtableError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Widget _uploadButton() {
    final spinner = const SizedBox.square(
      dimension: 14,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    if (_airtable) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('upload-applications'),
            tooltip: 'Upload a CSV instead',
            onPressed: _busy || _syncing ? null : _pickCsv,
            icon: _busy ? spinner : const Icon(Icons.upload_file, size: 18),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey('sync-airtable'),
            onPressed: _busy || _syncing ? null : _syncNow,
            icon: _syncing ? spinner : const Icon(Icons.sync, size: 16),
            label: const Text('Sync now'),
          ),
        ],
      );
    }
    return FilledButton.icon(
      key: const ValueKey('upload-applications'),
      onPressed: _busy ? null : _pickCsv,
      icon: _busy ? spinner : const Icon(Icons.upload_file, size: 16),
      label: const Text('Upload CSV'),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    return AppPanel(
      title: 'Applications',
      icon: Icons.school_outlined,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.canUpload
                  ? 'Upload the Applications Tracker from Airtable to see '
                        'every application here.'
                  : 'No applications yet. They appear here once the admin '
                        'uploads the Applications Tracker.',
              style: theme.textTheme.bodyMedium,
            ),
            if (widget.canUpload) ...[
              const SizedBox(height: 8),
              Text(
                'In Airtable: Applications Tracker › Grid view › view menu › '
                'Download CSV. Then upload that file'
                '${photoDropSupported ? ' (or drop it on this page)' : ''}. '
                'Each new upload shows what changed.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 16),
              _uploadButton(),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    List<Application> apps,
    List<ApplicationImport> imports,
    bool phone,
  ) {
    final now = DateTime.now();
    bool thisMonth(DateTime? d) =>
        d != null && d.year == now.year && d.month == now.month;
    final inProgress = apps.where((a) => a.inProgress).length;
    final offers = apps.where((a) => thisMonth(a.offerDate)).length;
    final coes = apps.where((a) => thisMonth(a.coeDate)).length;
    final done = apps
        .where((a) => ApplicationRepository.isDone(a.status))
        .length;
    final month = DateFormat('MMMM').format(now);
    final header = _header(context, imports, phone);

    if (_view == _View.quick) {
      return [
        header,
        const SizedBox(height: 14),
        ApplicationsQuickView(
          apps: apps,
          imports: imports,
          phone: phone,
          onShowAll: ({String? status, bool inProgress = false}) =>
              setState(() {
                _view = _View.list;
                _status = status;
                _inProgressOnly = inProgress;
                _country = _assignee = _rto = null;
                _offerOverdueOnly = false;
                _search.clear();
              }),
        ),
        const SizedBox(height: 12),
        _updatesPanel(context, imports),
      ];
    }

    final tiles = [
      _Stat(
        label: 'In progress',
        value: '$inProgress',
        caption: 'Not done, on hold or stopped',
        onTap: () => setState(() {
          _inProgressOnly = true;
          _status = null;
        }),
      ),
      _Stat(label: 'Offer letters', value: '$offers', caption: 'In $month'),
      _Stat(label: 'COEs issued', value: '$coes', caption: 'In $month'),
      _Stat(
        label: 'All applications',
        value: '${apps.length}',
        caption: '$done COE issued/done',
      ),
    ];

    return [
      header,
      const SizedBox(height: 12),
      _StatGrid(tiles: tiles, phone: phone),
      const SizedBox(height: 12),
      _stagePanel(context, apps),
      const SizedBox(height: 12),
      ..._listPanel(context, apps, phone),
    ];
  }

  Widget _header(
    BuildContext context,
    List<ApplicationImport> imports,
    bool phone,
  ) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final latest = imports.firstOrNull;
    final viewSwitch = SegmentedButton<_View>(
      key: const ValueKey('applications-view'),
      segments: [
        ButtonSegment(
          value: _View.quick,
          icon: phone ? null : const Icon(Icons.bolt_outlined, size: 16),
          label: Text(phone ? 'Quick' : 'Quick view'),
        ),
        ButtonSegment(
          value: _View.list,
          icon: phone ? null : const Icon(Icons.list_alt_outlined, size: 16),
          label: Text(phone ? 'List' : 'All applications'),
        ),
        ButtonSegment(
          value: _View.table,
          icon: phone ? null : const Icon(Icons.table_chart_outlined, size: 16),
          label: const Text('Table'),
        ),
      ],
      selected: {_view},
      showSelectedIcon: false,
      onSelectionChanged: (v) => setState(() => _view = v.first),
    );
    final airtable = ref.watch(airtableStatusProvider).value;
    final synced = airtable?.enabled ?? false;
    final warn = synced && airtable!.failing && widget.canUpload;
    final String? when = synced && airtable!.lastOkAt != null
        ? 'Synced from Airtable ${_when(airtable.lastOkAt!)}'
        : latest == null
        ? null
        : 'Updated ${_when(latest.at)}'
              '${latest.device.isEmpty ? '' : ' on ${latest.device}'}';
    final updated = when == null && !warn
        ? null
        : Tooltip(
            message: warn
                ? describeAirtableError(airtable.lastError!)
                : synced
                ? 'Airtable is read every 30 minutes on weekdays, hourly on '
                      'Saturdays, and in full every night.'
                : '',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (warn) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    warn ? 'Airtable sync isn’t working' : when!,
                    key: const ValueKey('applications-updated'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: warn ? theme.colorScheme.error : muted,
                    ),
                  ),
                ),
              ],
            ),
          );
    if (phone) {
      // Phones: the switch on its own line, then when + upload.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          viewSwitch,
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: updated ?? const SizedBox()),
              if (widget.canUpload) _uploadButton(),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        viewSwitch,
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: updated ?? const SizedBox(),
          ),
        ),
        if (widget.canUpload) ...[const SizedBox(width: 12), _uploadButton()],
      ],
    );
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final time = DateFormat('h:mm a').format(t);
    if (day == today) return 'today, $time';
    if (day == today.subtract(const Duration(days: 1))) {
      return 'yesterday, $time';
    }
    return '${DateFormat(t.year == now.year ? 'd MMM' : 'd MMM y').format(t)}, '
        '$time';
  }

  // ---- What changed --------------------------------------------------------

  Widget _updatesPanel(BuildContext context, List<ApplicationImport> imports) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final repo = ref.read(applicationRepositoryProvider);
    final shown =
        imports.where((i) => i.id == _importId).firstOrNull ??
        imports.firstOrNull;
    if (shown == null) return const SizedBox.shrink();
    final changes = repo.changesFor(shown.id);
    final byStudent = <String, List<ApplicationChange>>{};
    for (final c in changes) {
      byStudent.putIfAbsent(c.key, () => []).add(c);
    }
    final first = shown == imports.last && imports.length == 1;

    return AppPanel(
      title: 'Changes by upload',
      icon: Icons.notifications_active_outlined,
      trailingWidget: imports.length < 2
          ? null
          : DropdownButton<int>(
              key: const ValueKey('applications-upload-picker'),
              value: shown.id,
              underline: const SizedBox(),
              isDense: true,
              style: theme.textTheme.labelMedium,
              items: [
                for (final i in imports)
                  DropdownMenuItem(
                    value: i.id,
                    child: Text('Upload ${_when(i.at)}'),
                  ),
              ],
              onChanged: (id) => setState(() => _importId = id),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: byStudent.isEmpty
            ? Text(
                first || (shown.added == shown.total && shown.changed == 0)
                    ? 'First upload: ${shown.total} applications loaded. The '
                          'next upload will show what changed.'
                    : 'Nothing changed in this upload.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    [
                      if (shown.changed > 0) '${shown.changed} updated',
                      if (shown.added > 0) '${shown.added} new',
                      if (shown.removed > 0) '${shown.removed} removed',
                    ].join(' · '),
                    style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 6),
                  FirstFew(
                    key: ValueKey('changes-${shown.id}'),
                    children: [
                      for (final entry in byStudent.entries)
                        ApplicationUpdateRow(
                          student: entry.value.first.student,
                          changes: entry.value,
                          onTap: () => _openByKey(entry.key),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  void _openByKey(String key) {
    final app = ref
        .read(applicationRepositoryProvider)
        .all()
        .where((a) => a.key == key)
        .firstOrNull;
    if (app != null) showApplicationDetails(context, ref, app);
  }

  // ---- By stage --------------------------------------------------------------

  Widget _stagePanel(BuildContext context, List<Application> apps) {
    final theme = Theme.of(context);
    final counts = <String, int>{};
    for (final a in apps) {
      final s = a.status.isEmpty ? 'No status' : a.status;
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final stages = counts.keys.toList()
      ..sort(
        (a, b) =>
            ApplicationRepository.statusRank(a)
                .compareTo(ApplicationRepository.statusRank(b)),
      );
    final max = counts.values.fold<int>(1, (m, v) => v > m ? v : m);
    return AppPanel(
      title: 'By stage',
      icon: Icons.stacked_bar_chart,
      trailing: '${apps.length}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Column(
          children: [
            for (final s in stages)
              InkWell(
                onTap: () => setState(() {
                  _status = _status == s ? null : s;
                  _inProgressOnly = false;
                }),
                borderRadius: BorderRadius.circular(Dt.rSm),
                child: Tooltip(
                  message: '$s: ${counts[s]} — tap to list them',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 190,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TagChip(
                              s,
                              AirtableTags.status(s),
                              dense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, box) => Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                height: 12,
                                width: (box.maxWidth * counts[s]! / max).clamp(
                                  3,
                                  box.maxWidth,
                                ),
                                decoration: BoxDecoration(
                                  color: AirtableTags.statusColor(s),
                                  borderRadius: BorderRadius.circular(3),
                                  border: _status == s
                                      ? Border.all(
                                          color: theme.colorScheme.onSurface,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 34,
                          child: Text(
                            '${counts[s]}',
                            textAlign: TextAlign.right,
                            style: Dt.tab(theme.textTheme.labelLarge!),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- The list --------------------------------------------------------------

  List<Widget> _listPanel(
    BuildContext context,
    List<Application> apps,
    bool phone,
  ) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final q = _search.text.trim().toLowerCase();
    final now = DateTime.now();
    final shown = [
      for (final a in apps)
        if ((_status == null ||
                (a.status.isEmpty ? 'No status' : a.status) == _status) &&
            (_country == null || a.country == _country) &&
            (_assignee == null ||
                (_assignee == _noAssignee
                    ? a.assignee.isEmpty
                    : a.assignee == _assignee)) &&
            (_rto == null || a.rto == _rto) &&
            (!_inProgressOnly || a.inProgress) &&
            (!_offerOverdueOnly || a.offerOverdue(now)) &&
            (q.isEmpty ||
                '${a.student} ${a.rto} ${a.country} ${a.status} ${a.assignee} '
                        '${a.todo}'
                    .toLowerCase()
                    .contains(q)))
          a,
    ];
    final groups = <String, List<Application>>{};
    for (final a in shown) {
      groups
          .putIfAbsent(a.status.isEmpty ? 'No status' : a.status, () => [])
          .add(a);
    }
    final order = groups.keys.toList()
      ..sort(
        (a, b) =>
            ApplicationRepository.statusRank(a)
                .compareTo(ApplicationRepository.statusRank(b)),
      );
    // Any sort but "Stage" shows one flat list (each row with its status).
    int byDate(DateTime? x, DateTime? y, {bool newest = true}) {
      if (x == null && y == null) return 0;
      if (x == null) return 1; // undated last either way
      if (y == null) return -1;
      return newest ? y.compareTo(x) : x.compareTo(y);
    }

    final flat = [...shown]
      ..sort(
        (x, y) => switch (_sort) {
          _AppSort.stage => 0,
          _AppSort.name => x.student.toLowerCase().compareTo(
            y.student.toLowerCase(),
          ),
          _AppSort.appliedNewest => byDate(x.appDate, y.appDate),
          _AppSort.appliedOldest => byDate(x.appDate, y.appDate, newest: false),
          _AppSort.updated => byDate(x.updatedAt, y.updatedAt),
          _AppSort.milestone => byDate(x.lastStep, y.lastStep),
          _AppSort.offerWait => (y.offerWaitDays(now) ?? -1).compareTo(
            x.offerWaitDays(now) ?? -1,
          ),
        },
      );

    List<String> options(String Function(Application) f) =>
        (apps.map(f).where((v) => v.isNotEmpty).toSet().toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));

    Widget filter(
      String label,
      String? value,
      List<String> values,
      ValueChanged<String?> onChanged,
    ) => SizedBox(
      width: phone ? double.infinity : 200,
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        isExpanded: true,
        isDense: true,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          const DropdownMenuItem(value: null, child: Text('All')),
          for (final v in values)
            DropdownMenuItem(
              value: v,
              child: Text(v, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );

    final filters = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: phone ? double.infinity : 260,
          child: TextField(
            key: const ValueKey('applications-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Student, school, note…',
              isDense: true,
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        filter(
          'Status',
          _status,
          options((a) => a.status.isEmpty ? 'No status' : a.status)..sort(
            (a, b) =>
                ApplicationRepository.statusRank(a)
                    .compareTo(ApplicationRepository.statusRank(b)),
          ),
          (v) => setState(() => _status = v),
        ),
        filter(
          'Country',
          _country,
          options((a) => a.country),
          (v) => setState(() => _country = v),
        ),
        filter('Assignee', _assignee, [
          ...options((a) => a.assignee),
          if (apps.any((a) => a.assignee.isEmpty)) _noAssignee,
        ], (v) => setState(() => _assignee = v)),
        filter(
          'Institution',
          _rto,
          options((a) => a.rto),
          (v) => setState(() => _rto = v),
        ),
        SizedBox(
          width: phone ? double.infinity : 230,
          child: DropdownButtonFormField<_AppSort>(
            key: const ValueKey('applications-sort'),
            initialValue: _sort,
            isExpanded: true,
            isDense: true,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              labelText: 'Sort by',
              isDense: true,
              prefixIcon: Icon(Icons.sort, size: 18),
            ),
            items: [
              for (final s in _AppSort.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
            onChanged: (v) => setState(() => _sort = v ?? _AppSort.stage),
          ),
        ),
        FilterChip(
          key: const ValueKey('applications-in-progress'),
          label: const Text('In progress only'),
          selected: _inProgressOnly,
          onSelected: (v) => setState(() => _inProgressOnly = v),
        ),
        FilterChip(
          key: const ValueKey('applications-offer-overdue'),
          avatar: const Icon(Icons.notifications_active_outlined, size: 16),
          label: Text(
            'Offer letter overdue '
            '(${apps.where((a) => a.offerOverdue(now)).length})',
          ),
          selected: _offerOverdueOnly,
          onSelected: (v) => setState(() => _offerOverdueOnly = v),
        ),
      ],
    );

    final filtered =
        _status != null ||
        _country != null ||
        _assignee != null ||
        _rto != null ||
        _inProgressOnly ||
        _offerOverdueOnly ||
        q.isNotEmpty;

    return [
      AppPanel(
        // Keyed by the filters so the dropdowns show the current choice.
        key: ValueKey(
          'apps-$_status-$_country-$_assignee-$_rto-$_inProgressOnly-'
          '$_offerOverdueOnly-$_sort',
        ),
        title: 'Applications',
        icon: Icons.school_outlined,
        trailing: filtered
            ? '${shown.length} of ${apps.length}'
            : '${apps.length}',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              filters,
              if (filtered) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _status = _country = _assignee = _rto = null;
                    _inProgressOnly = _offerOverdueOnly = false;
                    _search.clear();
                  }),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                  label: const Text('Clear filters'),
                ),
              ],
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'No applications match.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
      // Rows are separate list items so a long list scrolls smoothly.
      if (_sort != _AppSort.stage) ...[
        const SizedBox(height: 10),
        for (final a in flat)
          ApplicationRow(
            app: a,
            phone: phone,
            showStatus: true,
            onTap: () => showApplicationDetails(context, ref, a),
          ),
      ] else
        for (final s in order) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Row(
              children: [
                TagChip(s, AirtableTags.status(s)),
                const SizedBox(width: 8),
                Text(
                  '${groups[s]!.length}',
                  style: theme.textTheme.labelLarge?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          for (final a in groups[s]!)
            ApplicationRow(
              app: a,
              phone: phone,
              onTap: () => showApplicationDetails(context, ref, a),
            ),
        ],
    ];
  }
}

/// The newest milestone reached: "COE 15 Jan 2026", "Offer 4 Sep 2025"…
String applicationMilestone(Application a) {
  String d(DateTime t) =>
      DateFormat(t.year == DateTime.now().year ? 'd MMM' : 'd MMM y').format(t);
  if (a.coeDate != null) return 'COE ${d(a.coeDate!)}';
  if (a.offerDate != null) return 'Offer ${d(a.offerDate!)}';
  if (a.appDate != null) return 'Applied ${d(a.appDate!)}';
  if (a.docDate != null) return 'Docs ${d(a.docDate!)}';
  return '';
}

/// One application in the list: name, school, country, who handles it,
/// the latest milestone and the to-do note.
class ApplicationRow extends StatelessWidget {
  const ApplicationRow({
    super.key,
    required this.app,
    required this.phone,
    required this.onTap,
    this.showStatus = false,
  });

  final Application app;
  final bool phone;
  final VoidCallback onTap;

  /// Show the status too (in a flat, sorted list rather than grouped).
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final scheme = theme.colorScheme;
    final milestone = applicationMilestone(app);
    final wait = app.offerOverdue(DateTime.now())
        ? app.offerWaitDays(DateTime.now())
        : null;
    final tags = Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (wait != null)
          Tooltip(
            message: 'Waiting $wait days for an offer letter',
            child: StatusPill('Offer: $wait days', tone: PillTone.warning),
          ),
        if (showStatus && app.status.isNotEmpty)
          TagChip(app.status, AirtableTags.status(app.status), dense: true),
        if (app.rto.isNotEmpty)
          TagChip(app.rto, AirtableTags.rto(app.rto), dense: true),
        if (app.country.isNotEmpty)
          TagChip(app.country, AirtableTags.country(app.country), dense: true),
        if (app.assignee.isNotEmpty)
          TagChip(
            app.assignee,
            AirtableTags.assignee(app.assignee),
            dense: true,
          ),
      ],
    );
    final note = app.todo.isEmpty
        ? null
        : Text(
            app.todo.replaceAll(RegExp(r'\s+'), ' '),
            maxLines: phone ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          );
    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            app.student,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (milestone.isNotEmpty)
                          Text(
                            milestone,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: muted,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    tags,
                    if (note != null) ...[const SizedBox(height: 4), note],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 200,
                      child: Text(
                        app.student,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(width: 280, child: tags),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: Text(milestone, style: theme.textTheme.bodySmall),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: note ?? const SizedBox()),
                  ],
                ),
        ),
      ),
    );
  }
}

/// What changed for one student in an upload, in words and tags.
class ApplicationUpdateRow extends StatelessWidget {
  const ApplicationUpdateRow({
    super.key,
    required this.student,
    required this.changes,
    this.onTap,
    this.dense = false,
  });

  final String student;
  final List<ApplicationChange> changes;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Dt.rSm),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 5 : 7, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(student, style: theme.textTheme.titleSmall),
            const SizedBox(height: 3),
            for (final c in changes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: describeApplicationChange(context, c, muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// One change as a line: tags for statuses, plain words for the rest.
Widget describeApplicationChange(
  BuildContext context,
  ApplicationChange c,
  Color muted,
) {
  final theme = Theme.of(context);
  final small = theme.textTheme.bodySmall!;
  String date(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : DateFormat('d MMM y').format(d);
  }

  Widget words(String s) => Text(s, style: small);
  Widget line(List<Widget> parts) => Wrap(
    spacing: 6,
    runSpacing: 3,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: parts,
  );

  switch (c.field) {
    case 'added':
      return line([
        words('New application'),
        if (c.newValue.isNotEmpty)
          TagChip(c.newValue, AirtableTags.status(c.newValue), dense: true),
      ]);
    case 'removed':
      return line([
        words('No longer in the tracker'),
        if (c.oldValue.isNotEmpty) ...[
          words('(was'),
          TagChip(c.oldValue, AirtableTags.status(c.oldValue), dense: true),
          words(')'),
        ],
      ]);
    case 'status':
      return line([
        words('Status'),
        if (c.oldValue.isNotEmpty)
          Opacity(
            opacity: 0.55,
            child: TagChip(
              c.oldValue,
              AirtableTags.status(c.oldValue),
              dense: true,
            ),
          ),
        words(c.oldValue.isEmpty ? 'set to' : 'to'),
        TagChip(c.newValue, AirtableTags.status(c.newValue), dense: true),
      ]);
    case 'doc_date' || 'app_date' || 'offer_date' || 'coe_date':
      final label = ApplicationRepository.fieldLabels[c.field]!;
      return words(
        c.newValue.isEmpty
            ? '$label date cleared'
            : c.oldValue.isEmpty
            ? '$label ${date(c.newValue)}'
            : '$label changed from ${date(c.oldValue)} to ${date(c.newValue)}',
      );
    case 'todo' || 'follow_up':
      final label = ApplicationRepository.fieldLabels[c.field]!;
      return Text(
        c.newValue.isEmpty
            ? '$label cleared'
            : '$label: ${c.newValue.replaceAll(RegExp(r'\s+'), ' ')}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: small.copyWith(color: muted),
      );
    default:
      final label = ApplicationRepository.fieldLabels[c.field] ?? c.field;
      return words(
        c.newValue.isEmpty
            ? '$label cleared (was ${c.oldValue})'
            : c.oldValue.isEmpty
            ? '$label: ${c.newValue}'
            : '$label changed from ${c.oldValue} to ${c.newValue}',
      );
  }
}

/// Everything about one application, with its history of changes.
Future<void> showApplicationDetails(
  BuildContext context,
  WidgetRef ref,
  Application a,
) {
  final history = ref.read(applicationRepositoryProvider).historyOf(a.key);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final muted = Dt.textMuted(theme);
      String d(DateTime? t) =>
          t == null ? '—' : DateFormat('d MMM y').format(t);
      Widget field(String label, Widget value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            Expanded(child: value),
          ],
        ),
      );
      Widget text(String s) =>
          Text(s.isEmpty ? '—' : s, style: theme.textTheme.bodyMedium);
      return AlertDialog(
        title: Text(a.student),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (a.offerWaitDays(DateTime.now()) case final days?
                    when a.offerOverdue(DateTime.now())) ...[
                  OfferReminderBox(app: a, days: days),
                  const SizedBox(height: 12),
                ],
                field(
                  'Status',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: a.status.isEmpty
                        ? text('')
                        : TagChip(a.status, AirtableTags.status(a.status)),
                  ),
                ),
                field(
                  'RTO',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: a.rto.isEmpty
                        ? text('')
                        : TagChip(a.rto, AirtableTags.rto(a.rto)),
                  ),
                ),
                field(
                  'Country',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: a.country.isEmpty
                        ? text('')
                        : TagChip(a.country, AirtableTags.country(a.country)),
                  ),
                ),
                field(
                  'Assignee',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: a.assignee.isEmpty
                        ? text('')
                        : TagChip(
                            a.assignee,
                            AirtableTags.assignee(a.assignee),
                          ),
                  ),
                ),
                field('Documents submitted', text(d(a.docDate))),
                field('Application submitted', text(d(a.appDate))),
                field('Offer letter received', text(d(a.offerDate))),
                field('COE issued', text(d(a.coeDate))),
                field('To do', text(a.todo)),
                if (a.followUp.isNotEmpty) field('Follow-up', text(a.followUp)),
                const SizedBox(height: 10),
                Text('History', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (history.isEmpty)
                  Text(
                    'No changes since it was first uploaded.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  )
                else
                  for (final h in history)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 90,
                            child: Text(
                              DateFormat('d MMM y').format(h.at),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
                              ),
                            ),
                          ),
                          Expanded(
                            child: describeApplicationChange(context, h, muted),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.caption,
    this.onTap,
  });

  final String label;
  final String value;
  final String caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: Dt.tab(theme.textTheme.headlineMedium!)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two tiles a row on phones, four otherwise, equal heights.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.tiles, required this.phone});
  final List<Widget> tiles;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final perRow = phone ? 2 : 4;
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += perRow) ...[
          if (i > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = i; j < i + perRow; j++) ...[
                  if (j > i) const SizedBox(width: 10),
                  Expanded(
                    child: j < tiles.length ? tiles[j] : const SizedBox(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

enum _View { quick, list, table }

/// "Waiting 12 days for an offer letter": shown on an application whose
/// offer letter is overdue (more than a week since it was submitted).
class OfferReminderBox extends StatelessWidget {
  const OfferReminderBox({super.key, required this.app, required this.days});
  final Application app;
  final int days;

  @override
  Widget build(BuildContext context) {
    final c = context.clarity;
    return Container(
      key: const ValueKey('offer-reminder'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.noticeBg,
        border: Border.all(color: c.noticeBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.notifications_active_outlined,
            size: 18,
            color: c.noticeFg,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Waiting $days days for an offer letter',
                  style: TextStyle(
                    fontFamily: Dt.font,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.noticeFg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Submitted ${DateFormat('d MMM y').format(app.appDate!)}'
                  '${app.rto.isEmpty ? '' : ' to ${app.rto}'}. Follow up '
                  'with the institution'
                  '${app.assignee.isEmpty ? '' : ' (${app.assignee})'}.',
                  style: TextStyle(
                    fontFamily: Dt.font,
                    fontSize: 13,
                    height: 1.45,
                    color: c.noticeFg,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "No assignee" in the Assignee filter.
const _noAssignee = 'No assignee';

/// How the All applications list is ordered.
enum _AppSort {
  stage('Stage (grouped)'),
  name('Student name (A–Z)'),
  appliedNewest('Applied: newest first'),
  appliedOldest('Applied: oldest first'),
  updated('Recently updated'),
  milestone('Latest milestone'),
  offerWait('Waiting longest for offer');

  const _AppSort(this.label);
  final String label;
}
