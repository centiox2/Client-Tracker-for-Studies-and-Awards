import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'design/app_theme.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/history/history_screen.dart';
import 'screens/quick_search/quick_search_dialog.dart';
import 'screens/quick_search/shortcuts_dialog.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/reports/reports_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/staff_management/staff_management_screen.dart';
import 'screens/weekly_tracker/weekly_tracker_screen.dart';
import 'state/app_state.dart';
import 'services/auto_backup.dart';
import 'state/cloud_sync.dart';
import 'screens/weekly_tracker/new_week_dialog.dart';
import 'widgets/motion.dart';
import 'widgets/sync_status.dart';
import 'widgets/numeric_field.dart';
import 'widgets/week_label.dart';

class ClientTrackerApp extends ConsumerWidget {
  const ClientTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Client Tracker · ${Dt.companyName}',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: themeMode,
      // Signed out: the open Reports view. Signed in: the admin workspace.
      // Keyed so signing in or out starts from a fresh shell.
      home: HomeShell(key: ValueKey(ref.watch(adminSessionProvider))),
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  final _focusNode = FocusNode();

  static const _reportsTab = _AppTabInfo(
    AppTab.reports,
    'Reports',
    Icons.insights_outlined,
  );

  static const _adminTabs = <_AppTabInfo>[
    _AppTabInfo(
      AppTab.home,
      'Overview',
      Icons.space_dashboard_outlined,
      shortLabel: 'Home',
    ),
    _AppTabInfo(
      AppTab.week,
      'Weekly tracker',
      Icons.calendar_view_week_outlined,
      shortLabel: 'Tracker',
    ),
    _AppTabInfo(AppTab.history, 'History', Icons.history),
    _AppTabInfo(AppTab.staff, 'Staff', Icons.groups_2_outlined),
    _reportsTab,
    _AppTabInfo(AppTab.settings, 'Settings', Icons.settings_outlined),
  ];

  /// Signed out: Reports plus read-only History and Staff — nothing that
  /// can change data.
  static const _viewerTabs = <_AppTabInfo>[
    _reportsTab,
    _AppTabInfo(AppTab.history, 'History', Icons.history),
    _AppTabInfo(AppTab.staff, 'Staff', Icons.groups_2_outlined),
  ];

  bool get _isViewer => !ref.read(adminSessionProvider);

  List<_AppTabInfo> get _tabs => _isViewer ? _viewerTabs : _adminTabs;

  /// Notices when the date changes so "today" (Quick view, the tracker's
  /// today column, the start-week banner) moves on even if the app is left
  /// open overnight. A refresh is cheap; once a minute is plenty.
  Timer? _clock;
  DateTime _today = _dateOnly(DateTime.now());

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      final now = _dateOnly(DateTime.now());
      if (now != _today) {
        _today = now;
        ref.read(dataVersionProvider.notifier).bump();
        ref.read(autoBackupProvider.notifier).ensureToday();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(shellContextProvider.notifier).capture(context);
      _focusNode.requestFocus();
      // Today's automatic backup, if there isn't one yet.
      ref.read(autoBackupProvider.notifier).ensureToday();
      // Online sync: download the latest, then live updates.
      ref.read(cloudSyncProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// True while the cursor is in an ordinary text box (a name, a search, a
  /// password) — not one of the tracker's number cells, where the page and
  /// undo shortcuts are meant to work.
  bool get _typingInTextField {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final inText =
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
    final inCountCell =
        focused.findAncestorWidgetOfExactType<NumericField>() != null;
    return inText && !inCountCell;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final modifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!modifier) return KeyEventResult.ignored;
    // Search, undo and tab shortcuts are workspace tools — admin only.
    if (_isViewer) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      // Handled, so the browser doesn't also open its own Ctrl+K search.
      showQuickSearch(context);
      return KeyEventResult.handled;
    }
    // In a text box, Ctrl+Z undoes the typing and Ctrl+1–6 must not throw
    // away what was typed by jumping to another page.
    if (_typingInTextField) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      final undone = ref.read(appActionsProvider).undoLastEdit();
      if (undone != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Undo ${undone.isNew ? 'New' : 'Existing'} · ${undone.value}',
            ),
            duration: const Duration(milliseconds: 1400),
          ),
        );
      }
    }
    final keys = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    ];
    final index = keys.indexOf(event.logicalKey);
    if (index >= 0) ref.read(navTabProvider.notifier).set(_tabs[index].tab);
    return KeyEventResult.ignored;
  }

  Widget _page(AppTab tab) => switch (tab) {
    AppTab.home => const DashboardScreen(),
    AppTab.week => const WeeklyTrackerScreen(),
    AppTab.history => HistoryScreen(readOnly: _isViewer),
    AppTab.staff => StaffManagementScreen(readOnly: _isViewer),
    AppTab.reports => const ReportsScreen(),
    AppTab.settings => const SettingsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final isViewer = !ref.watch(adminSessionProvider);
    final requested = ref.watch(navTabProvider);
    // Never render a workspace page when signed out, whatever the nav state.
    final tab = isViewer && !_viewerTabs.any((t) => t.tab == requested)
        ? AppTab.reports
        : requested;
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1050;
    final theme = Theme.of(context);

    final content = Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (_, event) => _handleKey(event),
      child: FadeThroughSwitcher(
        child: KeyedSubtree(key: ValueKey(tab), child: _page(tab)),
      ),
    );

    if (!desktop) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const _MobileTopBar(),
              if (!isViewer) _ContextBar(tab: tab),
              Expanded(child: content),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabs.indexWhere((item) => item.tab == tab),
          onDestinationSelected: (index) =>
              ref.read(navTabProvider.notifier).set(_tabs[index].tab),
          destinations: [
            for (final item in _tabs)
              NavigationDestination(
                icon: Icon(item.icon),
                selectedIcon: Icon(item.icon),
                label: item.shortLabel ?? item.label,
                tooltip: item.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _AppSidebar(
            tabs: _tabs,
            selected: tab,
            onSelect: (value) => ref.read(navTabProvider.notifier).set(value),
            onSearch: isViewer ? null : () => showQuickSearch(context),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: theme.colorScheme.outline,
          ),
          Expanded(
            child: Column(
              children: [
                _TopBar(tab: tab),
                // Navigation lives in the sidebar only (no duplicate tabs).
                if (!isViewer) _ContextBar(tab: tab),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppTabInfo {
  const _AppTabInfo(this.tab, this.label, this.icon, {this.shortLabel});
  final AppTab tab;
  final String label;
  final IconData icon;

  /// Used in the phone's bottom bar, where six long labels don't fit.
  final String? shortLabel;
}

class _AppSidebar extends StatelessWidget {
  const _AppSidebar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });
  final List<_AppTabInfo> tabs;
  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  /// Null hides the search box (signed out there's nothing to search).
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mainTabs = tabs.where((tab) => tab.tab != AppTab.settings).toList();
    final settings = tabs
        .where((tab) => tab.tab == AppTab.settings)
        .firstOrNull;

    Widget navItem(_AppTabInfo item) {
      final active = selected == item.tab;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          curve: Motion.curve,
          decoration: BoxDecoration(
            color: active ? scheme.surfaceContainerHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(Dt.rSm),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Dt.rSm),
              onTap: () => onSelect(item.tab),
              child: SizedBox(
                height: 34,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        size: 16,
                        color: active
                            ? Dt.brand(theme.brightness)
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: active
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (item.tab == AppTab.week)
                        Icon(
                          Icons.chevron_right,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 232,
      child: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            const _AccountMenu(),
            const SizedBox(height: 15),
            if (onSearch != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                  height: 34,
                  // Looks like a field but only opens the search dialog.
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      // Opaque: the field below ignores pointers, so the
                      // detector must claim the tap itself.
                      behavior: HitTestBehavior.opaque,
                      onTap: onSearch,
                      child: IgnorePointer(
                        child: TextField(
                          readOnly: true,
                          decoration: InputDecoration(
                            hintText: 'Quick search…',
                            prefixIcon: const Icon(Icons.search, size: 16),
                            suffixIcon: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Center(
                                widthFactor: 1,
                                child: Text(
                                  'Ctrl K',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            contentPadding: EdgeInsets.zero,
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 34,
                            ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 52,
                            ),
                            filled: true,
                            fillColor: scheme.surfaceContainerLow,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Dt.rSm),
                              borderSide: BorderSide(color: scheme.outline),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Dt.rSm),
                              borderSide: BorderSide(color: scheme.outline),
                            ),
                          ),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            _SidebarCaption(settings == null ? 'VIEW ONLY' : 'WORKSPACE'),
            for (final item in mainTabs) navItem(item),
            const SizedBox(height: 13),
            const Divider(height: 1),
            const Spacer(),
            if (settings != null) ...[
              const Divider(height: 1),
              const SizedBox(height: 8),
              navItem(settings),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

/// Sidebar header: who is signed in, with Sign out.
class _AccountMenu extends ConsumerWidget {
  const _AccountMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isViewer = !ref.watch(adminSessionProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: PopupMenuButton<String>(
        tooltip: 'Account',
        position: PopupMenuPosition.under,
        onSelected: (_) => isViewer
            ? showAdminSignIn(context)
            : ref.read(adminSessionProvider.notifier).signOut(),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'account',
            child: Row(
              children: [
                Icon(isViewer ? Icons.lock_open : Icons.logout, size: 16),
                const SizedBox(width: 10),
                Text(isViewer ? 'Admin sign in' : 'Sign out'),
              ],
            ),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              const _BrandMark(),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Client Tracker',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      isViewer ? 'View only' : 'Signed in as Admin',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.unfold_more, size: 15, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarCaption extends StatelessWidget {
  const _SidebarCaption(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontSize: 10,
        letterSpacing: 0.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Today's date and the time, ticking each minute — so a screen left open
/// (e.g. on the boss's desk) shows at a glance how current it is.
class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
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
    final theme = Theme.of(context);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return Text(
      '${DateFormat('EEEE d MMMM').format(now)} · $time',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.tab});
  final AppTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final isViewer = !ref.watch(adminSessionProvider);
    return SizedBox(
      height: 46,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                _tabLabel(tab),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 14),
              const _Clock(),
              const Spacer(),
              const SyncStatusBadge(),
              const SizedBox(width: 8),
              // Admins refresh from the context bar; the boss gets it here.
              if (isViewer) ...[
                TextButton.icon(
                  onPressed: () =>
                      ref.read(dataVersionProvider.notifier).bump(),
                  style: TextButton.styleFrom(foregroundColor: color),
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('Refresh'),
                ),
                const SizedBox(width: 6),
              ],
              if (!isViewer)
                IconButton(
                  tooltip: 'Keyboard shortcuts',
                  onPressed: () => showShortcutsDialog(context),
                  icon: const Icon(Icons.help_outline, size: 17),
                ),
              if (isViewer)
                OutlinedButton.icon(
                  onPressed: () => showAdminSignIn(context),
                  icon: const Icon(Icons.lock_outline, size: 14),
                  label: const Text('Admin'),
                )
              else
                TextButton.icon(
                  onPressed: () =>
                      ref.read(adminSessionProvider.notifier).signOut(),
                  style: TextButton.styleFrom(foregroundColor: color),
                  icon: const Icon(Icons.logout, size: 15),
                  label: const Text('Sign out'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileTopBar extends ConsumerWidget {
  const _MobileTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    height: 46,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const _BrandMark(),
          const SizedBox(width: 8),
          Text('Client Tracker', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          const SyncStatusBadge(compact: true),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (action) {
              if (action == 'search') {
                showQuickSearch(context);
              } else if (action == 'settings') {
                ref.read(appActionsProvider).selectTab(AppTab.settings);
              } else if (action == 'refresh') {
                ref.read(dataVersionProvider.notifier).bump();
              } else if (action == 'signout') {
                ref.read(adminSessionProvider.notifier).signOut();
              } else if (action == 'signin') {
                showAdminSignIn(context);
              }
            },
            itemBuilder: (context) {
              final admin = ref.read(adminSessionProvider);
              return [
                if (admin) ...const [
                  PopupMenuItem(value: 'search', child: Text('Search')),
                  PopupMenuItem(value: 'settings', child: Text('Settings')),
                ],
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Refresh data'),
                ),
                admin
                    ? const PopupMenuItem(
                        value: 'signout',
                        child: Text('Sign out'),
                      )
                    : const PopupMenuItem(
                        value: 'signin',
                        child: Text('Admin sign in'),
                      ),
              ];
            },
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Dt.rSm),
    child: Image.asset(
      Dt.logoAsset,
      width: 28,
      height: 28,
      filterQuality: FilterQuality.medium,
      semanticLabel: '${Dt.companyName} logo',
    ),
  );
}

class _ContextBar extends ConsumerWidget {
  const _ContextBar({required this.tab});
  final AppTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final week = ref.watch(currentWeekProvider)?.week;
    final range = week == null
        ? 'No active week'
        : '${week.startDate.day}/${week.startDate.month}/${week.startDate.year}  –  '
              '${week.endDate.day}/${week.endDate.month}/${week.endDate.year}';
    final picksWeek = tab == AppTab.home || tab == AppTab.week;
    // On desktop the top bar already names the page; phones have no top bar.
    final desktop = MediaQuery.sizeOf(context).width >= 1050;
    final label = picksWeek ? range : (desktop ? '' : _tabLabel(tab));
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
    );
    final title = picksWeek
        ? _WeekPicker(
            selectedId: week?.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: labelText),
                const Icon(Icons.arrow_drop_down, size: 17),
              ],
            ),
          )
        : labelText;
    return SizedBox(
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: title),
              ),
              if (compact)
                IconButton(
                  tooltip: 'Refresh',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      ref.read(dataVersionProvider.notifier).bump(),
                  icon: const Icon(Icons.refresh, size: 16),
                )
              else
                TextButton.icon(
                  onPressed: () =>
                      ref.read(dataVersionProvider.notifier).bump(),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Refresh'),
                ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: () => showNewWeekDialog(context, ref),
                icon: const Icon(Icons.add, size: 14),
                label: Text(compact ? 'New' : 'New week'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The context bar's week dropdown: switches the week shown on the
/// Overview and in the Weekly tracker.
class _WeekPicker extends ConsumerWidget {
  const _WeekPicker({required this.selectedId, required this.child});
  final int? selectedId;
  final Widget child;

  static const _maxListed = 10;
  static const _allWeeks = -1;
  static const _newWeek = -2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return PopupMenuButton<int>(
      tooltip: 'Switch week',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 260),
      onSelected: (value) {
        if (value == _allWeeks) {
          ref.read(appActionsProvider).selectTab(AppTab.history);
        } else if (value == _newWeek) {
          showNewWeekDialog(context, ref);
        } else {
          ref.read(currentWeekIdProvider.notifier).set(value);
        }
      },
      // Read (not watch) when the menu opens: watching kept every week's
      // totals recalculating on each keystroke in the tracker, just to keep
      // a closed menu up to date.
      itemBuilder: (context) {
        final weeks = ref.read(historyProvider);
        return [
          for (final w in weeks.take(_maxListed))
            PopupMenuItem(
              value: w.week.id,
              height: 40,
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: w.week.id == selectedId
                        ? const Icon(Icons.check, size: 15)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      weekRangeLabel(w.week.startDate, w.week.endDate),
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${w.totals.total}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (weeks.isNotEmpty) const PopupMenuDivider(),
          if (weeks.length > _maxListed)
            const PopupMenuItem(value: _allWeeks, child: Text('All weeks…')),
          const PopupMenuItem(value: _newWeek, child: Text('New week…')),
        ];
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: child,
      ),
    );
  }
}

String _tabLabel(AppTab tab) => switch (tab) {
  AppTab.home => 'Overview',
  AppTab.week => 'Weekly tracker',
  AppTab.history => 'History',
  AppTab.staff => 'Staff',
  AppTab.reports => 'Reports',
  AppTab.settings => 'Settings',
};
