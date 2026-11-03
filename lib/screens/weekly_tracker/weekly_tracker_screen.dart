import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../models/staff.dart';
import '../../repositories/client_count_repository.dart';
import '../../services/export_actions.dart';
import '../../state/app_state.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/motion.dart';
import '../../widgets/numeric_field.dart';
import '../../widgets/panels.dart';
import '../history/change_history_dialog.dart';
import 'day_off_dialog.dart';
import 'future_day_guard.dart';
import 'new_week_dialog.dart';
import 'time_off_dialog.dart';

class WeeklyTrackerScreen extends ConsumerStatefulWidget {
  const WeeklyTrackerScreen({super.key, this.initialWeekId});

  final int? initialWeekId;

  @override
  ConsumerState<WeeklyTrackerScreen> createState() =>
      _WeeklyTrackerScreenState();
}

class _WeeklyTrackerScreenState extends ConsumerState<WeeklyTrackerScreen> {
  int? _selectedDayId;

  @override
  void initState() {
    super.initState();
    if (widget.initialWeekId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(currentWeekIdProvider.notifier).set(widget.initialWeekId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(currentWeekProvider);

    if (data == null) {
      return EmptyState(
        icon: Icons.calendar_today,
        title: 'No week selected',
        message: 'Create a new week or open one from History.',
        actionLabel: 'New Week',
        onAction: () => showNewWeekDialog(context, ref),
      );
    }

    // Keep the full week visible on a wide viewport; switch to the focused
    // one-day layout on phones and narrow tablets.
    final isDesktop = MediaQuery.sizeOf(context).width >= 920;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: isDesktop
              ? _EditorialBoard(data: data)
              : _MobileWeekView(
                  data: data,
                  selectedDayId: _selectedDayId,
                  onSelectDay: (id) => setState(() => _selectedDayId = id),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- header ----

/// Opens the week starting [monday] if it exists; otherwise offers to start
/// it through the New week dialog. Browsing never creates weeks by itself —
/// empty weeks made by accident cluttered History and Reports.
Future<void> openOrOfferWeek(
  BuildContext context,
  WidgetRef ref,
  DateTime monday,
) async {
  final existing = ref.read(weekRepositoryProvider).findByStartDate(monday);
  if (existing != null) {
    ref.read(currentWeekIdProvider.notifier).set(existing.id);
    return;
  }
  await showNewWeekDialog(context, ref, initialMonday: monday);
}

// ---------------------------------------------------------------- board -----

/// The desktop "editorial board": compact serif header, then the full
/// staff × day grid — sized to fit the viewport so names and every cell are
/// visible (and editable) without scrolling — with a pinned DAY TOTAL footer
/// and the analytics rail (by day / most clients / client mix) on the right.
class _EditorialBoard extends ConsumerStatefulWidget {
  const _EditorialBoard({required this.data});

  final CurrentWeekData data;

  @override
  ConsumerState<_EditorialBoard> createState() => _EditorialBoardState();
}

class _EditorialBoardState extends ConsumerState<_EditorialBoard> {
  final Map<String, FocusNode> _focusNodes = {};

  // Explicit controllers: the board has two vertical scrollables (staff rows
  // + analytics rail) and they must not fight over the primary one.
  final _rowsController = ScrollController();
  final _railController = ScrollController();

  FocusNode _nodeFor(int staffId, int dayIndex, bool isNew) {
    final key = '$staffId-$dayIndex-${isNew ? 'n' : 'e'}';
    return _focusNodes.putIfAbsent(key, FocusNode.new);
  }

  FocusNode _nextAfter(int staffId, int dayIndex, bool isNew) {
    if (!isNew) return _nodeFor(staffId, dayIndex + 1, true);
    return _nodeFor(staffId, dayIndex, false);
  }

  /// Built rows by staff id, with the signature they were built from.
  final Map<int, (String, Widget)> _rows = {};

  /// The row for [staff]. Typing one number used to rebuild all 140 cells
  /// on the board; now only the row whose numbers changed is rebuilt — the
  /// others are returned as the identical widget, which Flutter skips.
  Widget _rowFor(
    CurrentWeekData data,
    NamedClientCount staff, {
    required double rowHeight,
    required double fieldHeight,
    required double fieldFontSize,
  }) {
    final now = DateTime.now();
    final sig = StringBuffer()
      ..write(staff.staffName)
      ..write('|${data.week.id}|${data.week.showZeros}')
      ..write('|$rowHeight|$fieldHeight|$fieldFontSize')
      ..write('|${now.year}-${now.month}-${now.day}');
    for (final d in data.days) {
      final c = d.countFor(staff.staffId);
      sig.write(
        '|${d.day.id}:${c.newClients}:${c.existingClients}'
        ':${d.isOff(staff.staffId)}:${d.isHoliday}',
      );
    }
    final key = sig.toString();
    final cached = _rows[staff.staffId];
    if (cached != null && cached.$1 == key) return cached.$2;
    final row = _BoardStaffRow(
      key: ValueKey('staff-${staff.staffId}'),
      data: data,
      staff: staff,
      nodeFor: _nodeFor,
      nextAfter: _nextAfter,
      rowHeight: rowHeight,
      fieldHeight: fieldHeight,
      fieldFontSize: fieldFontSize,
    );
    _rows[staff.staffId] = (key, row);
    return row;
  }

  @override
  void initState() {
    super.initState();
    // Open ready to type: the cursor goes to today's first "New" cell (the
    // first person working today) when this week contains today.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final days = widget.data.days;
      final now = DateTime.now();
      final todayIndex = days.indexWhere((d) => _sameDay(d.day.date, now));
      if (todayIndex < 0) return;
      final today = days[todayIndex];
      final first = today.rows.where((r) => !today.isOff(r.staffId));
      if (first.isEmpty) return;
      _nodeFor(first.first.staffId, todayIndex, true).requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _rowsController.dispose();
    _railController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final theme = Theme.of(context);
    final now = DateTime.now();

    final summary =
        '${data.totals.newClients} new · '
        '${data.totals.existingClients} existing · '
        '${data.totals.total} total · '
        'avg ${data.totals.dailyAverage.toStringAsFixed(1)}/day';
    final thisMonday = _mondayOf(now);
    final onThisWeek = data.week.startDate == thisMonday;
    // Arrows step between weeks that exist; past the newest one, "next"
    // offers to start the following week instead of silently creating it.
    final weeks = ref.read(weekRepositoryProvider);
    final previousWeek = weeks.adjacentWeek(
      data.week.startDate,
      forward: false,
    );
    final nextWeek = weeks.adjacentWeek(data.week.startDate, forward: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _boardMaxWidth),
              child: Row(
                children: [
                  _RoundIconButton(
                    icon: Icons.chevron_left,
                    tooltip: previousWeek == null
                        ? 'No earlier weeks'
                        : 'Previous week',
                    onPressed: previousWeek == null
                        ? null
                        : () => ref
                              .read(currentWeekIdProvider.notifier)
                              .set(previousWeek.id),
                  ),
                  const SizedBox(width: 4),
                  _RoundIconButton(
                    icon: Icons.chevron_right,
                    tooltip: nextWeek == null
                        ? 'Start next week…'
                        : 'Next week',
                    onPressed: nextWeek == null
                        ? () => openOrOfferWeek(
                            context,
                            ref,
                            data.week.startDate.add(const Duration(days: 7)),
                          )
                        : () => ref
                              .read(currentWeekIdProvider.notifier)
                              .set(nextWeek.id),
                  ),
                  const SizedBox(width: 12),
                  // The date range is already in the week picker directly
                  // above; the week number is what the arrows step through.
                  Text(
                    'Week ${_isoWeekNumber(data.week.startDate)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!onThisWeek) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () =>
                          openOrOfferWeek(context, ref, thisMonday),
                      child: const Text('Go to this week'),
                    ),
                  ],
                  const Spacer(),
                  const _SavedIndicator(),
                  const SizedBox(width: 14),
                  // Shrinks (with an ellipsis) rather than overflowing when
                  // "Go to this week" and the saved time are both showing.
                  Flexible(
                    flex: 100,
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Dt.tab(theme.textTheme.labelSmall!)
                          .copyWith(color: Dt.textMuted(theme)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const _ShowZerosToggle(),
                  _WeekMenu(week: data.week),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _boardMaxWidth),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const railWidth = 270.0;
                    const railGap = 14.0;
                    const headerH = 58.0;
                    const footerH = _footerHeight + 1;
                    // Give the entry grid the available width on ordinary
                    // laptop screens. The analytics rail moves below it until
                    // there is enough room for both without compressing cells.
                    final showRail = constraints.maxWidth >= 1380;
                    final staffCount = data.days.isEmpty
                        ? 0
                        : data.days.first.rows.length;
                    // Fit the board to the viewport: split the rows region
                    // between the staff and size the fields to match. Below the
                    // 34px floor the rows scroll instead of becoming cramped.
                    final rowsH = (constraints.maxHeight - headerH - footerH)
                        .clamp(0.0, double.infinity)
                        .toDouble();
                    final rowHeight =
                        (staffCount == 0 ? 42.0 : rowsH / staffCount)
                            .clamp(34.0, 48.0)
                            .toDouble();
                    final fieldHeight = (rowHeight - 6)
                        .clamp(26.0, 34.0)
                        .toDouble();
                    const fieldFontSize = 13.0;
                    final board = Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        border: Border.all(color: theme.colorScheme.outline),
                        borderRadius: BorderRadius.circular(Dt.rMd),
                      ),
                      child: _BoardTable(
                        data: data,
                        rowFor: _rowFor,
                        rowsController: _rowsController,
                        rowHeight: rowHeight,
                        fieldHeight: fieldHeight,
                        fieldFontSize: fieldFontSize,
                        needsScroll:
                            staffCount > 0 && rowsH / staffCount < 34.0,
                      ),
                    );
                    final rail = _AnalyticsRail(data: data, now: now);

                    if (!showRail) {
                      // The board contains `Expanded`s, so it needs a bounded
                      // height inside the ListView. The board draws its own
                      // header/footer, so it takes the full height here (the
                      // rowHeight math above already accounts for them); the
                      // analytics rail scrolls below.
                      return ListView(
                        children: [
                          SizedBox(height: constraints.maxHeight, child: board),
                          const SizedBox(height: 12),
                          rail,
                          const SizedBox(height: 12),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: board),
                        const SizedBox(width: railGap),
                        SizedBox(
                          width: railWidth,
                          child: ScrollConfiguration(
                            // The app theme forces scrollbar thumbs visible.
                            // Override the behavior itself here so Flutter
                            // cannot insert a desktop scrollbar over this
                            // narrow rail; wheel and trackpad scrolling stay
                            // enabled.
                            behavior: const _RailScrollBehavior(),
                            child: SingleChildScrollView(
                              controller: _railController,
                              child: _AnalyticsRail(
                                data: data,
                                now: now,
                                stacked: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Text(
            'Saves as you type  ·  Enter or Tab moves to the next box  ·  '
            'Click a name to set time off',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: Dt.textFaint(theme),
            ),
          ),
        ),
      ],
    );
  }
}

/// Wraps a day label so clicking it opens "Who's off?" for that day (mark
/// individual staff off, or the whole team as a holiday).
class _DayOffButton extends StatelessWidget {
  const _DayOffButton({required this.day, required this.child});

  final DayWithCounts day;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          '${DateFormat('EEEE').format(day.day.date)}: add a note, mark '
          'staff off or set a holiday',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(Dt.rSm),
        onTap: () => showDayOffDialog(context, dayId: day.day.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: child,
        ),
      ),
    );
  }
}

/// What follows a day's label: a "Holiday" badge when the whole team is
/// off, "2 off" when some are, otherwise a faint calendar icon hinting that
/// the label opens the time-off editor.
class _DayOffStatus extends StatelessWidget {
  const _DayOffStatus({required this.day, this.note});

  final DayWithCounts day;

  /// The day's note, shown as an icon with the text on hover.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final status = _status(context);
    if (note == null) return status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        status,
        const SizedBox(width: 4),
        Tooltip(
          message: note!,
          child: Icon(
            Icons.sticky_note_2_outlined,
            size: 13,
            color: Dt.textMuted(Theme.of(context)),
          ),
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    if (day.isHoliday) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(Dt.rPill),
        ),
        child: Text(
          'Holiday',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: Dt.textMuted(theme),
          ),
        ),
      );
    }
    final off = day.rows.where((r) => day.isOff(r.staffId)).length;
    if (off > 0) {
      return Text(
        '$off off',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          color: Dt.textMuted(theme),
        ),
      );
    }
    return Icon(
      Icons.event_busy_outlined,
      size: 13,
      color: Dt.textFaint(theme),
    );
  }
}

/// Scroll behavior for the analytics rail, which intentionally has no painted
/// scrollbar because the values are aligned against the panel's right edge.
class _RailScrollBehavior extends MaterialScrollBehavior {
  const _RailScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// "✓ Saved · 10:42" after a number is stored — quiet proof that autosave
/// worked. Empty until the first save in this session.
class _SavedIndicator extends ConsumerWidget {
  const _SavedIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(lastSavedProvider);
    if (saved == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = Dt.textMuted(theme);
    return Tooltip(
      message: 'Numbers save automatically as you type',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 13, color: color),
          const SizedBox(width: 5),
          AnimatedValueText(
            'Saved · ${DateFormat('HH:mm').format(saved)}',
            style: Dt.tab(theme.textTheme.labelSmall!).copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// The tracker's "⋯" menu: week-level actions.
class _WeekMenu extends ConsumerWidget {
  const _WeekMenu({required this.week});

  final Week week;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz, size: 18),
      position: PopupMenuPosition.under,
      onSelected: (action) async {
        switch (action) {
          case 'copy-off':
            final marked = ref
                .read(appActionsProvider)
                .copyPreviousWeekTimeOff(week.id);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  marked == 0
                      ? 'Nothing to copy — no new time off from last week.'
                      : 'Copied $marked ${marked == 1 ? 'day' : 'days'} '
                            'off from last week.',
                ),
              ),
            );
          case 'export':
            await exportWeekToFile(context, ref, week);
          case 'changes':
            await showChangeHistory(
              context,
              weekId: week.id,
              title: 'Changes this week',
            );
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'copy-off',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_repeat_outlined, size: 18),
            title: Text('Copy last week’s time off'),
          ),
        ),
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download_outlined, size: 18),
            title: Text('Export this week to Excel'),
          ),
        ),
        PopupMenuItem(
          value: 'changes',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.manage_history, size: 18),
            title: Text('Change history for this week'),
          ),
        ),
      ],
    );
  }
}

/// Small round hairline icon button (the chevron pair in the header).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;

  /// Null disables the button (e.g. no earlier week to go to).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(30, 30),
          maximumSize: const Size(30, 30),
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        child: Icon(icon, size: 16),
      ),
    );
  }
}

/// Pill toggle in the board header for the per-week "show zeros" preference.
/// When on, zero values are drawn as `0` instead of the blank en-dash
/// placeholder.
class _ShowZerosToggle extends ConsumerWidget {
  const _ShowZerosToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final week = ref.watch(currentWeekProvider);
    final theme = Theme.of(context);
    final showZeros = week?.week.showZeros ?? false;
    final label = showZeros ? 'Hide zeros' : 'Show zeros';
    return Tooltip(
      message: showZeros
          ? 'Show empty cells as a dash'
          : 'Show empty cells as 0',
      waitDuration: const Duration(milliseconds: 400),
      child: TextButton.icon(
        onPressed: week == null
            ? null
            : () => ref.read(appActionsProvider).toggleShowZeros(week.week.id),
        style: TextButton.styleFrom(foregroundColor: Dt.textMuted(theme)),
        icon: Icon(
          showZeros ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 14,
        ),
        label: Text(label),
      ),
    );
  }
}

// ---------------------------------------------------------------- table -----

/// Grid geometry shared by header / rows / footer. Day columns flex.
const double _nameWidth = 168;
const double _totalWidth = 72;
const double _footerHeight = 54;

/// Neutral tint behind today's column — enough to find your place without
/// borrowing a data colour.
Color _todayTint(ThemeData theme) => theme.colorScheme.onSurface.withValues(
  alpha: theme.brightness == Brightness.dark ? 0.04 : 0.035,
);

DateTime _mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// The board is wider than the reading cap — the mockup runs it at 1440.
const double _boardMaxWidth = 1440;

class _BoardTable extends ConsumerWidget {
  const _BoardTable({
    required this.data,
    required this.rowFor,
    required this.rowsController,
    required this.rowHeight,
    required this.fieldHeight,
    required this.fieldFontSize,
    required this.needsScroll,
  });

  final CurrentWeekData data;

  /// Supplies each staff row (cached by the board; see `_rowFor`).
  final Widget Function(
    CurrentWeekData data,
    NamedClientCount staff, {
    required double rowHeight,
    required double fieldHeight,
    required double fieldFontSize,
  })
  rowFor;
  final ScrollController rowsController;
  final double rowHeight;
  final double fieldHeight;
  final double fieldFontSize;

  /// True when the team is too long for the viewport even at the 34px
  /// minimum row height — rows scroll as before.
  final bool needsScroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = this.data;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final staffRows = data.days.isEmpty
        ? const <NamedClientCount>[]
        : data.days.first.rows;
    final border = BorderSide(color: theme.colorScheme.outline);

    // ---- pinned day header ---------------------------------------------
    Widget dayHeaderCell(DayWithCounts d) {
      final isToday = _sameDay(d.day.date, now);
      final locked = isDayGuarded(ref, d.day.id, d.day.date);
      Widget sub(String label, Color dot) => Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MeaningDot(dot, size: 6),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _subLabel(theme),
              ),
            ),
          ],
        ),
      );
      return Expanded(
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: border),
            color: isToday ? _todayTint(theme) : null,
          ),
          padding: const EdgeInsets.fromLTRB(4, 5, 4, 8),
          child: Column(
            children: [
              _DayOffButton(
                day: d,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: locked
                            ? 'Upcoming day — you’ll be asked before '
                                  'numbers go in'
                            : '',
                        child: Text(
                          '${DateFormat('EEE').format(d.day.date)} '
                          '${d.day.date.day}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: locked ? Dt.textFaint(theme) : null,
                          ),
                        ),
                      ),
                    ),
                    if (isToday) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Dt.brand(theme.brightness),
                          borderRadius: BorderRadius.circular(Dt.rPill),
                        ),
                        child: Text(
                          'Today',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: Dt.onBrand(theme.brightness),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    _DayOffStatus(day: d, note: data.notes[d.day.id]),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  sub('New', Dt.newGreen(theme.brightness)),
                  sub('Existing', Dt.existingBlue(theme.brightness)),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final headerRow = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _nameWidth,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Dt.s16, 0, 0, 9),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Text('Staff', style: _subLabel(theme)),
                  ),
                ),
              ),
              for (final d in data.days) dayHeaderCell(d),
              Container(
                width: _totalWidth,
                decoration: BoxDecoration(border: Border(left: border)),
                padding: const EdgeInsets.only(bottom: 9),
                alignment: Alignment.bottomCenter,
                child: Text('Week', style: _subLabel(theme)),
              ),
            ],
          ),
        ),
        Container(height: 1, color: theme.colorScheme.outline),
      ],
    );

    // ---- pinned totals footer -------------------------------------------
    Widget dayFooterCell(DayWithCounts d) {
      final isToday = _sameDay(d.day.date, now);
      // Time-off marks: only staff actually working count here.
      final working = d.workingRows;
      final n = working.fold<int>(0, (a, r) => a + r.newClients);
      final e = working.fold<int>(0, (a, r) => a + r.existingClients);
      final logged = working.any((r) => r.total > 0);
      final small = Dt.tab(theme.textTheme.labelSmall!)
          .copyWith(fontSize: 10.5, color: Dt.textMuted(theme));
      return Expanded(
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: border),
            color: isToday ? _todayTint(theme) : null,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedValueText(
                logged ? '${n + e}' : '–',
                style: Dt.tab(theme.textTheme.titleSmall!).copyWith(
                  fontWeight: FontWeight.w700,
                  color: logged ? null : Dt.textFaint(theme),
                ),
              ),
              if (logged) ...[
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$n new',
                        style: TextStyle(color: Dt.newGreen(theme.brightness)),
                      ),
                      const TextSpan(text: '  ·  '),
                      TextSpan(
                        text: '$e existing',
                        style: TextStyle(
                          color: Dt.existingBlue(theme.brightness),
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small,
                ),
              ],
            ],
          ),
        ),
      );
    }

    final weekLogged = data.totals.total > 0;
    final footerRow = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: theme.colorScheme.outline),
        SizedBox(
          height: _footerHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _nameWidth,
                child: Padding(
                  padding: const EdgeInsets.only(left: Dt.s16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Day total',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              for (final d in data.days) dayFooterCell(d),
              Container(
                width: _totalWidth,
                decoration: BoxDecoration(border: Border(left: border)),
                alignment: Alignment.center,
                child: AnimatedValueText(
                  weekLogged ? '${data.totals.total}' : '–',
                  style: Dt.tab(theme.textTheme.titleMedium!).copyWith(
                    fontWeight: FontWeight.w700,
                    color: weekLogged ? null : Dt.textFaint(theme),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    // ---- layout: pinned header / rows / pinned footer -------------------
    Widget staffRow(int i) => Container(
      // In the scroll branch rows need a fixed height; in the fit branch
      // the row is wrapped in Expanded below and fills the REAL available
      // space (the rowHeight estimate only sizes the input fields).
      height: needsScroll ? rowHeight : null,
      // Hairlines between rows guide the eye across ten fields per person.
      decoration: i == staffRows.length - 1
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.6),
                ),
              ),
            ),
      child: rowFor(
        data,
        staffRows[i],
        rowHeight: rowHeight,
        fieldHeight: fieldHeight,
        fieldFontSize: fieldFontSize,
      ),
    );

    final rowsBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (needsScroll)
          for (var i = 0; i < staffRows.length; i++) staffRow(i)
        else
          for (var i = 0; i < staffRows.length; i++)
            Expanded(child: staffRow(i)),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerRow,
        Expanded(
          child: needsScroll
              ? Scrollbar(
                  controller: rowsController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: rowsController,
                    child: rowsBlock,
                  ),
                )
              : rowsBlock,
        ),
        footerRow,
      ],
    );
  }

  TextStyle _subLabel(ThemeData theme) =>
      (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
        fontSize: 10.5,
        fontWeight: FontWeight.w500,
        color: Dt.textMuted(theme),
      );
}

/// One staff row: name + 5 day cell-pairs + serif weekly TOTAL.
class _BoardStaffRow extends ConsumerWidget {
  const _BoardStaffRow({
    super.key,
    required this.data,
    required this.staff,
    required this.nodeFor,
    required this.nextAfter,
    required this.rowHeight,
    required this.fieldHeight,
    required this.fieldFontSize,
  });

  final CurrentWeekData data;
  final NamedClientCount staff;
  final FocusNode Function(int, int, bool) nodeFor;
  final FocusNode Function(int, int, bool) nextAfter;
  final double rowHeight;
  final double fieldHeight;
  final double fieldFontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(appActionsProvider);
    final theme = Theme.of(context);
    final border = BorderSide(color: theme.colorScheme.outline);
    final dark = theme.brightness == Brightness.dark;
    final now = DateTime.now();

    final offDayLabels = <String>[
      for (final d in data.days)
        if (d.isOff(staff.staffId)) DateFormat('EEE').format(d.day.date),
    ];
    final isOffSomewhere = offDayLabels.isNotEmpty;

    // Weekly total counts only the days this staff member is working.
    var weekN = 0, weekE = 0;
    for (final d in data.days) {
      if (d.isOff(staff.staffId)) continue;
      final c = d.countFor(staff.staffId);
      weekN += c.newClients;
      weekE += c.existingClients;
    }

    return SizedBox(
      height: rowHeight,
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Tooltip(
              message: 'Tap to set time off',
              waitDuration: const Duration(milliseconds: 500),
              child: InkWell(
                onTap: () => showTimeOffDialog(
                  context,
                  ref,
                  staffId: staff.staffId,
                  staffName: staff.staffName,
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Dt.s16, right: Dt.s8),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          staff.staffName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: isOffSomewhere
                                ? Dt.textMuted(theme)
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (isOffSomewhere) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'Off: ${offDayLabels.join(" · ")}',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(Dt.rSm),
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: dark ? 0.9 : 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.event_busy,
                                  size: 11,
                                  color: Dt.textMuted(theme),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '${offDayLabels.length}',
                                  style: Dt.mono(
                                    context,
                                    size: 11,
                                    color: Dt.textMuted(theme),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          for (var i = 0; i < data.days.length; i++)
            Expanded(
              child: data.days[i].isOff(staff.staffId)
                  ? Container(
                      decoration: BoxDecoration(
                        border: Border(left: border),
                        color: _sameDay(data.days[i].day.date, now)
                            ? _todayTint(theme)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        data.days[i].isHoliday ? 'Holiday' : 'Off',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Dt.textMuted(theme),
                        ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: Border(left: border),
                        color: _sameDay(data.days[i].day.date, now)
                            ? _todayTint(theme)
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      child: Row(
                        children: [
                          for (final isNew in [true, false])
                            Expanded(
                              child: NumericField(
                                plusOne: PlusOne.onHover,
                                value: isNew
                                    ? data.days[i]
                                          .countFor(staff.staffId)
                                          .newClients
                                    : data.days[i]
                                          .countFor(staff.staffId)
                                          .existingClients,
                                focusNode: nodeFor(staff.staffId, i, isNew),
                                nextFocusNode: nextAfter(
                                  staff.staffId,
                                  i,
                                  isNew,
                                ),
                                width: double.infinity,
                                height: fieldHeight,
                                fontSize: fieldFontSize,
                                accent: isNew
                                    ? Dt.newGreen(theme.brightness)
                                    : Dt.existingBlue(theme.brightness),
                                valueColor: isNew
                                    ? Dt.newGreenBright(theme.brightness)
                                    : Dt.existingBlueBright(theme.brightness),
                                showZero: data.week.showZeros,
                                placeholder: '–',
                                confirmEdit:
                                    isDayGuarded(
                                      ref,
                                      data.days[i].day.id,
                                      data.days[i].day.date,
                                    )
                                    ? () => confirmFutureDayEdit(
                                        context,
                                        ref,
                                        dayId: data.days[i].day.id,
                                        date: data.days[i].day.date,
                                      )
                                    : null,
                                onClear: () => actions.undoCount(
                                  data.days[i].day.id,
                                  staff.staffId,
                                  isNew,
                                ),
                                onChanged: (v) => actions.saveCount(
                                  dayId: data.days[i].day.id,
                                  staffId: staff.staffId,
                                  newClients: isNew
                                      ? v
                                      : data.days[i]
                                            .countFor(staff.staffId)
                                            .newClients,
                                  existingClients: isNew
                                      ? data.days[i]
                                            .countFor(staff.staffId)
                                            .existingClients
                                      : v,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          Container(
            width: _totalWidth,
            decoration: BoxDecoration(border: Border(left: border)),
            alignment: Alignment.center,
            child: Text(
              weekN + weekE == 0 ? '–' : '${weekN + weekE}',
              style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                fontWeight: FontWeight.w600,
                color: weekN + weekE == 0 ? Dt.textFaint(theme) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- rail ------

/// The week's analytics as panels — This week, By day, Most clients, Client
/// mix. [stacked] puts them in one column (the narrow rail beside the board
/// on very wide screens); otherwise they sit side by side under the board.
class _AnalyticsRail extends ConsumerWidget {
  const _AnalyticsRail({
    required this.data,
    required this.now,
    this.stacked = false,
  });

  final CurrentWeekData data;
  final DateTime now;
  final bool stacked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final staffRows = data.days.isEmpty
        ? const <NamedClientCount>[]
        : data.days.first.rows;

    // Weekly totals per staff (off days contribute nothing), most first.
    int effectiveTotal(NamedClientCount row) => data.days.fold<int>(
      0,
      (a, d) => a + (d.isOff(row.staffId) ? 0 : d.countFor(row.staffId).total),
    );
    final leaders = <({String name, int total})>[
      for (final row in staffRows)
        (name: row.staffName, total: effectiveTotal(row)),
    ]..sort((a, b) => b.total.compareTo(a.total));
    final top5 = leaders.where((l) => l.total > 0).take(5).toList();
    final topTotal = top5.isEmpty ? 0 : top5.first.total;

    DayWithCounts? bestDay;
    var bestTotal = 0;
    for (final d in data.days) {
      final t = d.workingRows.fold<int>(0, (a, r) => a + r.total);
      if (t > bestTotal) {
        bestTotal = t;
        bestDay = d;
      }
    }
    final spanText = data.days.isEmpty
        ? '–'
        : '${DateFormat('d MMM').format(data.days.first.day.date)} – '
              '${DateFormat('d MMM yyyy').format(data.days.last.day.date)}';
    final offMarks = data.days.fold<int>(0, (a, d) => a + d.offStaffIds.length);
    final muted = Dt.textMuted(theme);

    final facts = AppPanel(
      title: 'This week',
      icon: Icons.info_outline,
      child: Column(
        children: [
          _FactRow(label: 'Spanning', value: spanText),
          _FactRow(label: 'Staff on board', value: '${staffRows.length}'),
          _FactRow(
            label: 'Staff days off',
            value: offMarks == 0 ? '–' : '$offMarks',
          ),
          _FactRow(
            label: 'Best day',
            value: bestDay == null
                ? '–'
                : '${DateFormat('EEEE').format(bestDay.day.date)} · $bestTotal',
            last: true,
          ),
        ],
      ),
    );

    final chart = AppPanel(
      title: 'By day',
      icon: Icons.bar_chart,
      trailingWidget: const NewExistingLegend(),
      child: StackedDayChart(
        height: 170,
        days: [
          for (final d in data.days)
            ChartDay(
              date: d.day.date,
              newClients: d.workingRows.fold<int>(
                0,
                (a, r) => a + r.newClients,
              ),
              existingClients: d.workingRows.fold<int>(
                0,
                (a, r) => a + r.existingClients,
              ),
              offCount: d.offStaffIds.length,
              isHoliday: d.isHoliday,
            ),
        ],
      ),
    );

    final leaderPanel = AppPanel(
      title: 'Most clients this week',
      icon: Icons.emoji_events_outlined,
      child: top5.isEmpty
          ? _RailNote('No numbers yet this week.', color: muted)
          : Column(
              children: [
                for (var i = 0; i < top5.length; i++)
                  _LeaderRow(
                    rank: i + 1,
                    name: top5[i].name,
                    total: top5[i].total,
                    fraction: top5[i].total / topTotal,
                    last: i == top5.length - 1,
                  ),
              ],
            ),
    );

    final mix = AppPanel(
      title: 'Client mix',
      icon: Icons.donut_small_outlined,
      child: _MixBar(
        newCount: data.totals.newClients,
        existingCount: data.totals.existingClients,
      ),
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        facts,
        const SizedBox(height: 12),
        chart,
        const SizedBox(height: 12),
        leaderPanel,
        const SizedBox(height: 12),
        mix,
      ],
    );
    if (stacked) return column;
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) return column;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(children: [facts, const SizedBox(height: 12), mix]),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: chart),
            const SizedBox(width: 12),
            Expanded(child: leaderPanel),
          ],
        );
      },
    );
  }
}

/// One label/value line of the week facts (hairline separators).
class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value, this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.6),
                ),
              ),
            ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Dt.textMuted(theme),
              ),
            ),
          ),
          const SizedBox(width: Dt.s12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Dt.tab(theme.textTheme.bodyMedium!)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rank, name, a bar scaled to the top performer, and the total.
class _LeaderRow extends StatelessWidget {
  const _LeaderRow({
    required this.rank,
    required this.name,
    required this.total,
    required this.fraction,
    required this.last,
  });

  final int rank;
  final String name;
  final int total;
  final double fraction;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: scheme.outline.withValues(alpha: 0.6),
                ),
              ),
            ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$rank',
              style: Dt.tab(theme.textTheme.labelSmall!)
                  .copyWith(color: Dt.textFaint(theme)),
            ),
          ),
          SizedBox(
            width: 96,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      Container(
                        color: scheme.onSurface.withValues(alpha: 0.08),
                      ),
                      FractionallySizedBox(
                        widthFactor: fraction.clamp(0.0, 1.0),
                        child: Container(
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Text(
            '$total',
            style: Dt.tab(theme.textTheme.bodyMedium!)
                .copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// New vs existing as one split bar (2px gap), with counts and shares
/// written out so the split never relies on colour alone.
class _MixBar extends StatelessWidget {
  const _MixBar({required this.newCount, required this.existingCount});

  final int newCount;
  final int existingCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = newCount + existingCount;
    if (total == 0) {
      return _RailNote('No clients logged yet.', color: Dt.textMuted(theme));
    }
    final newPct = (newCount * 100 / total).round();
    Widget label(String text, Color dot) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: Dt.tab(theme.textTheme.labelSmall!)
              .copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 10,
            child: Row(
              children: [
                if (newCount > 0)
                  Expanded(
                    flex: newCount,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Dt.newGreen(theme.brightness),
                        borderRadius: BorderRadius.horizontal(
                          left: const Radius.circular(4),
                          right: Radius.circular(existingCount == 0 ? 4 : 0),
                        ),
                      ),
                    ),
                  ),
                if (newCount > 0 && existingCount > 0) const SizedBox(width: 2),
                if (existingCount > 0)
                  Expanded(
                    flex: existingCount,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Dt.existingBlue(theme.brightness),
                        borderRadius: BorderRadius.horizontal(
                          right: const Radius.circular(4),
                          left: Radius.circular(newCount == 0 ? 4 : 0),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              label('$newCount new · $newPct%', Dt.newGreen(theme.brightness)),
              label(
                '$existingCount existing · ${100 - newPct}%',
                Dt.existingBlue(theme.brightness),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RailNote extends StatelessWidget {
  const _RailNote(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    ),
  );
}

// ---------------------------------------------------------------- mobile ----

class _MobileWeekView extends StatefulWidget {
  const _MobileWeekView({
    required this.data,
    required this.selectedDayId,
    required this.onSelectDay,
  });

  final CurrentWeekData data;
  final int? selectedDayId;
  final ValueChanged<int> onSelectDay;

  @override
  State<_MobileWeekView> createState() => _MobileWeekViewState();
}

class _MobileWeekViewState extends State<_MobileWeekView> {
  int? _resolvedDayId;

  @override
  Widget build(BuildContext context) {
    final days = widget.data.days;
    final theme = Theme.of(context);
    final today = DateTime.now();
    final todayEntry = days
        .where((d) => _sameDay(d.day.date, today))
        .toList()
        .firstOrNull;

    var selectedId = widget.selectedDayId ?? _resolvedDayId;
    selectedId ??= todayEntry?.day.id ?? days.first.day.id;
    if (!days.any((d) => d.day.id == selectedId)) {
      selectedId = days.first.day.id;
    }
    final index = days.indexWhere((d) => d.day.id == selectedId);
    final day = days[index];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Dt.s16,
            vertical: Dt.s8,
          ),
          // Full width with equal segments so all five days always fit.
          child: SegmentedButton<int>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            style: MediaQuery.sizeOf(context).width < 600
                ? Dt.phoneSegments
                : null,
            segments: [
              for (var i = 0; i < days.length; i++)
                ButtonSegment(
                  value: i,
                  label: Text(
                    DateFormat('EEE').format(days[i].day.date),
                    maxLines: 1,
                  ),
                ),
            ],
            selected: {index},
            onSelectionChanged: (selection) {
              setState(() {
                _resolvedDayId = days[selection.first].day.id;
              });
              widget.onSelectDay(days[selection.first].day.id);
            },
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Dt.s16, Dt.s16, Dt.s16, Dt.s32),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${DateFormat('EEEE').format(day.day.date)} · ${DateFormat('d MMMM y').format(day.day.date)}',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        showDayOffDialog(context, dayId: day.day.id),
                    icon: const Icon(Icons.event_busy_outlined, size: 15),
                    label: Text(
                      day.isHoliday
                          ? 'Holiday'
                          : day.offStaffIds.isNotEmpty
                          ? '${day.rows.where((r) => day.isOff(r.staffId)).length} off'
                          : 'Who’s off?',
                    ),
                  ),
                ],
              ),
              if (widget.data.notes[day.day.id] case final note?) ...[
                const SizedBox(height: Dt.s4),
                Row(
                  children: [
                    Icon(
                      Icons.sticky_note_2_outlined,
                      size: 14,
                      color: Dt.textMuted(theme),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        note,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Dt.textMuted(theme),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: Dt.s4),
              Text(
                'Tap a name to set time off',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
              const SizedBox(height: Dt.s12),
              for (final row in day.rows)
                _MobileStaffRow(
                  key: ValueKey('mobile-${day.day.id}-${row.staffId}'),
                  day: day,
                  row: row,
                  showZero: widget.data.week.showZeros,
                ),
              const SizedBox(height: Dt.s8),
              _daySummaryCard(context, day),
            ],
          ),
        ),
      ],
    );
  }

  Widget _daySummaryCard(BuildContext context, DayWithCounts day) {
    final theme = Theme.of(context);
    final working = day.workingRows;
    final n = working.fold<int>(0, (a, r) => a + r.newClients);
    final e = working.fold<int>(0, (a, r) => a + r.existingClients);
    return Container(
      padding: const EdgeInsets.all(Dt.s12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Dt.rMd),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _sum(context, 'New Total', '$n', Dt.newGreen(theme.brightness)),
          _sum(
            context,
            'Existing Total',
            '$e',
            Dt.existingBlue(theme.brightness),
          ),
          _sum(context, 'Day Total', '${n + e}', null),
        ],
      ),
    );
  }

  Widget _sum(BuildContext context, String label, String value, Color? color) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(label, style: microLabel(theme)),
        const SizedBox(height: Dt.s4),
        Text(
          value,
          style: Dt.tab(theme.textTheme.titleLarge!)
              .copyWith(fontWeight: FontWeight.w700, color: color),
        ),
      ],
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// One compact labelled count field used by the mobile staff row.
class InlineCountPair extends StatelessWidget {
  const InlineCountPair({
    super.key,
    required this.isNew,
    required this.newClients,
    required this.existingClients,
    required this.showZero,
    required this.actions,
    required this.day,
    required this.row,
    required this.newColor,
    required this.newColorBright,
    required this.existingColor,
    required this.existingColorBright,
    required this.context,
    required this.theme,
    this.confirmEdit,
  });

  /// Set while the day is a locked future day (see [NumericField]).
  final Future<bool> Function()? confirmEdit;

  final bool isNew;
  final int newClients;
  final int existingClients;
  final bool showZero;
  final AppActions actions;
  final DayWithCounts day;
  final NamedClientCount row;
  final Color newColor;
  final Color newColorBright;
  final Color existingColor;
  final Color existingColorBright;
  final BuildContext context;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final accent = isNew ? newColor : existingColor;
    final bright = isNew ? newColorBright : existingColorBright;
    final v = isNew ? newClients : existingClients;
    final label = isNew ? 'New' : 'Exist.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          children: [
            MeaningDot(accent),
            const SizedBox(width: Dt.s4),
            Text(label, style: microLabel(theme)),
          ],
        ),
        const SizedBox(height: Dt.s4),
        NumericField(
          value: v,
          showZero: showZero,
          plusOne: PlusOne.always,
          // Room for the number plus the always-visible "+".
          width: 78,
          accent: accent,
          valueColor: bright,
          placeholder: '–',
          confirmEdit: confirmEdit,
          onClear: () => actions.undoCount(day.day.id, row.staffId, isNew),
          onChanged: (nv) => actions.saveCount(
            dayId: day.day.id,
            staffId: row.staffId,
            newClients: isNew ? nv : newClients,
            existingClients: isNew ? existingClients : nv,
          ),
        ),
      ],
    );
  }
}

class _MobileStaffRow extends ConsumerWidget {
  const _MobileStaffRow({
    super.key,
    required this.day,
    required this.row,
    required this.showZero,
  });

  final DayWithCounts day;
  final NamedClientCount row;
  final bool showZero;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(appActionsProvider);
    final theme = Theme.of(context);
    final isOff = day.isOff(row.staffId);
    final confirmEdit = isDayGuarded(ref, day.day.id, day.day.date)
        ? () => confirmFutureDayEdit(
            context,
            ref,
            dayId: day.day.id,
            date: day.day.date,
          )
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: Dt.s8),
      padding: const EdgeInsets.symmetric(horizontal: Dt.s12, vertical: Dt.s12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Dt.rMd),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: InkWell(
              onTap: () => showTimeOffDialog(
                context,
                ref,
                staffId: row.staffId,
                staffName: row.staffName,
              ),
              child: Text(
                row.staffName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: isOff
                      ? Dt.textMuted(theme)
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(width: Dt.s8),
          if (isOff)
            Text(
              'Off',
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: Dt.textMuted(theme),
              ),
            )
          else ...[
            InlineCountPair(
              isNew: true,
              newClients: row.newClients,
              existingClients: row.existingClients,
              showZero: showZero,
              actions: actions,
              day: day,
              row: row,
              newColor: Dt.newGreen(theme.brightness),
              newColorBright: Dt.newGreenBright(theme.brightness),
              existingColor: Dt.existingBlue(theme.brightness),
              existingColorBright: Dt.existingBlueBright(theme.brightness),
              context: context,
              theme: theme,
              confirmEdit: confirmEdit,
            ),
            const SizedBox(width: Dt.s8),
            InlineCountPair(
              isNew: false,
              newClients: row.newClients,
              existingClients: row.existingClients,
              showZero: showZero,
              actions: actions,
              day: day,
              row: row,
              newColor: Dt.newGreen(theme.brightness),
              newColorBright: Dt.newGreenBright(theme.brightness),
              existingColor: Dt.existingBlue(theme.brightness),
              existingColorBright: Dt.existingBlueBright(theme.brightness),
              context: context,
              theme: theme,
              confirmEdit: confirmEdit,
            ),
            const SizedBox(width: Dt.s8),
            SizedBox(
              width: 28,
              child: Text(
                row.total == 0 ? '–' : '${row.total}',
                textAlign: TextAlign.right,
                style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                  fontWeight: FontWeight.w600,
                  color: row.total == 0 ? Dt.textFaint(theme) : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- helpers ---

/// ISO-8601 week number (the spreadsheet's "Week 41" convention).
int _isoWeekNumber(DateTime date) {
  final ordinal = date.difference(DateTime(date.year, 1, 1)).inDays + 1;
  return ((ordinal - date.weekday + 10) ~/ 7);
}
