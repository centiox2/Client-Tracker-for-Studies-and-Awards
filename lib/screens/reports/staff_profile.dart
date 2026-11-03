part of 'reports_screen.dart';

/// One staff member's record: totals, average per day worked, best day,
/// week by week, which weekdays they're busiest and their latest days.
Future<void> showStaffProfile(BuildContext context, int staffId) =>
    showDialog<void>(
      context: context,
      builder: (_) => _StaffProfileDialog(staffId: staffId),
    );

class _StaffProfileDialog extends ConsumerWidget {
  const _StaffProfileDialog({required this.staffId});

  final int staffId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final friday = today.add(Duration(days: 5 - today.weekday));
    final first = ref.watch(firstTrackedDayProvider) ?? today;
    final report = ref.watch(reportProvider((first, friday)));
    final profile = report.profileFor(staffId);
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 640;

    final close = IconButton(
      tooltip: 'Close',
      onPressed: () => Navigator.pop(context),
      icon: const Icon(Icons.close),
    );

    Widget body;
    if (profile == null) {
      body = const _Note('No numbers recorded for this person yet.');
    } else {
      final s = profile.staff;
      final best = profile.bestDay;
      final weeks = profile.weeks.length > 12
          ? profile.weeks.sublist(profile.weeks.length - 12)
          : profile.weeks;
      final busiest = profile.weekdays
          .where((w) => w.days > 0)
          .fold<WeekdayAverage?>(
            null,
            (b, w) => b == null || w.average > b.average ? w : b,
          );
      final tiles = <Widget>[
        _Tile(
          label: 'Clients, all time',
          value: '${s.total}',
          caption: '${s.newClients} new · ${s.existingClients} existing',
        ),
        _Tile(
          label: 'Average per day worked',
          value: _QuickView._avg(profile.dailyAverage),
          caption: '${s.daysWorked} days worked',
        ),
        _Tile(
          label: 'Best day',
          value: best == null ? '–' : '${best.total}',
          caption: best == null
              ? 'No clients yet'
              : DateFormat('EEE d MMM y').format(best.date),
        ),
        _Tile(
          label: 'New clients share',
          value: s.total == 0
              ? '–'
              : '${(s.newClients * 100 / s.total).round()}%',
          caption: '${s.daysOff} ${s.daysOff == 1 ? 'day' : 'days'} off',
        ),
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final perRow = compact ? 2 : 4;
              final w = (c.maxWidth - 10 * (perRow - 1)) / perRow;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final t in tiles) SizedBox(width: w, child: t)],
              );
            },
          ),
          const SizedBox(height: 12),
          _Panel(
            title: weeks.length < profile.weeks.length
                ? 'Last 12 weeks'
                : 'Week by week',
            icon: Icons.bar_chart,
            trailingWidget: const _Legend(),
            child: _BucketBars(
              buckets: weeks,
              height: 160,
              label: (m) => DateFormat('d\nMMM').format(m),
              tooltip: (m) => 'Week of ${DateFormat('d MMM y').format(m)}',
            ),
          ),
          const SizedBox(height: 12),
          _Panel(
            title: 'Average by weekday',
            icon: Icons.view_week_outlined,
            trailing: busiest == null
                ? null
                : 'Busiest: ${DateFormat('EEEE').format(DateTime(2024, 1, busiest.weekday))}',
            child: _WeekdayChart(
              averages: profile.weekdays,
              busiest: busiest?.weekday,
            ),
          ),
          const SizedBox(height: 12),
          _Panel(
            title: 'Latest days',
            icon: Icons.history,
            child: _RecentDays(days: profile.recentDays),
          ),
        ],
      );
    }

    final title = profile?.staff.name ?? 'Staff member';
    final subtitle = profile == null
        ? null
        : [
            profile.staff.active ? 'Active' : 'Inactive',
            if (profile.firstClient != null)
              'first client ${DateFormat('d MMM y').format(profile.firstClient!)}',
          ].join(' · ');

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 820,
          maxHeight: size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    child: Text(
                      title.isEmpty ? '?' : title[0].toUpperCase(),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (subtitle != null)
                          Text(
                            subtitle,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                      ],
                    ),
                  ),
                  close,
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentDays extends StatelessWidget {
  const _RecentDays({required this.days});

  final List<StaffDay> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (days.isEmpty) return const _Note('No days recorded yet.');
    final head = _headStyle(theme);
    const widths = [60.0, 70.0, 60.0];
    return Column(
      children: [
        _Row(
          header: true,
          widths: widths,
          cells: [
            Text('Day', style: head),
            Text('New', style: head),
            Text('Existing', style: head),
            Text('Total', style: head),
          ],
        ),
        for (var i = 0; i < days.length; i++)
          _Row(
            last: i == days.length - 1,
            widths: widths,
            cells: [
              Text(
                DateFormat('EEE d MMM').format(days[i].date),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (days[i].off) ...[
                const SizedBox.shrink(),
                const SizedBox.shrink(),
                Text('Off', style: _num(theme, color: Dt.textMuted(theme))),
              ] else ...[
                _count(
                  theme,
                  days[i].newClients,
                  color: Dt.newGreen(theme.brightness),
                ),
                _count(
                  theme,
                  days[i].existingClients,
                  color: Dt.existingBlue(theme.brightness),
                ),
                _count(theme, days[i].total, bold: true),
              ],
            ],
          ),
      ],
    );
  }
}
