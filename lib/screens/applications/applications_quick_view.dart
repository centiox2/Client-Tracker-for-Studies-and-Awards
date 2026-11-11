import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/airtable_tags.dart';
import '../../design/app_theme.dart';
import '../../repositories/application_repository.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';
import 'applications_screen.dart'
    show ApplicationUpdateRow, showApplicationDetails;

/// Applications at a glance, for the boss: what happened today (milestones,
/// notes the team dated today, changes in today's uploads), the week day by
/// day, what needs attention, who is handling what, this month against last,
/// and COEs over the last six months.
///
/// Everything comes from the uploaded Airtable CSV, so "today" is as of the
/// latest upload (the header says when that was).
class ApplicationsQuickView extends ConsumerWidget {
  const ApplicationsQuickView({
    super.key,
    required this.apps,
    required this.imports,
    required this.phone,
    required this.onShowAll,
  });

  final List<Application> apps;
  final List<ApplicationImport> imports;
  final bool phone;

  /// Opens the full list, filtered to a status (or everything in progress).
  final void Function({String? status, bool inProgress}) onShowAll;

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final repo = ref.read(applicationRepositoryProvider);
    final now = DateTime.now();
    final today = _day(now);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final latest = imports.firstOrNull;

    // ---- Today ----
    bool on(DateTime? d, DateTime day) => d != null && _day(d) == day;
    int countOn(DateTime? Function(Application) f, DateTime day) =>
        apps.where((a) => on(f(a), day)).length;
    final todaysUploads = imports.where((i) => _day(i.at) == today).toList();
    final todaysChanges = [
      for (final i in todaysUploads) ...repo.changesFor(i.id),
    ];
    final notesToday = [
      for (final a in apps)
        for (final (d, text) in a.datedNotes)
          if (d == today) (a, text),
    ];
    final updatedToday = {
      for (final c in todaysChanges) c.key,
      for (final (a, _) in notesToday) a.key,
    }.length;

    final header = Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          DateFormat('EEEE d MMMM').format(now),
          style: theme.textTheme.titleMedium,
        ),
        if (latest != null)
          Text(
            todaysUploads.isEmpty
                ? 'No upload yet today · last upload '
                      '${DateFormat('d MMM, h:mm a').format(latest.at)}'
                : 'As of the upload at ${DateFormat('h:mm a').format(latest.at)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: todaysUploads.isEmpty ? theme.colorScheme.error : muted,
            ),
          ),
      ],
    );

    String weekCaption(DateTime? Function(Application) f) {
      final n = apps.where((a) {
        final d = f(a);
        return d != null &&
            !_day(d).isBefore(monday) &&
            !_day(d).isAfter(today);
      }).length;
      return '$n this week';
    }

    final tiles = [
      _Tile(
        label: 'Applications submitted',
        value: '${countOn((a) => a.appDate, today)}',
        caption: weekCaption((a) => a.appDate),
      ),
      _Tile(
        label: 'Offer letters',
        value: '${countOn((a) => a.offerDate, today)}',
        caption: weekCaption((a) => a.offerDate),
      ),
      _Tile(
        label: 'COEs issued',
        value: '${countOn((a) => a.coeDate, today)}',
        caption: weekCaption((a) => a.coeDate),
      ),
      _Tile(
        label: 'Students updated',
        value: '$updatedToday',
        caption: '${notesToday.length} notes dated today',
      ),
    ];

    // ---- Today's activity: milestones, notes, upload changes ----
    final activity = <_Event>[];
    for (final a in apps) {
      if (on(a.coeDate, today)) {
        activity.add(_Event(a, Icons.verified_outlined, 'COE issued'));
      }
      if (on(a.offerDate, today)) {
        activity.add(
          _Event(a, Icons.mark_email_read_outlined, 'Offer letter received'),
        );
      }
      if (on(a.appDate, today)) {
        activity.add(_Event(a, Icons.send_outlined, 'Application submitted'));
      }
      if (on(a.docDate, today)) {
        activity.add(
          _Event(a, Icons.description_outlined, 'Documents submitted'),
        );
      }
    }
    for (final (a, text) in notesToday) {
      activity.add(_Event(a, Icons.sticky_note_2_outlined, text, note: true));
    }
    final byKey = {for (final a in apps) a.key: a};
    final changesByStudent = <String, List<ApplicationChange>>{};
    for (final c in todaysChanges) {
      // Notes and dates already show above from the data itself.
      if (c.field == 'todo' ||
          c.field.endsWith('_date') &&
              c.newValue.isNotEmpty &&
              DateTime.tryParse(c.newValue) == today) {
        continue;
      }
      changesByStudent.putIfAbsent(c.key, () => []).add(c);
    }

    final activityPanel = AppPanel(
      title: 'Today',
      icon: Icons.today_outlined,
      trailing: activity.isEmpty && changesByStudent.isEmpty
          ? null
          : '${activity.length + changesByStudent.length}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: activity.isEmpty && changesByStudent.isEmpty
            ? Text(
                todaysUploads.isEmpty
                    ? 'Nothing dated today yet. Upload today’s Airtable '
                          'export to see today’s progress.'
                    : 'Nothing new today in the tracker.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              )
            : FirstFew(
                // Milestones, then status moves, then the day's notes.
                children: [
                  for (final e in activity.where((e) => !e.note))
                    _EventRow(
                      event: e,
                      onTap: () => showApplicationDetails(context, ref, e.app),
                    ),
                  for (final entry in changesByStudent.entries)
                    ApplicationUpdateRow(
                      student: entry.value.first.student,
                      changes: entry.value,
                      dense: true,
                      onTap: byKey[entry.key] == null
                          ? null
                          : () => showApplicationDetails(
                              context,
                              ref,
                              byKey[entry.key]!,
                            ),
                    ),
                  for (final e in activity.where((e) => e.note))
                    _EventRow(
                      event: e,
                      onTap: () => showApplicationDetails(context, ref, e.app),
                    ),
                ],
              ),
      ),
    );

    // ---- This week, day by day ----
    final days = [
      for (
        var d = monday;
        !d.isAfter(today);
        d = d.add(const Duration(days: 1))
      )
        d,
    ];
    int notesOn(DateTime day) => apps.fold(
      0,
      (n, a) => n + a.datedNotes.where((x) => x.$1 == day).length,
    );
    final weekPanel = AppPanel(
      title: 'This week',
      icon: Icons.date_range_outlined,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Table(
          columnWidths: const {0: FlexColumnWidth(1.6)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                for (final h in [
                  '',
                  'Docs',
                  'Applied',
                  'Offers',
                  'COEs',
                  'Notes',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      h,
                      textAlign: h.isEmpty ? TextAlign.left : TextAlign.right,
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
              ],
            ),
            for (final d in days)
              TableRow(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outline),
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      d == today ? 'Today' : DateFormat('EEE d').format(d),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: d == today ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                  for (final n in [
                    countOn((a) => a.docDate, d),
                    countOn((a) => a.appDate, d),
                    countOn((a) => a.offerDate, d),
                    countOn((a) => a.coeDate, d),
                    notesOn(d),
                  ])
                    Text(
                      n == 0 ? '–' : '$n',
                      textAlign: TextAlign.right,
                      style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                        color: n == 0 ? muted : null,
                        fontWeight: n == 0 ? null : FontWeight.w600,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );

    // ---- Needs attention: waiting longest since the last step ----
    final inProgress = apps.where((a) => a.inProgress).toList();
    DateTime? lastActivity(Application a) {
      final notes = a.datedNotes.map((n) => n.$1);
      return [a.lastStep, ...notes].whereType<DateTime>().fold<DateTime?>(
        null,
        (x, y) => x == null || y.isAfter(x) ? y : x,
      );
    }

    final waiting = [
      for (final a in inProgress)
        if (lastActivity(a) case final t?)
          (a, today.difference(_day(t)).inDays),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    final stale = waiting.where((w) => w.$2 >= 14).toList();
    final unassigned = inProgress.where((a) => a.assignee.isEmpty).length;
    // No date anywhere in the tracker: can't say how long they've waited,
    // so they're named here rather than left out.
    final undated = inProgress.where((a) => lastActivity(a) == null).length;

    final attentionPanel = AppPanel(
      title: 'Needs attention',
      icon: Icons.priority_high_rounded,
      trailing: stale.isEmpty ? null : '${stale.length} waiting 2+ weeks',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stale.isEmpty)
              Text(
                'No application in progress has waited two weeks or more.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              )
            else
              for (final (a, daysWaiting) in stale.take(8))
                InkWell(
                  onTap: () => showApplicationDetails(context, ref, a),
                  borderRadius: BorderRadius.circular(Dt.rSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 58,
                          child: Text(
                            '$daysWaiting d',
                            style: Dt.tab(theme.textTheme.titleSmall!).copyWith(
                              color: daysWaiting >= 30
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a.student,
                                style: theme.textTheme.bodyMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: 6,
                                runSpacing: 3,
                                children: [
                                  TagChip(
                                    a.status,
                                    AirtableTags.status(a.status),
                                    dense: true,
                                  ),
                                  if (a.assignee.isNotEmpty)
                                    TagChip(
                                      a.assignee,
                                      AirtableTags.assignee(a.assignee),
                                      dense: true,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            if (stale.length > 8)
              Text(
                'and ${stale.length - 8} more',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            if (unassigned > 0) ...[
              const SizedBox(height: 6),
              Text(
                '$unassigned in progress with no assignee',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (undated > 0) ...[
              const SizedBox(height: 4),
              Text(
                '$undated in progress with no dates in the tracker yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Days since the last date in the tracker (documents, '
              'application, offer, COE or a dated note).',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );

    // ---- Who's handling what ----
    final byAssignee = <String, List<Application>>{};
    for (final a in inProgress) {
      byAssignee
          .putIfAbsent(
            a.assignee.isEmpty ? 'No assignee' : a.assignee,
            () => [],
          )
          .add(a);
    }
    final people = byAssignee.keys.toList()
      ..sort((x, y) => byAssignee[y]!.length.compareTo(byAssignee[x]!.length));
    final maxLoad = people.isEmpty ? 1 : byAssignee[people.first]!.length;
    final whoPanel = AppPanel(
      title: 'Who’s handling what',
      icon: Icons.groups_2_outlined,
      trailing: '${inProgress.length} in progress',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Column(
          children: [
            for (final p in people)
              Tooltip(
                message: _stageSummary(byAssignee[p]!),
                child: InkWell(
                  key: ValueKey('handling-$p'),
                  borderRadius: BorderRadius.circular(Dt.rSm),
                  // Who they're handling, and what nobody is.
                  onTap: () => showHandling(
                    context,
                    ref,
                    person: p == 'No assignee' ? null : p,
                    mine: p == 'No assignee' ? const [] : byAssignee[p]!,
                    unassigned: byAssignee['No assignee'] ?? const [],
                    lastActivity: lastActivity,
                    today: today,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: p == 'No assignee'
                                ? Text(
                                    p,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: muted,
                                    ),
                                  )
                                : TagChip(
                                    p,
                                    AirtableTags.assignee(p),
                                    dense: true,
                                  ),
                          ),
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, box) => Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                height: 10,
                                width:
                                    box.maxWidth *
                                    byAssignee[p]!.length /
                                    maxLoad,
                                decoration: BoxDecoration(
                                  color: Dt.brand(theme.brightness),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 34,
                          child: Text(
                            '${byAssignee[p]!.length}',
                            textAlign: TextAlign.right,
                            style: Dt.tab(theme.textTheme.labelLarge!),
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 16, color: muted),
                      ],
                    ),
                  ),
                ),
              ),
            if (people.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Tap a name to see who they’re handling, and what has no '
                  'one yet.',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
          ],
        ),
      ),
    );

    // ---- This month against last ----
    final firstOfMonth = DateTime(today.year, today.month);
    final firstOfLast = DateTime(today.year, today.month - 1);
    // The same stretch of last month (1st to today's day), for a fair look.
    final lastMonthSameDay = DateTime(
      firstOfLast.year,
      firstOfLast.month,
      today.day.clamp(1, DateTime(today.year, today.month, 0).day),
    );
    int inRange(
      DateTime? Function(Application) f,
      DateTime from,
      DateTime to,
    ) => apps.where((a) {
      final d = f(a);
      if (d == null) return false;
      final x = _day(d);
      return !x.isBefore(from) && !x.isAfter(to);
    }).length;
    final monthRows = [
      ('Documents submitted', (Application a) => a.docDate),
      ('Applications submitted', (Application a) => a.appDate),
      ('Offer letters', (Application a) => a.offerDate),
      ('COEs issued', (Application a) => a.coeDate),
    ];
    final monthName = DateFormat('MMMM').format(today);
    final lastName = DateFormat('MMMM').format(firstOfLast);
    final monthPanel = AppPanel(
      title: '$monthName so far',
      icon: Icons.calendar_month_outlined,
      trailing: 'vs $lastName 1–${lastMonthSameDay.day}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Column(
          children: [
            for (final (label, f) in monthRows)
              Builder(
                builder: (context) {
                  final n = inRange(f, firstOfMonth, today);
                  final before = inRange(f, firstOfLast, lastMonthSameDay);
                  final diff = n - before;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(label, style: theme.textTheme.bodyMedium),
                        ),
                        Text(
                          '$n',
                          style: Dt.tab(theme.textTheme.titleSmall!)
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                        SizedBox(
                          width: 92,
                          child: Text(
                            diff == 0
                                ? 'same'
                                : diff > 0
                                ? '+$diff'
                                : '−${-diff}',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: diff > 0
                                  ? Dt.newGreen(theme.brightness)
                                  : diff < 0
                                  ? theme.colorScheme.error
                                  : muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );

    // ---- COEs by month, last six ----
    final months = [
      for (var i = 5; i >= 0; i--) DateTime(today.year, today.month - i),
    ];
    final coeCounts = [
      for (final m in months)
        apps
            .where(
              (a) =>
                  a.coeDate != null &&
                  a.coeDate!.year == m.year &&
                  a.coeDate!.month == m.month,
            )
            .length,
    ];
    final offerCounts = [
      for (final m in months)
        apps
            .where(
              (a) =>
                  a.offerDate != null &&
                  a.offerDate!.year == m.year &&
                  a.offerDate!.month == m.month,
            )
            .length,
    ];
    final maxCoe = coeCounts.fold<int>(1, (m, v) => v > m ? v : m);
    final coePanel = AppPanel(
      title: 'COEs by month',
      icon: Icons.bar_chart,
      trailing: '${coeCounts.fold<int>(0, (s, v) => s + v)} in 6 months',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
        child: SizedBox(
          height: 150,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < months.length; i++)
                Expanded(
                  child: Tooltip(
                    message:
                        '${DateFormat('MMMM y').format(months[i])}: '
                        '${coeCounts[i]} COEs, ${offerCounts[i]} offer letters',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${coeCounts[i]}',
                          style: Dt.tab(theme.textTheme.labelMedium!),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          height: 100 * coeCounts[i] / maxCoe + 2,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: AirtableTags.statusColor('COE ISSUED/DONE'),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          DateFormat('MMM').format(months[i]),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: i == months.length - 1 ? null : muted,
                            fontWeight: i == months.length - 1
                                ? FontWeight.w700
                                : null,
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

    // ---- Where things stand (tap a stage to list it) ----
    final stageCounts = <String, int>{};
    for (final a in inProgress) {
      stageCounts[a.status] = (stageCounts[a.status] ?? 0) + 1;
    }
    final stages = stageCounts.keys.toList()
      ..sort(
        (x, y) =>
            ApplicationRepository.statusRank(x)
                .compareTo(ApplicationRepository.statusRank(y)),
      );
    final standPanel = AppPanel(
      title: 'In progress, by stage',
      icon: Icons.linear_scale,
      trailingWidget: TextButton(
        onPressed: () => onShowAll(inProgress: true),
        child: Text('List all ${inProgress.length}'),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in stages)
              InkWell(
                onTap: () => onShowAll(status: s),
                borderRadius: BorderRadius.circular(99),
                child: TagChip(
                  '$s · ${stageCounts[s]}',
                  AirtableTags.status(s),
                ),
              ),
          ],
        ),
      ),
    );

    Widget gap() => const SizedBox(height: 12);
    final left = [activityPanel, gap(), attentionPanel, gap(), standPanel];
    final right = [
      weekPanel,
      gap(),
      monthPanel,
      gap(),
      coePanel,
      gap(),
      whoPanel,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 12),
        _TileRow(tiles: tiles, phone: phone),
        gap(),
        if (phone) ...[
          ...left,
          gap(),
          ...right,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: left,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: right,
                ),
              ),
            ],
          ),
      ],
    );
  }

  static String _stageSummary(List<Application> apps) {
    final counts = <String, int>{};
    for (final a in apps) {
      counts[a.status] = (counts[a.status] ?? 0) + 1;
    }
    final keys = counts.keys.toList()
      ..sort(
        (x, y) =>
            ApplicationRepository.statusRank(x)
                .compareTo(ApplicationRepository.statusRank(y)),
      );
    return keys.map((k) => '$k: ${counts[k]}').join('\n');
  }
}

class _Event {
  _Event(this.app, this.icon, this.text, {this.note = false});
  final Application app;
  final IconData icon;
  final String text;
  final bool note;
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.onTap});
  final _Event event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final a = event.app;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Dt.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(event.icon, size: 16, color: muted),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(a.student, style: theme.textTheme.titleSmall),
                      if (a.rto.isNotEmpty)
                        TagChip(a.rto, AirtableTags.rto(a.rto), dense: true),
                      if (a.assignee.isNotEmpty)
                        TagChip(
                          a.assignee,
                          AirtableTags.assignee(a.assignee),
                          dense: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    event.text,
                    maxLines: event.note ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: event.note ? muted : null,
                      fontWeight: event.note ? null : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    required this.caption,
  });
  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
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
    );
  }
}

class _TileRow extends StatelessWidget {
  const _TileRow({required this.tiles, required this.phone});
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
                for (var j = i; j < i + perRow && j < tiles.length; j++) ...[
                  if (j > i) const SizedBox(width: 10),
                  Expanded(child: tiles[j]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The first [count] children, with "Show all" for the rest.
class FirstFew extends StatefulWidget {
  const FirstFew({super.key, required this.children});
  final List<Widget> children;
  static const count = 8;

  @override
  State<FirstFew> createState() => FirstFewState();
}

class FirstFewState extends State<FirstFew> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final more = widget.children.length - FirstFew.count;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...(_all || more <= 0
            ? widget.children
            : widget.children.take(FirstFew.count)),
        if (more > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('today-show-all'),
              onPressed: () => setState(() => _all = !_all),
              child: Text(
                _all ? 'Show fewer' : 'Show all ${widget.children.length}',
              ),
            ),
          ),
      ],
    );
  }
}

/// One person's in-progress applications ("Handling") and those nobody is
/// on yet ("Unassigned"); [person] null shows only the unassigned. A tap on
/// a student opens their details.
Future<void> showHandling(
  BuildContext context,
  WidgetRef ref, {
  required String? person,
  required List<Application> mine,
  required List<Application> unassigned,
  required DateTime? Function(Application) lastActivity,
  required DateTime today,
}) => showDialog<void>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    // Longest waiting first: that's who needs a nudge.
    List<Application> sorted(List<Application> list) => [...list]
      ..sort((a, b) {
        final x = lastActivity(a), y = lastActivity(b);
        if (x == null || y == null) return x == null ? -1 : 1;
        return x.compareTo(y);
      });
    String waited(Application a) {
      final t = lastActivity(a);
      if (t == null) return 'No dates yet';
      final days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
      return days <= 0
          ? 'Active today'
          : days == 1
          ? '1 day since last step'
          : '$days days since last step';
    }

    Widget row(Application a) {
      final where = [a.rto, a.country].where((t) => t.isNotEmpty).join(' · ');
      return ListTile(
        key: ValueKey('handling-app-${a.key}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          a.student,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [if (where.isNotEmpty) where, waited(a)].join('\n'),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        trailing: a.status.isEmpty
            ? null
            : TagChip(a.status, AirtableTags.status(a.status), dense: true),
        onTap: () => showApplicationDetails(context, ref, a),
      );
    }

    Widget section(String title, List<Application> list, String empty) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                '${title.toUpperCase()} · ${list.length}',
                style: microLabel(theme),
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(4),
                child: Text(empty, style: TextStyle(color: muted)),
              ),
            for (final a in sorted(list)) row(a),
          ],
        );

    return AlertDialog(
      title: person == null
          ? const Text('Unassigned applications')
          : Row(
              children: [
                TagChip(person, AirtableTags.assignee(person)),
                const SizedBox(width: 8),
                const Flexible(child: Text('is handling')),
              ],
            ),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (person != null)
              section('Handling', mine, 'Nothing in progress for $person.'),
            section(
              'Unassigned',
              unassigned,
              'Every application in progress has someone on it.',
            ),
            const SizedBox(height: 8),
            Text(
              'In progress applications from the latest upload. Assign them '
              'in Airtable, then upload the CSV again.',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  },
);
