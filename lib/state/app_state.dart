import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/cloud_config.dart';
import '../models/app_user.dart';
import '../models/staff.dart';
import '../models/user_role.dart';
import '../repositories/client_count_repository.dart';
import '../repositories/report_repository.dart';
import '../repositories/revenue_repository.dart';
import '../database/database.dart';
import '../repositories/week_repository.dart';
import 'providers.dart';

export '../models/app_user.dart';
export '../models/daily_report.dart';
export '../models/user_role.dart';
export 'providers.dart';

/// Bumps whenever any data changes so dependent providers refresh.
final dataVersionProvider = NotifierProvider<DataVersionNotifier, int>(
  DataVersionNotifier.new,
);

class DataVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Bumped by the "N" shortcut on Revenue: the page puts the cursor in the
/// amount box for a new payment.
final newPaymentRequestProvider = NotifierProvider<DataVersionNotifier, int>(
  DataVersionNotifier.new,
);

/// All staff (active and inactive) in display order.
final staffListProvider = Provider<List<Staff>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(staffRepositoryProvider).getAll();
});

/// Everyone signs in with their own username and password when this build
/// has the online database (where the accounts are kept). Without it, the
/// app keeps the four shared profiles on this device.
final accountsEnabledProvider = Provider<bool>((ref) => CloudConfig.active);

/// The person signed in (personal accounts); null before anyone signs in,
/// and always null with the shared profiles.
final currentUserProvider = NotifierProvider<CurrentUserNotifier, AppUser?>(
  CurrentUserNotifier.new,
);

class CurrentUserNotifier extends Notifier<AppUser?> {
  /// Opens straight in for the account kept signed in on this device
  /// ("Remember me"); otherwise the sign-in screen.
  @override
  AppUser? build() {
    if (!ref.read(accountsEnabledProvider)) return null;
    return ref.read(authRepositoryProvider).rememberedUser?.user;
  }

  /// [user] signed in (their password, and any first-time new password,
  /// already done).
  void signedIn(AppUser user) {
    ref
        .read(navTabProvider.notifier)
        .set(
          user.role.canEdit
              ? AppTab.home
              : user.role == UserRole.team
              ? AppTab.dailyReports
              : AppTab.reports,
        );
    state = user;
  }

  /// Their latest details from the online database (a new name, say).
  void update(AppUser user) {
    if (state?.id == user.id) state = user;
  }

  void signedOut() {
    ref.read(navTabProvider.notifier).set(AppTab.reports);
    state = null;
  }
}

/// The staff member the signed-in account is linked to (Settings › Users),
/// for "your numbers" across the app; null when not linked.
final linkedStaffProvider = Provider<Staff?>((ref) {
  final id = ref.watch(currentUserProvider)?.staffId;
  if (id == null) return null;
  return ref.watch(staffListProvider).where((s) => s.id == id).firstOrNull;
});

/// A message for the sign-in screen: why someone was signed out.
final signInNoticeProvider = NotifierProvider<SignInNoticeNotifier, String?>(
  SignInNoticeNotifier.new,
);

class SignInNoticeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? notice) => state = notice;
}

/// The role in use: the signed-in person's (personal accounts), or the
/// profile chosen on the profile screen at launch. Null until then.
final sessionProvider = NotifierProvider<SessionNotifier, UserRole?>(
  SessionNotifier.new,
);

/// The same provider by its older name (the admin was the only sign-in).
final adminSessionProvider = sessionProvider;

/// Signed in as the admin (the admin portal: revenue entry, Settings).
final isAdminProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider)?.isAdmin ?? false,
);

/// The profile can enter and change client numbers (admin, admin team).
final canEditProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider)?.canEdit ?? false,
);

/// The profile may see revenue (admin, director).
final seesRevenueProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider)?.seesRevenue ?? false,
);

typedef AdminSessionNotifier = SessionNotifier;

class SessionNotifier extends Notifier<UserRole?> {
  /// Opens straight into a profile kept signed in on this device (the
  /// director's, say); otherwise the profile screen.
  @override
  UserRole? build() {
    if (ref.read(accountsEnabledProvider)) {
      return ref.watch(currentUserProvider)?.role;
    }
    return ref.read(authRepositoryProvider).rememberedProfile;
  }

  /// Checks the admin [password] and signs in on success.
  bool signIn(String password) {
    final ok = ref.read(authRepositoryProvider).verifyAdmin(password);
    if (ok) signInAfterSetup();
    return ok;
  }

  /// Signs straight in as the admin (the password was just checked or set).
  void signInAfterSetup() => open(UserRole.admin);

  /// Opens [role] (its password, if any, already checked).
  void open(UserRole role) {
    ref
        .read(navTabProvider.notifier)
        .set(role.canEdit ? AppTab.home : AppTab.reports);
    state = role;
  }

  /// Back to the profile screen (and no longer kept signed in here). With
  /// personal accounts: signs the person out, back to the sign-in screen.
  void signOut() {
    if (ref.read(accountsEnabledProvider)) {
      // Online sync notices and ends the sign-in online too.
      ref.read(authRepositoryProvider).forgetSignIn();
      ref.read(currentUserProvider.notifier).signedOut();
      return;
    }
    ref.read(authRepositoryProvider).forgetProfile();
    ref.read(navTabProvider.notifier).set(AppTab.reports);
    state = null;
  }
}

/// Navigation sections, shared by sidebar (desktop) and bottom bar (mobile).
enum AppTab {
  home,
  dailyReports,
  week,
  revenue,
  applications,
  history,
  staff,
  reports,
  settings,
}

/// The shell's context, captured by [HomeShell] so helper functions outside
/// the widget tree (e.g. [jumpWeeks]) can show snackbars. Null until the
/// shell has mounted.
final shellContextProvider =
    NotifierProvider<ShellContextNotifier, BuildContext?>(
      ShellContextNotifier.new,
    );

class ShellContextNotifier extends Notifier<BuildContext?> {
  @override
  BuildContext? build() => null;

  /// Captures the shell's context (called once from [HomeShell]).
  void capture(BuildContext context) => state = context;
}

/// The currently visible tab.
final navTabProvider = NotifierProvider<NavTabNotifier, AppTab>(
  NavTabNotifier.new,
);

class NavTabNotifier extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.home;

  void set(AppTab tab) => state = tab;
}

/// A day whose week Reports should open on in Details (set by History's
/// "View report"); Reports consumes and clears it when it opens.
final reportWeekRequestProvider =
    NotifierProvider<ReportWeekRequestNotifier, DateTime?>(
      ReportWeekRequestNotifier.new,
    );

class ReportWeekRequestNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void set(DateTime? day) => state = day;
}

/// Future days the user has confirmed editing in this session (the
/// tracker dims days after today and asks before the first number).
final unlockedDaysProvider = NotifierProvider<UnlockedDaysNotifier, Set<int>>(
  UnlockedDaysNotifier.new,
);

class UnlockedDaysNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void unlock(int dayId) => state = {...state, dayId};
}

/// Finished weeks (by their Monday) the user said yes to changing, this
/// session.
final unlockedWeeksProvider =
    NotifierProvider<UnlockedWeeksNotifier, Set<DateTime>>(
      UnlockedWeeksNotifier.new,
    );

class UnlockedWeeksNotifier extends Notifier<Set<DateTime>> {
  @override
  Set<DateTime> build() => const {};

  void unlock(DateTime monday) => state = {...state, monday};
}

/// The week the user is currently working with (dashboard + tracker).
final currentWeekIdProvider = NotifierProvider<CurrentWeekIdNotifier, int?>(
  CurrentWeekIdNotifier.new,
);

class CurrentWeekIdNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? id) => state = id;
}

class CurrentWeekData {
  CurrentWeekData({
    required this.week,
    required this.days,
    required this.totals,
    required this.staffTotals,
    this.notes = const {},
  });

  final Week week;
  final List<DayWithCounts> days;
  final WeekTotals totals;
  final List<StaffWeekTotals> staffTotals;

  /// Day notes for this week, keyed by day id.
  final Map<int, String> notes;

  DayWithCounts? dayFor(DateTime date) {
    for (final d in days) {
      if (_sameDay(d.day.date, date)) return d;
    }
    return null;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Hydrated data for the week being worked with. Uses the explicitly
/// selected week, falling back to the most recent one — so after a restart
/// the dashboard/tracker immediately show the current week.
final currentWeekProvider = Provider<CurrentWeekData?>((ref) {
  ref.watch(dataVersionProvider);
  final weeks = ref.read(weekRepositoryProvider);
  final counts = ref.read(clientCountRepositoryProvider);
  final stats = ref.read(statisticsServiceProvider);

  CurrentWeekData? build(Week week) {
    final days = counts.weekDaysWithCounts(week.id);
    return CurrentWeekData(
      week: week,
      days: days,
      totals: stats.weekTotals(week),
      staffTotals: stats.staffWeekTotals(week),
      notes: ref.read(dayNotesRepositoryProvider).notesForWeek(week.id),
    );
  }

  final id = ref.watch(currentWeekIdProvider);
  if (id != null) {
    final week = weeks.getWeek(id);
    if (week != null) return build(week);
  }
  final latest = weeks.getAllWeeks().firstOrNull;
  return latest == null ? null : build(latest);
});

/// Totals for the week before the one being worked with, used for the
/// dashboard's "vs last week" comparison. Null when that week doesn't exist.
final previousWeekTotalsProvider = Provider<WeekTotals?>((ref) {
  final current = ref.watch(currentWeekProvider);
  if (current == null) return null;
  final previous = ref
      .read(weekRepositoryProvider)
      .findByStartDate(
        current.week.startDate.subtract(const Duration(days: 7)),
      );
  if (previous == null) return null;
  final totals = ref.read(statisticsServiceProvider).weekTotals(previous);
  // The week shown is still going: compare with the same days of last week
  // (Mon–Thu against Mon–Thu), not the whole of it.
  final today = DateTime.now();
  final start = current.week.startDate;
  final end = current.week.endDate;
  final inProgress =
      !today.isBefore(start) &&
      !today.isAfter(end.add(const Duration(days: 1)));
  if (!inProgress) return totals;
  final cutoff = today.weekday;
  final days = ref.read(weekRepositoryProvider).getDays(previous.id);
  var n = 0, e = 0;
  for (final d in days) {
    if (d.date.weekday > cutoff) continue;
    final t = totals.perDay[d.id];
    if (t == null) continue;
    n += t.newClients;
    e += t.existingClients;
  }
  return WeekTotals(
    newClients: n,
    existingClients: e,
    dailyAverage: totals.dailyAverage,
    perDay: totals.perDay,
  );
});

/// The Monday of the week the user should be working in today (next week on
/// Saturdays and Sundays) when that week hasn't been created yet; otherwise
/// null. Drives the dashboard's one-click "Start week" banner.
final suggestedWeekStartProvider = Provider<DateTime?>((ref) {
  ref.watch(dataVersionProvider);
  final today = DateTime.now();
  final monday = today.weekday >= DateTime.saturday
      ? WeekRepository.mondayOf(today.add(const Duration(days: 7)))
      : WeekRepository.mondayOf(today);
  final exists =
      ref.read(weekRepositoryProvider).findByStartDate(monday) != null;
  return exists ? null : monday;
});

/// Detailed report for a date range (Reports page). Refreshes whenever any
/// data changes, so numbers entered in the tracker show up immediately.
/// Auto-disposed: periods you browse past are dropped instead of being kept
/// (and recalculated) for the rest of the session.
final reportProvider = Provider.autoDispose
    .family<Report, (DateTime, DateTime)>((ref, range) {
      ref.watch(dataVersionProvider);
      return ref.read(reportRepositoryProvider).report(range.$1, range.$2);
    });

/// The first tracked working day (for "all time" ranges); null when none.
final firstTrackedDayProvider = Provider<DateTime?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(reportRepositoryProvider).firstDay();
});

/// Clients per day the team aims for (Settings); null when unset.
final dailyTargetProvider = Provider<int?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(appSettingsRepositoryProvider).dailyTarget;
});

/// Revenue transactions entered for one day.
final revenueEntriesProvider = Provider.family<List<RevenueEntry>, DateTime>((
  ref,
  day,
) {
  ref.watch(dataVersionProvider);
  return ref.read(revenueRepositoryProvider).entriesFor(day);
});

/// Daily revenue totals for an inclusive date range (every day included).
final revenueDaysProvider =
    Provider.family<List<RevenueDay>, (DateTime, DateTime)>((ref, range) {
      ref.watch(dataVersionProvider);
      return ref
          .read(revenueRepositoryProvider)
          .daysBetween(range.$1, range.$2);
    });

/// What payments can be for ("Application fee", …), editable in Settings.
final revenuePurposesProvider = Provider<List<String>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(appSettingsRepositoryProvider).revenuePurposes;
});

/// The currency label shown before amounts ("KSh" unless changed).
final currencyProvider = Provider<String>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(appSettingsRepositoryProvider).currency;
});

/// The day the Revenue page shows (today unless another day is picked).
final revenueDateProvider = NotifierProvider<RevenueDateNotifier, DateTime>(
  RevenueDateNotifier.new,
);

class RevenueDateNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  void set(DateTime day) => state = DateTime(day.year, day.month, day.day);
}

/// When a number was last saved in this session — the tracker's quiet
/// "Saved · 10:42" so you can trust autosave. Null until the first save.
final lastSavedProvider = NotifierProvider<LastSavedNotifier, DateTime?>(
  LastSavedNotifier.new,
);

class LastSavedNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void markNow() => state = DateTime.now();
}

/// Month-to-date totals (derived from day data, never stored).
final monthTotalsProvider = Provider<MonthTotals>((ref) {
  ref.watch(dataVersionProvider);
  return ref.read(statisticsServiceProvider).monthTotals(DateTime.now());
});

/// All weeks for the History screen (newest first) with their totals.
class WeekSummary {
  WeekSummary({required this.week, required this.totals});

  final Week week;
  final WeekTotals totals;
}

final historyProvider = Provider<List<WeekSummary>>((ref) {
  ref.watch(dataVersionProvider);
  final weeks = ref.read(weekRepositoryProvider);
  final stats = ref.read(statisticsServiceProvider);
  return weeks
      .getAllWeeks()
      .map((w) => WeekSummary(week: w, totals: stats.weekTotals(w)))
      .toList();
});

/// When a backup file was last saved on this device (shared_preferences),
/// for the "back up your data" reminder. Null: never, or not loaded yet.
final lastBackupProvider = NotifierProvider<LastBackupNotifier, DateTime?>(
  LastBackupNotifier.new,
);

class LastBackupNotifier extends Notifier<DateTime?> {
  static const _key = 'last_backup_at';

  /// True once the stored value has been read (so the reminder doesn't
  /// flash before it's known).
  bool loaded = false;

  @override
  DateTime? build() {
    SharedPreferences.getInstance().then((prefs) {
      loaded = true;
      final raw = prefs.getString(_key);
      state = raw == null ? null : DateTime.tryParse(raw);
      ref.notifyListeners();
    });
    return null;
  }

  void markNow() {
    final now = DateTime.now();
    state = now;
    SharedPreferences.getInstance().then(
      (p) => p.setString(_key, now.toIso8601String()),
    );
  }
}

/// True when the backup reminder should show: never backed up, or not in
/// the last 7 days.
final backupDueProvider = Provider<bool>((ref) {
  final last = ref.watch(lastBackupProvider);
  if (!ref.read(lastBackupProvider.notifier).loaded) return false;
  return last == null ||
      DateTime.now().difference(last) > const Duration(days: 7);
});

/// Theme mode (light / dark / system), persisted via shared_preferences.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  bool _loaded = false;

  @override
  ThemeMode build() {
    _load();
    // Clarity is light-first: light, or dark when the computer is set to
    // dark — until someone picks one with the moon button.
    return ThemeMode.system;
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;

    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('themeMode') ?? ThemeMode.system.index;
    if (index >= 0 && index < ThemeMode.values.length) {
      state = ThemeMode.values[index];
    }
  }

  /// The moon button: light ↔ dark ([platform] is the computer's setting,
  /// for when nothing has been picked yet).
  void toggle(Brightness platform) {
    final dark = switch (state) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platform == Brightness.dark,
    };
    set(dark ? ThemeMode.light : ThemeMode.dark);
  }

  void set(ThemeMode mode) {
    state = mode;
    SharedPreferences.getInstance().then(
      (p) => p.setInt('themeMode', mode.index),
    );
  }
}

/// Actions shared by screens (keeps business logic out of widgets).
class AppActions {
  AppActions(this._ref);

  final Ref _ref;

  /// Switches the visible section; can open a specific week in the tracker.
  /// Opens Reports › Details on the week containing [day].
  void openWeekReport(DateTime day) {
    _ref.read(reportWeekRequestProvider.notifier).set(day);
    _ref.read(navTabProvider.notifier).set(AppTab.reports);
  }

  void selectTab(AppTab tab, {int? weekId}) {
    if (weekId != null) {
      _ref.read(currentWeekIdProvider.notifier).set(weekId);
    }
    _ref.read(navTabProvider.notifier).set(tab);
  }

  /// Creates the week for the Monday–Friday containing [anyDay]. Returns the
  /// new week, or throws [StateError] if it already exists.
  Week createWeek(DateTime anyDay) {
    final week = _ref.read(weekRepositoryProvider).createWeekFor(anyDay);
    _touch();
    return week;
  }

  /// Saves cumulative New/Existing counts for one staff/day. The stored value
  /// is the new cumulative total (3 → 5 stores 5, not 8).
  ///
  /// Before overwriting, the previous value is remembered in the undo buffer
  /// so the user can revert a mistaken edit (Clear or Ctrl+Z restore it).
  void saveCount({
    required int dayId,
    required int staffId,
    required int newClients,
    required int existingClients,
  }) {
    final repo = _ref.read(clientCountRepositoryProvider);
    final existing = repo.countValues(dayId, staffId);
    rememberCount(dayId, staffId, true, existing.newClients);
    rememberCount(dayId, staffId, false, existing.existingClients);
    repo.saveCount(
      dayId: dayId,
      staffId: staffId,
      newClients: newClients,
      existingClients: existingClients,
    );
    _saved();
  }

  /// Marks (or unmarks) one staff member off on one working day. Numbers
  /// already entered are kept but excluded from every total.
  void setStaffDayOff({
    required int dayId,
    required int staffId,
    required bool off,
  }) {
    _ref
        .read(timeOffRepositoryProvider)
        .setDay(dayId: dayId, staffId: staffId, off: off);
    _touch();
  }

  /// Marks several staff on or off for one day at once ([changes] maps
  /// staff id → off) — the day time-off dialog and "Holiday".
  void setDayOffForStaff({
    required int dayId,
    required Map<int, bool> changes,
  }) {
    if (changes.isEmpty) return;
    _ref
        .read(timeOffRepositoryProvider)
        .setDayForStaff(dayId: dayId, changes: changes);
    _touch();
  }

  /// Show / hide zeros: a display preference of this device only. It used
  /// to be saved on the week, which is shared online — so each press
  /// queued an upload and flipped every other device too.
  void toggleShowZeros() => _ref.read(showZerosProvider.notifier).toggle();

  void _touch() => _ref.read(dataVersionProvider.notifier).bump();

  /// A change to client numbers: refresh, and record the save time.
  void _saved() {
    _ref.read(lastSavedProvider.notifier).markNow();
    _touch();
  }

  /// Saves (or, when blank, removes) a day's note.
  void setDayNote(int dayId, String note) {
    _ref.read(dayNotesRepositoryProvider).setNote(dayId, note);
    _touch();
  }

  // ---- Revenue -----------------------------------------------------------

  int addRevenue(
    DateTime day,
    int amountCents, {
    String note = '',
    DateTime? at,
    String purpose = '',
  }) {
    final id = _ref
        .read(revenueRepositoryProvider)
        .add(day, amountCents, note: note, at: at, purpose: purpose);
    _touch();
    return id;
  }

  /// Takes back a batch just added (Undo after adding from photos).
  void removeRevenue(Iterable<int> ids) {
    final repo = _ref.read(revenueRepositoryProvider);
    for (final id in ids) {
      repo.delete(id);
    }
    _touch();
  }

  void updateRevenue(
    int id, {
    required int amountCents,
    required String note,
    DateTime? at,
    String? purpose,
  }) {
    _ref
        .read(revenueRepositoryProvider)
        .update(
          id,
          amountCents: amountCents,
          note: note,
          at: at,
          purpose: purpose,
        );
    _touch();
  }

  void deleteRevenue(int id) {
    _ref.read(revenueRepositoryProvider).delete(id);
    _touch();
  }

  void restoreRevenue(RevenueEntry entry) {
    _ref.read(revenueRepositoryProvider).restore(entry);
    _touch();
  }

  void setRevenuePurposes(List<String> purposes) {
    _ref.read(appSettingsRepositoryProvider).revenuePurposes = purposes;
    _touch();
  }

  void setCurrency(String currency) {
    _ref.read(appSettingsRepositoryProvider).currency = currency;
    _touch();
  }

  /// Sets the daily client target; null or 0 clears it.
  void setDailyTarget(int? target) {
    _ref.read(appSettingsRepositoryProvider).dailyTarget = target;
    _touch();
  }

  /// Repeats last week's time off on the same weekdays of [weekId] — for
  /// regular days off (e.g. someone who never works Fridays). Returns how
  /// many staff-days were marked; existing marks are left as they are.
  int copyPreviousWeekTimeOff(int weekId) {
    final weeks = _ref.read(weekRepositoryProvider);
    final week = weeks.getWeek(weekId);
    if (week == null) return 0;
    final previous = weeks.findByStartDate(
      week.startDate.subtract(const Duration(days: 7)),
    );
    if (previous == null) return 0;
    final timeOff = _ref.read(timeOffRepositoryProvider);
    final lastWeek = timeOff.offMapForWeek(previous.id);
    final prevDays = {for (final d in weeks.getDays(previous.id)) d.id: d};
    final thisDays = {for (final d in weeks.getDays(weekId)) d.weekday: d};
    // Only staff who are on this week's board.
    final onBoard = {
      for (final d
          in _ref
              .read(clientCountRepositoryProvider)
              .weekDaysWithCounts(weekId))
        for (final r in d.rows) r.staffId,
    };
    var marked = 0;
    for (final MapEntry(key: prevDayId, value: staffIds) in lastWeek.entries) {
      final weekday = prevDays[prevDayId]?.weekday;
      final target = weekday == null ? null : thisDays[weekday];
      if (target == null) continue;
      final already = timeOff.offStaffIds(target.id);
      final changes = {
        for (final s in staffIds)
          if (onBoard.contains(s) && !already.contains(s)) s: true,
      };
      if (changes.isEmpty) continue;
      timeOff.setDayForStaff(dayId: target.id, changes: changes);
      marked += changes.length;
    }
    if (marked > 0) _touch();
    return marked;
  }

  /// Remembers the last committed value for one count cell so the user can
  /// undo a mistaken edit (the Clear affordance and Ctrl+Z both restore it).
  void rememberCount(int dayId, int staffId, bool isNew, int value) {
    final key = '$dayId:$staffId:${isNew ? "n" : "e"}';
    _ref.read(undoProvider.notifier).remember(key, value);
  }

  /// Restores the previous value for one count cell, if one was remembered.
  /// Returns the restored value, or `null` when there is nothing to undo.
  /// The restored value is written to the database *without* re-memorizing,
  /// so the undo buffer for the other cell in the same row is preserved.
  int? undoCount(int dayId, int staffId, bool isNew) {
    final key = '$dayId:$staffId:${isNew ? "n" : "e"}';
    final restored = _ref.read(undoProvider.notifier).pop(key);
    if (restored == null) return null;
    _ref
        .read(clientCountRepositoryProvider)
        .saveCount(
          dayId: dayId,
          staffId: staffId,
          newClients: isNew ? restored : _currentNew(dayId, staffId),
          existingClients: isNew ? _currentExisting(dayId, staffId) : restored,
        );
    _saved();
    return restored;
  }

  /// The currently stored New value for one cell.
  int _currentNew(int dayId, int staffId) {
    return _ref
        .read(clientCountRepositoryProvider)
        .countValues(dayId, staffId)
        .newClients;
  }

  /// The currently stored Existing value for one cell.
  int _currentExisting(int dayId, int staffId) {
    return _ref
        .read(clientCountRepositoryProvider)
        .countValues(dayId, staffId)
        .existingClients;
  }

  /// Undoes the most recent count edit, regardless of which cell it was in.
  /// Returns the cell identity and restored value, or `null` when the buffer
  /// is empty. Used by the global Ctrl+Z / Cmd+Z shortcut.
  ({int dayId, int staffId, bool isNew, int value})? undoLastEdit() {
    final popped = _ref.read(undoProvider.notifier).popMostRecent();
    if (popped == null) return null;
    final (key, previous) = popped;
    final parts = key.split(':');
    final dayId = int.parse(parts[0]);
    final staffId = int.parse(parts[1]);
    final isNew = parts[2] == 'n';
    _ref
        .read(clientCountRepositoryProvider)
        .saveCount(
          dayId: dayId,
          staffId: staffId,
          newClients: isNew ? previous : _currentNew(dayId, staffId),
          existingClients: isNew ? _currentExisting(dayId, staffId) : previous,
        );
    _saved();
    return (dayId: dayId, staffId: staffId, isNew: isNew, value: previous);
  }
}

final appActionsProvider = Provider<AppActions>((ref) => AppActions(ref));

/// Empty tracker cells as "0" (true) or a dash. Kept on this device only
/// (in the local sync_state table, which is never uploaded), so changing it
/// starts no sync and leaves everyone else's screen as it is.
final showZerosProvider = NotifierProvider<ShowZerosNotifier, bool>(
  ShowZerosNotifier.new,
);

class ShowZerosNotifier extends Notifier<bool> {
  static const _key = 'show_zeros';

  @override
  bool build() {
    final rows = ref.read(databaseProvider).raw.select(
      'SELECT v FROM sync_state WHERE k = ?;',
      [_key],
    );
    return rows.isEmpty ? true : rows.first['v'] == '1';
  }

  void toggle() => set(!state);

  void set(bool on) {
    state = on;
    ref.read(databaseProvider).raw.execute(
      'INSERT INTO sync_state (k, v) VALUES (?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
      [_key, on ? '1' : '0'],
    );
  }
}

/// The desktop sidebar folded to a strip of icons. Kept on this device only
/// (local sync_state table, never uploaded).
final sidebarCollapsedProvider =
    NotifierProvider<SidebarCollapsedNotifier, bool>(
      SidebarCollapsedNotifier.new,
    );

class SidebarCollapsedNotifier extends Notifier<bool> {
  static const _key = 'sidebar_collapsed';

  @override
  bool build() {
    final rows = ref.read(databaseProvider).raw.select(
      'SELECT v FROM sync_state WHERE k = ?;',
      [_key],
    );
    return rows.isNotEmpty && rows.first['v'] == '1';
  }

  void toggle() => set(!state);

  void set(bool collapsed) {
    state = collapsed;
    ref.read(databaseProvider).raw.execute(
      'INSERT INTO sync_state (k, v) VALUES (?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
      [_key, collapsed ? '1' : '0'],
    );
  }
}

/// Text size on this device: 1.0 normal, 1.15 large, 1.3 larger. Applied on
/// top of the computer's own setting; never synced.
final textScaleProvider = NotifierProvider<TextScaleNotifier, double>(
  TextScaleNotifier.new,
);

class TextScaleNotifier extends Notifier<double> {
  static const _key = 'text_scale';
  static const sizes = <(double, String)>[
    (1.0, 'Normal'),
    (1.15, 'Large'),
    (1.3, 'Larger'),
  ];

  @override
  double build() {
    final rows = ref.read(databaseProvider).raw.select(
      'SELECT v FROM sync_state WHERE k = ?;',
      [_key],
    );
    return rows.isEmpty ? 1.0 : double.tryParse('${rows.first['v']}') ?? 1.0;
  }

  void set(double scale) {
    state = scale;
    ref.read(databaseProvider).raw.execute(
      'INSERT INTO sync_state (k, v) VALUES (?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
      [_key, '$scale'],
    );
  }
}

/// Small per-device remembered choices (a page's last tab, sort…), kept in
/// the local sync_state table under "ui." plus the name. Never synced.
/// Bumped when card orders are reset, so every grid reloads its order.
final cardOrderVersionProvider = NotifierProvider<DataVersionNotifier, int>(
  DataVersionNotifier.new,
);

final uiPrefProvider = Provider<UiPrefs>(
  (ref) => UiPrefs(ref.read(databaseProvider)),
);

class UiPrefs {
  UiPrefs(this._db);
  final AppDatabase _db;

  String? get(String name) {
    try {
      final rows = _db.raw.select('SELECT v FROM sync_state WHERE k = ?;', [
        'ui.$name',
      ]);
      return rows.isEmpty ? null : rows.first['v'] as String?;
    } catch (_) {
      return null;
    }
  }

  void set(String name, String value) {
    try {
      _db.raw.execute(
        'INSERT INTO sync_state (k, v) VALUES (?, ?) '
        'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
        ['ui.$name', value],
      );
    } catch (_) {}
  }

  /// Forgets every setting whose name starts with [prefix].
  void clearPrefix(String prefix) {
    try {
      _db.raw.execute('DELETE FROM sync_state WHERE k LIKE ?;', [
        'ui.$prefix%',
      ]);
    } catch (_) {}
  }

  /// The enum value saved under [name], or [fallback].
  T pick<T extends Enum>(String name, List<T> values, T fallback) {
    final saved = get(name);
    return values.where((v) => v.name == saved).firstOrNull ?? fallback;
  }
}
