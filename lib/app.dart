import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme.dart';
import 'screens/daily_reports/daily_reports_screen.dart';
import 'services/daily_reports_service.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/history/history_screen.dart';
import 'screens/quick_search/quick_search_dialog.dart';
import 'screens/quick_search/shortcuts_dialog.dart';
import 'screens/applications/applications_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_picker.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/reports/reports_screen.dart';
import 'screens/revenue/revenue_screen.dart';
import 'screens/revenue/scan_payments.dart';
import 'services/share_receiver.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/staff_management/staff_management_screen.dart';
import 'screens/weekly_tracker/new_week_dialog.dart';
import 'screens/weekly_tracker/weekly_tracker_screen.dart';
import 'state/app_state.dart';
import 'services/auto_backup.dart';
import 'state/cloud_sync.dart';
import 'widgets/motion.dart';
import 'widgets/sync_status.dart';
import 'widgets/numeric_field.dart';
import 'widgets/app_page_header.dart';
import 'widgets/clarity.dart';
import 'services/export_actions.dart';

class ClientTrackerApp extends ConsumerWidget {
  const ClientTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: '${Dt.appName} · ${Dt.companyName}',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: themeMode,
      // First sign in (personal accounts) or pick a profile (no online
      // database); then the app as that role allows. Keyed so switching
      // starts afresh.
      home: switch (ref.watch(sessionProvider)) {
        null when ref.watch(accountsEnabledProvider) => const LoginScreen(),
        null => const ProfilePickerScreen(),
        final role => HomeShell(
          key: ValueKey((role, ref.watch(currentUserProvider)?.id)),
        ),
      },
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
    Icons.show_chart,
  );

  static const _adminTabs = <_AppTabInfo>[
    _AppTabInfo(
      AppTab.home,
      'Overview',
      Icons.grid_view_outlined,
      shortLabel: 'Home',
    ),
    _dailyReportsTab,
    _AppTabInfo(
      AppTab.week,
      'Weekly tracker',
      Icons.calendar_today_outlined,
      shortLabel: 'Tracker',
    ),
    _revenueTab,
    _applicationsTab,
    _AppTabInfo(AppTab.history, 'History', Icons.history),
    _AppTabInfo(AppTab.staff, 'Staff', Icons.people_outline),
    _reportsTab,
    _AppTabInfo(AppTab.settings, 'Settings', Icons.settings_outlined),
  ];

  static const _dailyReportsTab = _AppTabInfo(
    AppTab.dailyReports,
    'Daily reports',
    Icons.description_outlined,
    shortLabel: 'Daily',
  );

  static const _applicationsTab = _AppTabInfo(
    AppTab.applications,
    'Applications',
    Icons.school_outlined,
    shortLabel: 'Apps',
  );

  static const _revenueTab = _AppTabInfo(
    AppTab.revenue,
    'Revenue',
    Icons.payments_outlined,
  );

  /// The phone's bottom bar holds five buttons at most; with more pages the
  /// main ones stay and the rest go under "More".
  static const _phoneMain = [
    AppTab.dailyReports,
    AppTab.home,
    AppTab.week,
    AppTab.reports,
    AppTab.revenue,
  ];

  /// Signed out: Reports plus read-only History and Staff — nothing that
  /// can change data.
  static const _viewerTabs = <_AppTabInfo>[
    _dailyReportsTab,
    _reportsTab,
    _revenueTab,
    _applicationsTab,
    _AppTabInfo(AppTab.history, 'History', Icons.history),
    _AppTabInfo(AppTab.staff, 'Staff', Icons.people_outline),
  ];

  /// View-only profiles (Director, Team): nothing that changes data.
  bool get _isViewer => !ref.read(canEditProvider);

  /// The pages this profile may open: revenue only for the admin and the
  /// director, Settings only for the admin.
  List<_AppTabInfo> get _tabs {
    final role = ref.read(sessionProvider);
    final base = _isViewer ? _viewerTabs : _adminTabs;
    return [
      for (final t in base)
        if ((t.tab != AppTab.revenue || (role?.seesRevenue ?? false)) &&
            (t.tab != AppTab.settings || (role?.isAdmin ?? false)) &&
            // Daily reports live with personal accounts (online only).
            (t.tab != AppTab.dailyReports || ref.read(accountsEnabledProvider)))
          t,
    ];
  }

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
        // A new day: the daily report reminder checks again.
        ref.read(reportsChangedProvider.notifier).bump();
        // Revenue was showing "today": move it on to the new day too.
        final revenueDay = ref.read(revenueDateProvider.notifier);
        if (ref.read(revenueDateProvider) == _today) revenueDay.set(now);
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
      // Share → S&A Hub (phones): payment photos or an M-Pesa SMS.
      listenForShares(_onShared);
      _checkKeptSignIn();
    });
  }

  /// Kept signed in on this device: if the admin has since changed this
  /// profile's password, ask for it again.
  Future<void> _checkKeptSignIn() async {
    if (ref.read(accountsEnabledProvider)) {
      // Personal accounts: still signed in online (the account wasn't
      // switched off, the password not reset), and another 30 days.
      final sync = ref.read(cloudSyncProvider.notifier);
      await sync.ready;
      if (mounted) await sync.checkSession();
      return;
    }
    final auth = ref.read(authRepositoryProvider);
    final role = ref.read(sessionProvider);
    if (role == null || auth.rememberedProfile != role) return;
    final sync = ref.read(cloudSyncProvider.notifier);
    await sync.ready;
    if (!mounted) return;
    if (sync.enabled && !sync.canRead) {
      // Kept signed in from before reading needed a sign-in: an open
      // profile signs in again by itself; a locked one asks once.
      if (!auth.isLocked(role)) {
        await sync.openProfile(role, '');
        return;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      ref.read(sessionProvider.notifier).signOut();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Please sign in to ${role.label} once more to keep getting the '
            'latest data.',
          ),
        ),
      );
      return;
    }
    final now = await sync.profileVersion(role);
    if (now == null || !mounted) return; // offline: stay signed in
    final kept = auth.rememberedVersion(role);
    if (kept == null) {
      auth.setRememberedVersion(role, now); // first check: note it
    } else if (kept != now) {
      final messenger = ScaffoldMessenger.of(context);
      ref.read(sessionProvider.notifier).signOut();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'The ${role.label} password was changed. Sign in again.',
          ),
        ),
      );
    }
  }

  /// Photos or text shared into the app: to Revenue, read and reviewed.
  /// Adding needs the admin, so sign in first if needed.
  Future<void> _onShared(SharedItems items) async {
    if (!mounted) return;
    if (!ref.read(isAdminProvider) && ref.read(accountsEnabledProvider)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only an admin can add payments.')),
      );
      await deleteSharedCopies(items.photos);
      return;
    }
    if (!ref.read(isAdminProvider)) {
      await showAdminSignIn(context);
      if (!mounted || !ref.read(isAdminProvider)) {
        await deleteSharedCopies(items.photos);
        return;
      }
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    ref.read(navTabProvider.notifier).set(AppTab.revenue);
    ref.read(revenueDateProvider.notifier).set(today);
    // Let the Revenue page come up behind the review.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (items.photos.isNotEmpty) {
      await importPaymentPhotos(
        context,
        ref,
        today,
        items.photos,
        shared: true,
      );
    } else if (items.text != null) {
      await reviewSharedText(context, ref, today, items.text!);
    }
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
      LogicalKeyboardKey.digit7,
    ];
    final index = keys.indexOf(event.logicalKey);
    if (index >= 0 && index < _tabs.length) {
      ref.read(navTabProvider.notifier).set(_tabs[index].tab);
    }
    return KeyEventResult.ignored;
  }

  Widget _page(AppTab tab) => switch (tab) {
    AppTab.home => const DashboardScreen(),
    AppTab.dailyReports => const DailyReportsScreen(),
    AppTab.week => const WeeklyTrackerScreen(),
    AppTab.revenue => RevenueScreen(readOnly: !ref.read(isAdminProvider)),
    AppTab.applications => ApplicationsScreen(canUpload: !_isViewer),
    AppTab.history => HistoryScreen(readOnly: _isViewer),
    AppTab.staff => StaffManagementScreen(readOnly: _isViewer),
    AppTab.reports => const ReportsScreen(),
    AppTab.settings => const SettingsScreen(),
  };

  /// Every page starts with its Clarity header (date, title, sync). The
  /// Overview draws its own, with its toolbar.
  Widget _withHeader(AppTab tab) {
    final page = _page(tab);
    if (tab == AppTab.home) return page;
    final h = clarityHPad(context);
    final phone = MediaQuery.sizeOf(context).width < 640;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(h, phone ? 20 : 28, h, 4),
          child: AppPageHeader(tab: tab, actions: _headerActions(tab)),
        ),
        Expanded(child: page),
      ],
    );
  }

  /// The buttons in a page's header (the main one last).
  List<Widget> _headerActions(AppTab tab) {
    final canEdit = ref.read(canEditProvider);
    final narrow = MediaQuery.sizeOf(context).width < 920;
    Widget refresh() => OutlinedButton.icon(
      key: const ValueKey('header-refresh'),
      onPressed: () => ref.read(dataVersionProvider.notifier).bump(),
      icon: const Icon(Icons.refresh),
      label: const Text('Refresh'),
    );
    Widget newWeek() => FilledButton.icon(
      key: const ValueKey('header-new-week'),
      onPressed: () => showNewWeekDialog(context, ref),
      icon: const Icon(Icons.add),
      label: const Text('New week'),
    );
    return switch (tab) {
      AppTab.week => [
        // Narrow screens: the week (wide ones have it on the board).
        if (narrow) WeekRangeButton(canStart: canEdit),
        if (!narrow) refresh(),
        if (canEdit && !narrow) newWeek(),
      ],
      AppTab.history => [refresh(), if (canEdit) newWeek()],
      AppTab.revenue when !narrow => [
        OutlinedButton.icon(
          key: const ValueKey('header-change-log'),
          onPressed: () => showRevenueHistory(context, ref),
          icon: const Icon(Icons.history),
          label: const Text('Change log'),
        ),
      ],
      _ => const [],
    };
  }

  /// The phone's "More" sheet: the pages that don't fit the bottom bar.
  void _showMore(List<_AppTabInfo> tabs, AppTab current) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in tabs)
              ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                selected: item.tab == current,
                onTap: () {
                  Navigator.of(sheet).pop();
                  ref.read(navTabProvider.notifier).set(item.tab);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isViewer = !ref.watch(canEditProvider);
    final requested = ref.watch(navTabProvider);
    final allowed = _tabs;
    // Nothing recorded today yet: a dot on Daily reports.
    final reportDue = ref.watch(reportDueTodayProvider).value ?? false;
    // Never render a page this profile may not see, whatever the nav state.
    final tab = allowed.any((t) => t.tab == requested)
        ? requested
        : (isViewer ? AppTab.reports : allowed.first.tab);
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1050;

    final content = Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (_, event) => _handleKey(event),
      child: FadeThroughSwitcher(
        child: KeyedSubtree(key: ValueKey(tab), child: _withHeader(tab)),
      ),
    );

    if (!desktop) {
      final tabs = allowed;
      final useMore = tabs.length > 5;
      // Four main pages (the most important this profile has) plus More.
      final main = useMore
          ? (([
              for (final t in _phoneMain)
                if (tabs.any((i) => i.tab == t)) t,
            ]).take(4).toSet())
          : const <AppTab>{};
      final barTabs = useMore
          ? [
              for (final t in tabs)
                if (main.contains(t.tab)) t,
            ]
          : tabs;
      final moreTabs = useMore
          ? [
              for (final t in tabs)
                if (!main.contains(t.tab)) t,
            ]
          : const <_AppTabInfo>[];
      final barIndex = barTabs.indexWhere((item) => item.tab == tab);
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const _MobileTopBar(),
              Divider(height: 1, color: context.clarity.border),
              Expanded(child: content),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          // A page under "More" lights up the More button.
          selectedIndex: barIndex >= 0 ? barIndex : barTabs.length,
          onDestinationSelected: (index) {
            if (index < barTabs.length) {
              ref.read(navTabProvider.notifier).set(barTabs[index].tab);
            } else {
              _showMore(moreTabs, tab);
            }
          },
          destinations: [
            for (final item in barTabs)
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: reportDue && item.tab == AppTab.dailyReports,
                  smallSize: 8,
                  child: Icon(item.icon),
                ),
                selectedIcon: Icon(item.icon),
                label: item.shortLabel ?? item.label,
                tooltip: item.label,
              ),
            if (useMore)
              NavigationDestination(
                icon: const Icon(Icons.menu),
                selectedIcon: const Icon(Icons.menu),
                label: barIndex >= 0
                    ? 'More'
                    : (moreTabs.firstWhere((t) => t.tab == tab).shortLabel ??
                          moreTabs.firstWhere((t) => t.tab == tab).label),
                tooltip: 'More pages',
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AppSidebar(
            reportDue: reportDue,
            tabs: _tabs,
            selected: tab,
            onSelect: (value) => ref.read(navTabProvider.notifier).set(value),
            onSearch: isViewer ? null : () => showQuickSearch(context),
          ),
          Expanded(child: content),
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

/// The sidebar (248px): the brand, search, the menu, a backup notice when
/// one is due, and who's signed in with the light/dark switch and sign out.
class _AppSidebar extends ConsumerWidget {
  const _AppSidebar({
    this.reportDue = false,
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });
  final List<_AppTabInfo> tabs;

  /// Nothing recorded today yet: a dot on Daily reports.
  final bool reportDue;
  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  /// Null hides the search box (signed out there's nothing to search).
  final VoidCallback? onSearch;

  static const fullWidth = 248.0;
  static const stripWidth = 72.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final c = context.clarity;
    return AnimatedContainer(
      key: const ValueKey('sidebar'),
      duration: Motion.of(context, Motion.fast),
      curve: Motion.curve,
      width: collapsed ? stripWidth : fullWidth,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.border)),
      ),
      clipBehavior: Clip.hardEdge,
      // The layout follows the real width, so nothing is squeezed while the
      // sidebar opens or closes.
      child: LayoutBuilder(
        builder: (context, box) =>
            box.maxWidth < 200 ? _strip(context, ref) : _full(context, ref),
      ),
    );
  }

  Widget _navItem(
    BuildContext context,
    _AppTabInfo item, {
    bool strip = false,
  }) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final active = selected == item.tab;
    final dot = item.tab == AppTab.dailyReports && reportDue
        ? Tooltip(
            message: 'Nothing recorded today yet',
            child: Container(
              key: const ValueKey('report-due-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.seriesNew,
                shape: BoxShape.circle,
              ),
            ),
          )
        : null;
    final icon = Icon(
      item.icon,
      size: 18,
      color: active ? c.accent : c.textSecondary,
    );
    final content = strip
        ? Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              icon,
              if (dot != null) Positioned(right: -8, top: -6, child: dot),
            ],
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                icon,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? c.accent : c.textSecondary,
                    ),
                  ),
                ),
                ?dot,
              ],
            ),
          );
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? c.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(Dt.rSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: strip ? ValueKey('strip-${item.tab.name}') : null,
          borderRadius: BorderRadius.circular(Dt.rSm),
          hoverColor: c.neutralBg,
          onTap: () => onSelect(item.tab),
          child: Semantics(
            selected: active,
            button: true,
            label: strip ? item.label : null,
            child: SizedBox(height: 40, child: content),
          ),
        ),
      ),
    );
    // In the strip the name shows on hover.
    return strip
        ? Tooltip(
            message: item.label,
            preferBelow: false,
            verticalOffset: 0,
            margin: const EdgeInsets.only(left: 64),
            child: tile,
          )
        : tile;
  }

  /// The menu in the middle, scrolling only if the window is very short.
  Widget _menu(BuildContext context, {required bool strip}) => Expanded(
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in tabs)
              if (item.tab != AppTab.settings)
                _navItem(context, item, strip: strip),
          ],
        ),
      ),
    ),
  );

  Widget _full(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final backupDue = ref.watch(backupDueProvider);
    final lastBackup = ref.watch(lastBackupProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: _Brand()),
              IconButton(
                key: const ValueKey('sidebar-collapse'),
                tooltip: 'Close sidebar',
                onPressed: () =>
                    ref.read(sidebarCollapsedProvider.notifier).set(true),
                icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (onSearch != null) ...[
            _SearchBox(onTap: onSearch!),
            const SizedBox(height: 20),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              onSearch == null ? 'VIEW ONLY' : 'WORKSPACE',
              style: microLabel(theme),
            ),
          ),
          _menu(context, strip: false),
          const SizedBox(height: 12),
          if (backupDue) ...[
            NoticeBox(
              key: const ValueKey('backup-notice'),
              title: lastBackup == null
                  ? 'No backup yet'
                  : 'Last backup '
                        '${DateTime.now().difference(lastBackup).inDays} days ago',
              message:
                  'Data lives only on this device. Save a copy to USB or '
                  'email.',
              actionLabel: 'Back up now',
              onAction: () => backupToFile(context, ref),
            ),
            const SizedBox(height: 12),
          ],
          // Settings at the foot of the menu, above who's signed in.
          for (final item in tabs)
            if (item.tab == AppTab.settings) _navItem(context, item),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: c.border),
          ),
          const _UserRow(),
        ],
      ),
    );
  }

  /// The closed sidebar: a strip of icons (names on hover).
  Widget _strip(BuildContext context, WidgetRef ref) {
    final c = context.clarity;
    final backupDue = ref.watch(backupDueProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: _BrandMark(size: 36)),
          const SizedBox(height: 12),
          Center(
            child: IconButton(
              key: const ValueKey('sidebar-expand'),
              tooltip: 'Open sidebar',
              onPressed: () =>
                  ref.read(sidebarCollapsedProvider.notifier).set(false),
              icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
            ),
          ),
          if (onSearch != null)
            Center(
              child: IconButton(
                key: const ValueKey('strip-search'),
                tooltip: 'Search (Ctrl K)',
                onPressed: onSearch,
                icon: const Icon(Icons.search, size: 18),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: c.border),
          ),
          _menu(context, strip: true),
          if (backupDue)
            Center(
              child: IconButton(
                key: const ValueKey('strip-backup'),
                tooltip: 'No recent backup — back up now',
                onPressed: () => backupToFile(context, ref),
                style: IconButton.styleFrom(
                  backgroundColor: c.noticeBg,
                  foregroundColor: c.noticeFg,
                  side: BorderSide(color: c.noticeBorder),
                ),
                icon: const Icon(Icons.backup_outlined, size: 18),
              ),
            ),
          const SizedBox(height: 8),
          for (final item in tabs)
            if (item.tab == AppTab.settings)
              _navItem(context, item, strip: true),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: c.border),
          ),
          const _UserRow(strip: true),
        ],
      ),
    );
  }
}

/// The "S&A" mark and the company.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const _BrandMark(size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Dt.appName,
                  style: theme.textTheme.titleSmall?.copyWith(fontSize: 15),
                ),
                Text(
                  Dt.companyShort,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textMuted,
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

/// Looks like a field; opens the quick search (Ctrl K).
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    return Semantics(
      button: true,
      label: 'Search',
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dt.rSm),
          side: BorderSide(color: c.border),
        ),
        child: InkWell(
          key: const ValueKey('sidebar-search'),
          borderRadius: BorderRadius.circular(Dt.rSm),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.search, size: 18, color: c.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Search clients, staff…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: c.textMuted,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(Dt.rTag),
                    ),
                    child: Text(
                      'Ctrl K',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: c.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who's signed in (tap for the account menu), the light/dark switch and
/// sign out.
class _UserRow extends ConsumerWidget {
  const _UserRow({this.strip = false});

  /// The closed sidebar: avatar, light/dark and sign out, one under another.
  final bool strip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final role = ref.watch(sessionProvider);
    final user = ref.watch(currentUserProvider);
    final canEdit = ref.watch(canEditProvider);
    final name = user?.fullName ?? role?.label ?? '';
    final initials = initialsOf(name);
    final dark = theme.brightness == Brightness.dark;
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: c.border,
      child: Text(
        initials,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: c.text,
        ),
      ),
    );
    final account = MenuAnchor(
      alignmentOffset: const Offset(0, -4),
      menuChildren: [
        if (user != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.key_outlined, size: 16),
            onPressed: () => showChangeOwnPassword(context),
            child: const Text('Change password'),
          ),
        if (canEdit)
          MenuItemButton(
            leadingIcon: const Icon(Icons.keyboard_outlined, size: 16),
            onPressed: () => showShortcutsDialog(context),
            child: const Text('Keyboard shortcuts'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.refresh, size: 16),
          onPressed: () => ref.read(dataVersionProvider.notifier).bump(),
          child: const Text('Refresh data'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: strip ? name : '',
        child: InkWell(
          key: const ValueKey('account-menu'),
          borderRadius: BorderRadius.circular(Dt.rSm),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: strip
                ? avatar
                : Row(
                    children: [
                      avatar,
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: c.text,
                              ),
                            ),
                            Text(
                              user?.role == UserRole.admin
                                  ? 'Administrator'
                                  : user?.role.label ??
                                        (role == null ? '' : 'Profile'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
    final themeButton = IconButton(
      key: const ValueKey('theme-toggle'),
      tooltip: dark ? 'Switch to light' : 'Switch to dark',
      onPressed: () => ref
          .read(themeModeProvider.notifier)
          .toggle(MediaQuery.platformBrightnessOf(context)),
      icon: Icon(
        dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        size: 18,
      ),
    );
    final signOut = user != null
        ? IconButton(
            key: const ValueKey('sign-out'),
            tooltip: 'Sign out',
            onPressed: () => ref.read(sessionProvider.notifier).signOut(),
            icon: const Icon(Icons.logout, size: 18),
          )
        : IconButton(
            key: const ValueKey('switch-profile'),
            tooltip: 'Switch profile',
            onPressed: () => ref.read(sessionProvider.notifier).signOut(),
            icon: const Icon(Icons.switch_account_outlined, size: 18),
          );
    if (strip) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [account, const SizedBox(height: 4), themeButton, signOut],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(child: account),
          themeButton,
          signOut,
        ],
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
          Text(Dt.appName, style: Theme.of(context).textTheme.titleSmall),
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
              } else if (action == 'password') {
                showChangeOwnPassword(context);
              } else if (action == 'signout') {
                ref.read(sessionProvider.notifier).signOut();
              }
            },
            itemBuilder: (context) {
              final role = ref.read(sessionProvider);
              final user = ref.read(currentUserProvider);
              return [
                if (user != null)
                  PopupMenuItem(
                    enabled: false,
                    child: Text('${user.fullName} · ${user.role.label}'),
                  ),
                if (role?.canEdit ?? false)
                  const PopupMenuItem(value: 'search', child: Text('Search')),
                if (role?.isAdmin ?? false)
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('Settings'),
                  ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Refresh data'),
                ),
                if (user != null)
                  const PopupMenuItem(
                    value: 'password',
                    child: Text('Change password'),
                  ),
                PopupMenuItem(
                  value: 'signout',
                  child: Text(
                    user != null
                        ? 'Sign out'
                        : 'Switch profile (${role?.label ?? ''})',
                  ),
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

/// The Studies and Awards logo, on its light square (readable on both
/// themes).
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Dt.rSm),
    child: Image.asset(
      Dt.logoAsset,
      key: const ValueKey('brand-logo'),
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: '${Dt.companyName} logo',
    ),
  );
}
