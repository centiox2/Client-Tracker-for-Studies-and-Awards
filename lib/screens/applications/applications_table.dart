import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/airtable_tags.dart';
import '../../design/app_theme.dart';
import '../../repositories/application_repository.dart';

/// Every application with every column, like the Airtable grid: sortable by
/// any column (tap its heading), searchable, filterable by status, scrolling
/// sideways for the wide columns. Tap a row for the details and history.
class ApplicationsTable extends StatefulWidget {
  const ApplicationsTable({
    super.key,
    required this.apps,
    required this.onOpen,
  });

  final List<Application> apps;
  final ValueChanged<Application> onOpen;

  @override
  State<ApplicationsTable> createState() => _ApplicationsTableState();
}

class _Column {
  const _Column(this.label, this.width, this.sortKey, this.cell);
  final String label;
  final double width;

  /// What the column sorts by (null: not sortable).
  final Comparable<Object>? Function(Application)? sortKey;
  final Widget Function(BuildContext, Application) cell;
}

class _ApplicationsTableState extends State<ApplicationsTable> {
  final _search = TextEditingController();
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  String? _status;

  /// The column sorted by, and which way (null: Airtable's order).
  int? _sortColumn;
  bool _ascending = true;

  static const _rowHeight = 50.0;

  @override
  void dispose() {
    _search.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  static String _date(DateTime? d) =>
      d == null ? '' : DateFormat('d MMM y').format(d);

  static Comparable<Object>? _dateKey(DateTime? d) => d?.millisecondsSinceEpoch;

  static Comparable<Object>? _text(String s) =>
      s.isEmpty ? null : s.toLowerCase();

  List<_Column> _columns() {
    Widget text(String s, {int lines = 1, bool muted = false}) => Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Text(
          s,
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: muted ? Dt.textMuted(theme) : theme.colorScheme.onSurface,
          ),
        );
      },
    );
    Widget tag(String s, (Color, Color) colors) => Align(
      alignment: Alignment.centerLeft,
      child: TagChip(s, colors, dense: true),
    );

    return [
      _Column(
        'Student name',
        210,
        (a) => _text(a.student),
        (c, a) => Text(
          a.student,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(c).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      _Column(
        'RTO name',
        170,
        (a) => _text(a.rto),
        (c, a) => tag(a.rto, AirtableTags.rto(a.rto)),
      ),
      _Column(
        'Country',
        120,
        (a) => _text(a.country),
        (c, a) => tag(a.country, AirtableTags.country(a.country)),
      ),
      _Column(
        'Doc submit date',
        118,
        (a) => _dateKey(a.docDate),
        (c, a) => text(_date(a.docDate)),
      ),
      _Column(
        'App submitted date',
        118,
        (a) => _dateKey(a.appDate),
        (c, a) => text(_date(a.appDate)),
      ),
      _Column(
        'Offer letter received date',
        118,
        (a) => _dateKey(a.offerDate),
        (c, a) => text(_date(a.offerDate)),
      ),
      _Column(
        'COE issue date',
        118,
        (a) => _dateKey(a.coeDate),
        (c, a) => text(_date(a.coeDate)),
      ),
      _Column(
        'Status',
        240,
        (a) => ApplicationRepository.statusRank(a.status),
        (c, a) => tag(a.status, AirtableTags.status(a.status)),
      ),
      _Column(
        'Assignee',
        110,
        (a) => _text(a.assignee),
        (c, a) => tag(a.assignee, AirtableTags.assignee(a.assignee)),
      ),
      _Column(
        'To do list',
        380,
        (a) => _text(a.todo),
        (c, a) => text(a.todo.replaceAll(RegExp(r'\s*\n\s*'), ' · '), lines: 2),
      ),
      _Column(
        'Follow up update',
        240,
        (a) => _text(a.followUp),
        (c, a) => text(a.followUp, lines: 2, muted: true),
      ),
    ];
  }

  void _sortBy(int i) => setState(() {
    if (_sortColumn != i) {
      _sortColumn = i;
      _ascending = true;
    } else if (_ascending) {
      _ascending = false;
    } else {
      _sortColumn = null; // back to Airtable's order
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = Dt.textMuted(theme);
    final columns = _columns();
    const numberWidth = 52.0;
    final width = numberWidth + columns.fold<double>(0, (s, c) => s + c.width);

    // Airtable's order: by status (its groups), then the file's order.
    final q = _search.text.trim().toLowerCase();
    final rows =
        [
          for (final a in widget.apps)
            if ((_status == null || a.status == _status) &&
                (q.isEmpty ||
                    '${a.student} ${a.rto} ${a.country} ${a.status} ${a.assignee} '
                            '${a.todo} ${a.followUp}'
                        .toLowerCase()
                        .contains(q)))
              a,
        ]..sort((x, y) {
          final r = ApplicationRepository.statusRank(x.status)
              .compareTo(ApplicationRepository.statusRank(y.status));
          return r != 0 ? r : x.position.compareTo(y.position);
        });
    if (_sortColumn case final i?) {
      final key = columns[i].sortKey!;
      // Stable, with empty cells always last.
      final indexed = rows.indexed.toList()
        ..sort((p, r) {
          final kp = key(p.$2), kr = key(r.$2);
          if (kp == null && kr == null) return p.$1.compareTo(r.$1);
          if (kp == null) return 1;
          if (kr == null) return -1;
          final c = _ascending ? kp.compareTo(kr) : kr.compareTo(kp);
          return c != 0 ? c : p.$1.compareTo(r.$1);
        });
      rows
        ..clear()
        ..addAll(indexed.map((e) => e.$2));
    }

    final statuses =
        {
          for (final a in widget.apps)
            if (a.status.isNotEmpty) a.status,
        }.toList()..sort(
          (x, y) =>
              ApplicationRepository.statusRank(x)
                  .compareTo(ApplicationRepository.statusRank(y)),
        );

    final toolbar = Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 260,
          child: TextField(
            key: const ValueKey('table-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Search the table',
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
        SizedBox(
          width: 230,
          child: DropdownButtonFormField<String?>(
            initialValue: _status,
            isExpanded: true,
            isDense: true,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              labelText: 'Status',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('All')),
              for (final s in statuses)
                DropdownMenuItem(
                  value: s,
                  child: Text(s, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _status = v),
          ),
        ),
        Text(
          rows.length == widget.apps.length
              ? '${rows.length} rows'
              : '${rows.length} of ${widget.apps.length} rows',
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
        if (_sortColumn != null)
          TextButton.icon(
            onPressed: () => setState(() => _sortColumn = null),
            icon: const Icon(Icons.sort, size: 16),
            label: const Text('Airtable order'),
          ),
      ],
    );

    Widget cellBox(double w, Widget child) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );

    final header = Container(
      height: 46,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        children: [
          cellBox(
            numberWidth,
            Text(
              '#',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
          for (final (i, c) in columns.indexed)
            InkWell(
              key: ValueKey('table-sort-${c.label}'),
              onTap: c.sortKey == null ? null : () => _sortBy(i),
              child: cellBox(
                c.width,
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_sortColumn == i)
                      Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 13,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    final body = rows.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'No applications match.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          )
        : Scrollbar(
            controller: _vertical,
            child: ListView.builder(
              controller: _vertical,
              itemExtent: _rowHeight,
              itemCount: rows.length,
              itemBuilder: (context, r) {
                final a = rows[r];
                return Material(
                  color: r.isEven
                      ? scheme.surfaceContainerLow
                      : scheme.surfaceContainerLowest,
                  child: InkWell(
                    onTap: () => widget.onOpen(a),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: scheme.outline.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          cellBox(
                            numberWidth,
                            Text(
                              '${r + 1}',
                              style: Dt.tab(theme.textTheme.labelSmall!)
                                  .copyWith(color: muted),
                            ),
                          ),
                          for (final c in columns)
                            cellBox(c.width, c.cell(context, a)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outline),
              borderRadius: BorderRadius.circular(Dt.rMd),
            ),
            child: Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              notificationPredicate: (n) => n.depth == 0,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: Column(
                    children: [
                      header,
                      Expanded(child: body),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
