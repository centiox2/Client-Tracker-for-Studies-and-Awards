import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../screens/weekly_tracker/new_week_dialog.dart';
import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'clarity.dart';
import 'sync_status.dart';
import 'week_label.dart';

/// The name of each page, as its header and the menu show it.
String pageTitle(AppTab tab) => switch (tab) {
  AppTab.home => 'Overview',
  AppTab.dailyReports => 'Daily reports',
  AppTab.revenue => 'Revenue',
  AppTab.applications => 'Applications',
  AppTab.week => 'Weekly tracker',
  AppTab.history => 'History',
  AppTab.staff => 'Staff',
  AppTab.reports => 'Reports',
  AppTab.settings => 'Settings',
};

/// The top of every page: today's date and the time (ticking each minute,
/// so a screen left open shows how current it is), the page's title, and
/// its toolbar — the sync status first, then [actions] (at most one
/// primary button, last).
class AppPageHeader extends ConsumerStatefulWidget {
  const AppPageHeader({
    super.key,
    required this.tab,
    this.actions = const [],
    this.title,
  });

  final AppTab tab;
  final List<Widget> actions;

  /// Overrides the page's usual title.
  final String? title;

  @override
  ConsumerState<AppPageHeader> createState() => _AppPageHeaderState();
}

class _AppPageHeaderState extends ConsumerState<AppPageHeader> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    final now = DateTime.now();
    _timer = Timer(Duration(seconds: 60 - now.second), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final eyebrow =
        '${DateFormat('EEEE, d MMMM y').format(now)} · '
        '${DateFormat('HH:mm').format(now)}';
    // The sync chip (phones show it in the top bar instead).
    final sync =
        ref.watch(cloudSyncProvider.select((s) => s.phase)) != SyncPhase.off &&
        MediaQuery.sizeOf(context).width >= 1050;
    return PageHeader(
      eyebrow: eyebrow,
      title: widget.title ?? pageTitle(widget.tab),
      actions: [if (sync) const SyncStatusBadge(), ...widget.actions],
    );
  }
}

/// "📅 9 – 13 Nov 2026 ▾": the week shown on the Overview and in the
/// Weekly tracker; opens the recent weeks, all weeks and "New week".
class WeekRangeButton extends ConsumerWidget {
  const WeekRangeButton({super.key, this.canStart = true, this.prefix = ''});

  /// Offer "New week…" (people who can change data).
  final bool canStart;

  /// Before the dates ("Week 46 · ").
  final String prefix;

  static const _maxListed = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final week = ref.watch(currentWeekProvider)?.week;
    final label = week == null
        ? 'No active week'
        : '$prefix${shortRangeLabel(week.startDate, week.endDate)}';
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        for (final w in ref.read(historyProvider).take(_maxListed))
          MenuItemButton(
            leadingIcon: SizedBox(
              width: 18,
              child: w.week.id == week?.id
                  ? const Icon(Icons.check, size: 16)
                  : null,
            ),
            trailingIcon: Text(
              '${w.totals.total}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onPressed: () =>
                ref.read(currentWeekIdProvider.notifier).set(w.week.id),
            child: Text(shortRangeLabel(w.week.startDate, w.week.endDate)),
          ),
        if (ref.read(historyProvider).length > _maxListed)
          MenuItemButton(
            onPressed: () =>
                ref.read(appActionsProvider).selectTab(AppTab.history),
            child: const Text('All weeks…'),
          ),
        if (canStart)
          MenuItemButton(
            key: const ValueKey('new-week-menu'),
            leadingIcon: const Icon(Icons.add, size: 16),
            onPressed: () => showNewWeekDialog(context, ref),
            child: const Text('New week…'),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        key: const ValueKey('week-picker'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.calendar_today_outlined, size: 16),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16),
          ],
        ),
      ),
    );
  }
}
