import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/client_count_repository.dart';
import '../../state/app_state.dart';

/// Every edit to a client number — which staff member's day, from what to
/// what, and when — newest first. [weekId] opens it on one week; the week
/// can be switched to any earlier week, or to all weeks, from the dialog.
Future<void> showChangeHistory(
  BuildContext context, {
  int? weekId,
  String? title,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ChangeHistoryDialog(weekId: weekId, title: title),
);

class _ChangeHistoryDialog extends ConsumerStatefulWidget {
  const _ChangeHistoryDialog({this.weekId, this.title});

  final int? weekId;
  final String? title;

  @override
  ConsumerState<_ChangeHistoryDialog> createState() =>
      _ChangeHistoryDialogState();
}

class _ChangeHistoryDialogState extends ConsumerState<_ChangeHistoryDialog> {
  String? _staff;

  /// The week shown; null for every week.
  late int? _week = widget.weekId;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dataVersionProvider);
    final all = ref
        .read(clientCountRepositoryProvider)
        .changes(weekId: _week, limit: _week == null ? 2000 : 500);
    final weeks = ref.watch(historyProvider);
    final names = {for (final c in all) c.staffName}.toList()..sort();
    final shown = _staff == null
        ? all
        : all.where((c) => c.staffName == _staff).toList();
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.manage_history,
                    size: 18,
                    color: Dt.textMuted(theme),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _week == null
                          ? 'Change history · all weeks'
                          : _week == widget.weekId && widget.title != null
                          ? widget.title!
                          : 'Change history',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Every change to a client number, newest first. Quick '
                    're-edits of the same cell count as one change.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Dt.textMuted(theme),
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<int?>(
                      key: const ValueKey('change-history-week'),
                      initialValue: _week,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Week',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All weeks'),
                        ),
                        for (final w in weeks)
                          DropdownMenuItem(
                            value: w.week.id,
                            child: Text(
                              '${DateFormat('d MMM').format(w.week.startDate)}'
                              ' – '
                              '${DateFormat('d MMM y').format(w.week.endDate)}',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _week = v;
                        _staff = null;
                      }),
                    ),
                  ),
                  if (names.length > 1)
                    SizedBox(
                      key: ValueKey('staff-filter-$_week'),
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _staff,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Staff',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Everyone'),
                          ),
                          for (final n in names)
                            DropdownMenuItem(value: n, child: Text(n)),
                        ],
                        onChanged: (v) => setState(() => _staff = v),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Text(
                        _week == null
                            ? 'No changes recorded yet.'
                            : 'No changes in this week. Pick “All weeks” '
                                  'to see every change.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Dt.textMuted(theme),
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        itemCount: shown.length,
                        itemBuilder: (context, i) => _ChangeRow(
                          change: shown[i],
                          showDate:
                              i == 0 ||
                              !_sameDay(
                                shown[i - 1].changedAt,
                                shown[i].changedAt,
                              ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change, required this.showDate});

  final CountChange change;

  /// First change on a new calendar day: show a date heading above it.
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final c = change;
    final small = theme.textTheme.labelSmall?.copyWith(color: muted);

    Widget part(String label, int from, int to, Color color) {
      final changed = from != to;
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: changed ? '$from to $to' : '$to',
              style: TextStyle(
                color: changed ? color : muted,
                fontWeight: changed ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
        style: Dt.tab(theme.textTheme.labelMedium!).copyWith(color: muted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showDate)
          Container(
            color: theme.colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Text(
              _sameDay(c.changedAt, DateTime.now())
                  ? 'Today'
                  : DateFormat('EEEE d MMMM y').format(c.changedAt),
              style: microLabel(theme),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  DateFormat('HH:mm').format(c.changedAt),
                  style: Dt.tab(theme.textTheme.labelMedium!)
                      .copyWith(color: muted),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.staffName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Numbers for '
                      '${DateFormat(c.day.year == DateTime.now().year ? 'EEE d MMM' : 'EEE d MMM y').format(c.day)}',
                      style: small,
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: 14,
                children: [
                  part(
                    'New',
                    c.oldNew,
                    c.newNew,
                    Dt.newGreen(theme.brightness),
                  ),
                  part(
                    'Existing',
                    c.oldExisting,
                    c.newExisting,
                    Dt.existingBlue(theme.brightness),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
