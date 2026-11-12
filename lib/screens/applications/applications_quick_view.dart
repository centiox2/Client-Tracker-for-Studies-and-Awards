import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/airtable_tags.dart';
import '../../design/app_theme.dart';
import '../../repositories/application_repository.dart';
import '../../state/app_state.dart';
import '../../widgets/card_board.dart';
import '../../widgets/clarity.dart';
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
        // "As of the upload" repeats the line above it on a phone.
        if (latest != null &&
            (todaysUploads.isEmpty || MediaQuery.sizeOf(context).width >= 600))
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
      KpiCard(
        label: 'Applications submitted',
        value: '${countOn((a) => a.appDate, today)}',
        unit: 'today',
        caption: weekCaption((a) => a.appDate),
      ),
      KpiCard(
        label: 'Offer letters',
        value: '${countOn((a) => a.offerDate, today)}',
        unit: 'today',
        caption: weekCaption((a) => a.offerDate),
      ),
      KpiCard(
        label: 'COEs issued',
        value: '${countOn((a) => a.coeDate, today)}',
        unit: 'today',
        caption: weekCaption((a) => a.coeDate),
      ),
      KpiCard(
        label: 'Students updated',
        value: '$updatedToday',
        unit: 'today',
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

    // ---- Offer letter reminders: applied over a week ago, no offer ----
    final offerWaits = [
      for (final a in apps)
        if (a.offerOverdue(today)) (a, a.offerWaitDays(today)!),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    final c = context.clarity;
    final offerPanel = AppPanel(
      key: const ValueKey('offer-reminders'),
      title: 'Offer letter reminders',
      subtitle:
          'Submitted more than ${ApplicationRepository.offerReminderDays} '
          'days ago, no offer letter yet',
      trailingWidget: offerWaits.isEmpty
          ? null
          : StatusPill('${offerWaits.length} waiting', tone: PillTone.warning),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (offerWaits.isEmpty)
              Text(
                'Every application submitted over a week ago has its offer '
                'letter (or has moved on).',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              )
            else
              FirstFew(
                showAllKey: const ValueKey('offer-show-all'),
                children: [
                  for (final (a, days) in offerWaits)
                    InkWell(
                      key: ValueKey('offer-wait-${a.key}'),
                      onTap: () => showApplicationDetails(context, ref, a),
                      borderRadius: BorderRadius.circular(Dt.rSm),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                '$days days',
                                style: Dt.tab(theme.textTheme.bodyMedium!)
                                    .copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: days > 21
                                          ? c.negativeFg
                                          : c.warningFg,
                                    ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.student,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (a.rto.isNotEmpty) a.rto,
                                      'submitted '
                                          '${DateFormat('d MMM').format(a.appDate!)}',
                                      if (a.assignee.isNotEmpty) a.assignee,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
                                  color: p == 'No assignee'
                                      ? context.clarity.textMuted
                                      : AirtableTags.assigneeBar(p),
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

    // ---- COEs and offer letters by month, last six, by who handled them ----
    final months = [
      for (var i = 5; i >= 0; i--) DateTime(today.year, today.month - i),
    ];
    final coePanel = MonthlyByAssignee(
      key: const ValueKey('coe-by-month'),
      title: 'COEs by month',
      what: 'COEs',
      months: months,
      apps: apps,
      dateOf: (a) => a.coeDate,
      onOpen: (a) => showApplicationDetails(context, ref, a),
    );
    final appliedToOffer = [
      for (final a in apps)
        if (a.appDate != null &&
            a.offerDate != null &&
            !a.offerDate!.isBefore(a.appDate!) &&
            !_day(a.offerDate!).isBefore(months.first))
          _day(a.offerDate!).difference(_day(a.appDate!)).inDays,
    ];
    final avgWait = appliedToOffer.isEmpty
        ? null
        : appliedToOffer.reduce((x, y) => x + y) / appliedToOffer.length;
    final offerChart = MonthlyByAssignee(
      key: const ValueKey('offers-by-month'),
      title: 'Offer letters by month',
      what: 'offer letters',
      months: months,
      apps: apps,
      dateOf: (a) => a.offerDate,
      onOpen: (a) => showApplicationDetails(context, ref, a),
      footer: [
        if (avgWait != null)
          'Application to offer: ${avgWait.round()} days on average',
        '${offerWaits.length} waiting over '
            '${ApplicationRepository.offerReminderDays} days',
      ].join(' · '),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 12),
        KpiGrid(
          orderKey: 'applications.quick',
          minWidth: phone ? 150 : 190,
          children: tiles,
        ),
        const SizedBox(height: Dt.gap),
        CardBoard(
          boardKey: 'applications.quick',
          cards: [
            BoardCard('offers', offerPanel),
            BoardCard('today', activityPanel),
            BoardCard('attention', attentionPanel),
            BoardCard('stages', standPanel),
            BoardCard('week', weekPanel, column: 1),
            BoardCard('month', monthPanel, column: 1),
            BoardCard('who', whoPanel, column: 1),
            BoardCard('coe', coePanel, column: 2),
            BoardCard('offer-chart', offerChart, column: 2),
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

/// The first [count] children, with "Show all" for the rest.
class FirstFew extends StatefulWidget {
  const FirstFew({
    super.key,
    required this.children,
    this.showAllKey = const ValueKey('today-show-all'),
  });
  final List<Widget> children;
  final Key showAllKey;
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
              key: widget.showAllKey,
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

/// A month-by-month bar chart of one milestone (COEs, offer letters), each
/// bar split by who handled them in their tag colours. A month opens its
/// list; a student there opens their card.
class MonthlyByAssignee extends StatelessWidget {
  const MonthlyByAssignee({
    super.key,
    required this.title,
    required this.what,
    required this.months,
    required this.apps,
    required this.dateOf,
    required this.onOpen,
    this.footer,
  });

  final String title;

  /// What is counted, in a sentence ("COEs").
  final String what;
  final List<DateTime> months;
  final List<Application> apps;
  final DateTime? Function(Application) dateOf;
  final void Function(Application) onOpen;
  final String? footer;

  static const _none = 'No assignee';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final perMonth = [
      for (final m in months)
        [
          for (final a in apps)
            if (dateOf(a) case final d?
                when d.year == m.year && d.month == m.month)
              a,
        ],
    ];
    String who(Application a) => a.assignee.isEmpty ? _none : a.assignee;
    Color colorOf(String p) =>
        p == _none ? c.textMuted : AirtableTags.assigneeBar(p);
    final people = <String, int>{};
    for (final list in perMonth) {
      for (final a in list) {
        people[who(a)] = (people[who(a)] ?? 0) + 1;
      }
    }
    final order = people.keys.toList()
      ..sort((x, y) => people[y]!.compareTo(people[x]!));
    final total = perMonth.fold<int>(0, (s, l) => s + l.length);
    final top = perMonth.fold<int>(1, (m, l) => l.length > m ? l.length : m);

    void showMonth(int i) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${DateFormat('MMMM y').format(months[i])} · '
          '${perMonth[i].length} $what',
        ),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (perMonth[i].isEmpty) Text('No $what this month.'),
              for (final a in [
                ...perMonth[i],
              ]..sort((x, y) => dateOf(x)!.compareTo(dateOf(y)!)))
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(
                    a.student,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      DateFormat('d MMM').format(dateOf(a)!),
                      if (a.rto.isNotEmpty) a.rto,
                    ].join(' · '),
                  ),
                  trailing: a.assignee.isEmpty
                      ? null
                      : TagChip(
                          a.assignee,
                          AirtableTags.assignee(a.assignee),
                          dense: true,
                        ),
                  onTap: () {
                    Navigator.pop(context);
                    onOpen(a);
                  },
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
      ),
    );

    return AppPanel(
      title: title,
      trailing: '$total in 6 months',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < months.length; i++)
                    Expanded(
                      child: Tooltip(
                        message: [
                          '${DateFormat('MMMM y').format(months[i])}: '
                              '${perMonth[i].length} $what',
                          for (final p in order)
                            if (perMonth[i].where((a) => who(a) == p).length
                                case final n when n > 0)
                              '$p: $n',
                        ].join('\n'),
                        child: InkWell(
                          key: ValueKey('$what-month-$i'),
                          onTap: () => showMonth(i),
                          borderRadius: BorderRadius.circular(Dt.rSm),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                '${perMonth[i].length}',
                                style: Dt.tab(theme.textTheme.labelMedium!),
                              ),
                              const SizedBox(height: 3),
                              Container(
                                height: 100 * perMonth[i].length / top + 2,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color: c.track,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    for (final p in order.reversed)
                                      if (perMonth[i]
                                              .where((a) => who(a) == p)
                                              .length
                                          case final n when n > 0)
                                        Expanded(
                                          flex: n,
                                          child: ColoredBox(
                                            color: colorOf(p),
                                            child: const SizedBox.expand(),
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                DateFormat('MMM').format(months[i]),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: i == months.length - 1
                                      ? null
                                      : c.textMuted,
                                  fontWeight: i == months.length - 1
                                      ? FontWeight.w700
                                      : null,
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
            if (order.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final p in order)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: colorOf(p),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '$p ${people[p]}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: c.textMuted,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
            if (footer != null && footer!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
