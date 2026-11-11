import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/auth_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/report_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

/// Open Reports (no login), the admin password that guards the workspace,
/// and the Reports page itself.
void main() {
  late AppDatabase db;

  setUpAll(() => AuthRepository.iterations = 10);
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  Future<void> pumpApp(
    WidgetTester tester, {
    bool admin = false,
    Size size = const Size(1600, 1000),
    UserRole? role,
    bool picker = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (role != null)
            adminSessionProvider.overrideWith(() => _AsRole(role))
          else if (!picker)
            adminSessionProvider.overrideWith(
              admin ? SignedInSession.new : DirectorSession.new,
            ),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  int staffId(String name) =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [name]).first['id']!
          as int;

  // ---------------------------------------------------------------- auth ---

  test('AuthRepository: set, verify and change the admin password', () {
    final auth = AuthRepository(db);
    expect(auth.hasAdminPassword, isFalse);
    expect(auth.verifyAdmin('anything'), isFalse);

    auth.setAdminPassword('first-pass');
    expect(auth.hasAdminPassword, isTrue);
    expect(auth.verifyAdmin('first-pass'), isTrue);
    expect(auth.verifyAdmin('wrong'), isFalse);

    auth.setAdminPassword('second-pass');
    expect(auth.verifyAdmin('first-pass'), isFalse);
    expect(auth.verifyAdmin('second-pass'), isTrue);

    // Only a hash is stored, never the password itself.
    final stored = db.raw.select('SELECT password_hash FROM app_accounts;');
    expect(stored.single['password_hash'], isNot('second-pass'));
    expect(() => auth.setAdminPassword('ab'), throwsArgumentError);
  });

  testWidgets('the app opens on the profiles; Director views Reports', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, picker: true);
    expect(find.text('Who’s using the app?'), findsOneWidget);
    for (final r in UserRole.values) {
      expect(find.byKey(ValueKey('profile-${r.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('profile-director')));
    await tester.pumpAndSettle();

    expect(find.text('Latest updates'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('account-menu')),
        matching: find.text('Director'),
      ),
      findsOneWidget,
    );
    expect(find.text('Revenue'), findsWidgets); // the director sees it
    // Nothing that changes data.
    for (final hidden in [
      'Weekly tracker',
      'Overview',
      'Settings',
      'New week',
      'Edit in tracker',
      'Quick search…',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
  });

  testWidgets('Team sees everything except revenue', (tester) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, role: UserRole.team);
    expect(find.text('Latest updates'), findsOneWidget);
    expect(find.text('Revenue'), findsNothing);
    expect(find.text('Revenue today'), findsNothing);
    expect(find.byKey(const ValueKey('quick-revenue')), findsNothing);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Staff'), findsOneWidget);
    expect(find.text('Weekly tracker'), findsNothing);
  });

  testWidgets('Admin team edits everything except revenue and settings', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, role: UserRole.adminTeam);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('account-menu')),
        matching: find.text('Admin team'),
      ),
      findsOneWidget,
    );
    expect(find.text('Weekly tracker'), findsOneWidget);
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Revenue'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    expect(find.text('Revenue today'), findsNothing);
  });

  testWidgets('a profile with a password asks for it', (tester) async {
    AuthRepository(db).setProfilePassword(UserRole.team, 'team-pass');
    await pumpApp(tester, picker: true);
    await tester.tap(find.byKey(const ValueKey('profile-team')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-password')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-password')),
      'nope',
    );
    await tester.tap(find.byKey(const ValueKey('profile-open')));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password. Try again.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-password')),
      'team-pass',
    );
    await tester.tap(find.byKey(const ValueKey('profile-open')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('account-menu')),
        matching: find.text('Team'),
      ),
      findsOneWidget,
    );

    // Switch profile goes back to the profiles.
    await tester.tap(find.byKey(const ValueKey('switch-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Who’s using the app?'), findsOneWidget);
  });

  testWidgets('the director stays signed in on her device', (tester) async {
    final auth = AuthRepository(db);
    auth.setProfilePassword(UserRole.director, 'boss-pass');
    await pumpApp(tester, picker: true);
    await tester.tap(find.byKey(const ValueKey('profile-director')));
    await tester.pumpAndSettle();
    // Ticked for the director.
    final stay = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('profile-stay')),
    );
    expect(stay.value, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('profile-password')),
      'boss-pass',
    );
    await tester.tap(find.byKey(const ValueKey('profile-open')));
    await tester.pumpAndSettle();
    expect(auth.rememberedProfile, UserRole.director);

    // Next launch: straight in, no profile screen, no password.
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, picker: true);
    expect(find.text('Who’s using the app?'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('account-menu')),
        matching: find.text('Director'),
      ),
      findsOneWidget,
    );

    // Switch profile signs out for good.
    await tester.tap(find.byKey(const ValueKey('switch-profile')));
    await tester.pumpAndSettle();
    expect(auth.rememberedProfile, isNull);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, picker: true);
    expect(find.text('Who’s using the app?'), findsOneWidget);

    // A new password from the admin ends it too.
    auth.rememberProfile(UserRole.director);
    auth.setProfilePassword(UserRole.director, 'new-pass');
    expect(auth.rememberedProfile, isNull);
  });

  testWidgets('other profiles aren’t kept signed in unless ticked', (
    tester,
  ) async {
    AuthRepository(db).setProfilePassword(UserRole.team, 'team-pass');
    await pumpApp(tester, picker: true);
    await tester.tap(find.byKey(const ValueKey('profile-team')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('profile-stay')))
          .value,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-password')),
      'team-pass',
    );
    await tester.tap(find.byKey(const ValueKey('profile-open')));
    await tester.pumpAndSettle();
    expect(AuthRepository(db).rememberedProfile, isNull);
  });

  testWidgets('the admin sets and clears profile passwords in Settings', (
    tester,
  ) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final set = find.byKey(const ValueKey('profile-set-director'));
    await tester.ensureVisible(set);
    await tester.pumpAndSettle();
    await tester.tap(set);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-new-password')),
      'boss-pass',
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-new-password-again')),
      'boss-typo',
    );
    await tester.tap(find.byKey(const ValueKey('profile-save-password')));
    await tester.pumpAndSettle();
    expect(find.text('The two passwords don’t match.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-new-password-again')),
      'boss-pass',
    );
    await tester.tap(find.byKey(const ValueKey('profile-save-password')));
    await tester.pumpAndSettle();
    final auth = AuthRepository(db);
    expect(auth.isLocked(UserRole.director), isTrue);
    expect(auth.verifyProfile(UserRole.director, 'boss-pass'), isTrue);
    expect(auth.isLocked(UserRole.team), isFalse);

    final open = find.byKey(const ValueKey('profile-open-director'));
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(auth.isLocked(UserRole.director), isFalse);
  });

  testWidgets('the boss sees read-only History and Staff', (tester) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);

    // History: weeks listed with View, but nothing to delete.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('View'), findsOneWidget);
    expect(find.byTooltip('Delete week'), findsNothing);

    // Staff: the team, with no add, rename, deactivate, delete or reorder.
    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Add to the team'), findsNothing);
    expect(find.byTooltip('Rename'), findsNothing);
    expect(find.byTooltip('Delete permanently'), findsNothing);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);

    // View opens that week's detailed report.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('Quick view'), findsOneWidget); // on Reports now
    expect(find.text('Mon – Fri'), findsNothing); // History's column
    expect(find.text('Latest updates'), findsNothing); // Details, not Quick
    expect(
      find.textContaining(DateFormat('d MMM').format(week.startDate)),
      findsWidgets,
    );
  });

  testWidgets(
    'first Admin click creates the password and opens the workspace',
    (tester) async {
      await pumpApp(tester, picker: true);
      await tester.tap(find.byKey(const ValueKey('profile-admin')));
      await tester.pumpAndSettle();
      expect(find.text('Create the admin password'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'admin-pass');
      await tester.enterText(fields.at(1), 'admin-pass');
      await tester.tap(find.text('Create password and sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Clients this month'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('account-menu')),
          matching: find.text('Admin'),
        ),
        findsOneWidget,
      );
      expect(AuthRepository(db).verifyAdmin('admin-pass'), isTrue);
    },
  );

  testWidgets('admin signs in, then switches back to the profiles', (
    tester,
  ) async {
    AuthRepository(db).setAdminPassword('admin-pass');
    await pumpApp(tester, picker: true);

    await tester.tap(find.byKey(const ValueKey('profile-admin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'admin-pass');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Clients this month'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('switch-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Who’s using the app?'), findsOneWidget);
    expect(find.text('Weekly tracker'), findsNothing);
  });

  testWidgets('wrong password is rejected, and Back returns to the profiles', (
    tester,
  ) async {
    AuthRepository(db).setAdminPassword('admin-pass');
    await pumpApp(tester, picker: true);

    await tester.tap(find.byKey(const ValueKey('profile-admin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password. Try again.'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Who’s using the app?'), findsOneWidget);
    expect(find.text('Clients this month'), findsNothing);
  });

  // ------------------------------------------------------------- reports ---

  group('ReportRepository', () {
    test('per-staff and per-day totals exclude days off', () {
      final weeks = WeekRepository(db);
      final counts = ClientCountRepository(db);
      // A fixed past week: Mon 28 Sep – Fri 2 Oct 2026.
      final week = weeks.createWeekFor(DateTime(2026, 9, 28));
      final days = weeks.getDays(week.id);
      void save(int day, String name, int n, int e) => counts.saveCount(
        dayId: days[day].id,
        staffId: staffId(name),
        newClients: n,
        existingClients: e,
      );
      save(0, 'Joy', 3, 2);
      save(1, 'Joy', 1, 0);
      save(0, 'Ian', 0, 4);
      save(2, 'Ian', 9, 9); // Ian is off that day — must not count.
      TimeOffRepository(db)
          .setDay(dayId: days[2].id, staffId: staffId('Ian'), off: true);

      final r = ReportRepository(db)
          .report(DateTime(2026, 9, 28), DateTime(2026, 10, 2));
      expect(r.total, 10);
      expect(r.newClients, 4);
      expect(r.existingClients, 6);
      expect(r.days, hasLength(5));
      expect(r.days[0].total, 9);
      expect(r.days[2].total, 0);
      expect(r.days[2].offCount, 1);
      expect(r.dailyAverage, closeTo(10 / 5, 0.001));
      expect(r.staffWithClients, 2);

      // Most clients first.
      expect(r.staff.first.name, 'Joy');
      expect(r.staff.first.total, 6);
      final ian = r.staff.firstWhere((s) => s.name == 'Ian');
      expect(ian.total, 4);
      expect(ian.daysOff, 1);
      expect(ian.daysWorked, 4);
      expect(r.lastUpdated, isNotNull);
    });

    test('a single day and a month range', () {
      final weeks = WeekRepository(db);
      final week = weeks.createWeekFor(DateTime(2026, 9, 28));
      final days = weeks.getDays(week.id);
      ClientCountRepository(db).saveCount(
        dayId: days[4].id, // Fri 2 Oct
        staffId: staffId('Joy'),
        newClients: 5,
        existingClients: 0,
      );
      final repo = ReportRepository(db);
      expect(
        repo.report(DateTime(2026, 10, 2), DateTime(2026, 10, 2)).total,
        5,
      );
      // September only covers Mon 28 – Wed 30 of that week.
      final sept = repo.report(DateTime(2026, 9, 1), DateTime(2026, 9, 30));
      expect(sept.days, hasLength(3));
      expect(sept.total, 0);
      expect(
        repo.report(DateTime(2026, 10, 1), DateTime(2026, 10, 31)).total,
        5,
      );
    });
  });

  /// The day Quick view treats as "today" (Friday at the weekend).
  DateTime quickDay() {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day);
    return d.weekday > 5 ? d.subtract(Duration(days: d.weekday - 5)) : d;
  }

  void saveOn(DateTime date, String name, int n, int e) {
    final weeks = WeekRepository(db);
    final week = weeks.findByDate(date) ?? weeks.createWeekFor(date);
    final day = weeks
        .getDays(week.id)
        .firstWhere(
          (d) => d.date.day == date.day && d.date.month == date.month,
        );
    ClientCountRepository(db).saveCount(
      dayId: day.id,
      staffId: staffId(name),
      newClients: n,
      existingClients: e,
    );
  }

  test('ReportRepository: staff-by-day cells and latest activity', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final days = weeks.getDays(week.id);
    final counts = ClientCountRepository(db);
    counts.saveCount(
      dayId: days[0].id,
      staffId: staffId('Joy'),
      newClients: 2,
      existingClients: 1,
    );
    counts.saveCount(
      dayId: days[1].id,
      staffId: staffId('Ian'),
      newClients: 0,
      existingClients: 4,
    );
    TimeOffRepository(db)
        .setDay(dayId: days[2].id, staffId: staffId('Joy'), off: true);

    // Fixed timestamps: two saves in one test can share a millisecond.
    db.raw.execute(
      'UPDATE client_counts SET updated_at = ? WHERE staff_id = ?;',
      ['2026-09-28T09:00:00.000', staffId('Joy')],
    );
    db.raw.execute(
      'UPDATE client_counts SET updated_at = ? WHERE staff_id = ?;',
      ['2026-09-29T11:30:00.000', staffId('Ian')],
    );

    final r = ReportRepository(db)
        .report(DateTime(2026, 9, 28), DateTime(2026, 10, 2));
    expect(r.cellFor(staffId('Joy'), days[0].id)!.total, 3);
    expect(r.cellFor(staffId('Joy'), days[2].id)!.off, isTrue);
    expect(r.cellFor(staffId('Ian'), days[1].id)!.existingClients, 4);
    // Only staff-days with clients appear, newest change first.
    expect(r.activity.map((a) => a.staffName), ['Ian', 'Joy']);
  });

  testWidgets(
    'Quick view shows today: who saw clients, who has not, who is off',
    (tester) async {
      final day = quickDay();
      saveOn(day, 'Joy', 3, 2);
      saveOn(day, 'Dennis', 0, 1);
      final weeks = WeekRepository(db);
      final dayId = weeks
          .getDays(weeks.findByDate(day)!.id)
          .firstWhere((d) => d.date.day == day.day)
          .id;
      TimeOffRepository(db)
          .setDay(dayId: dayId, staffId: staffId('Ian'), off: true);

      await pumpApp(tester);

      expect(find.text('Quick view'), findsOneWidget);
      expect(find.text('6'), findsWidgets); // today's total
      expect(find.text('2 of 13 working'), findsOneWidget);
      expect(find.text('No clients yet'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Ian'), findsOneWidget); // listed under Off
      expect(find.text('Latest updates'), findsOneWidget);
      expect(find.textContaining('3 new · 2 existing'), findsWidgets);
    },
  );

  testWidgets('Details: week chart, staff-by-day grid, and admin edit link', (
    tester,
  ) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    final monday = WeekRepository(db).getDays(week.id).first;
    ClientCountRepository(db).saveCount(
      dayId: monday.id,
      staffId: staffId('Joy'),
      newClients: 4,
      existingClients: 3,
    );
    await pumpApp(tester, admin: true);

    await tester.tap(find.text('Reports').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.text('Clients by staff'), findsOneWidget);
    expect(find.text('Clients by day'), findsOneWidget);
    expect(find.text('Staff by day'), findsOneWidget);
    expect(find.text('Day by day'), findsOneWidget);
    expect(find.text('1 of 14 saw clients'), findsOneWidget);
    expect(find.text('Avg / day'), findsOneWidget);

    // The grid can switch to New only: Joy's Monday shows 4.
    await tester.tap(find.text('New').last);
    await tester.pumpAndSettle();
    expect(find.text('4'), findsWidgets);

    await tester.tap(find.text('Edit in tracker'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^Week \d+ · ')), findsOneWidget);
  });

  testWidgets('Reports renders at phone width', (tester) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.text('Latest updates'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Staff by day'), findsOneWidget);
  });

  testWidgets('Details month view scrolls sideways without overflow', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Staff by day'), findsOneWidget);
  });
}

class _AsRole extends AdminSessionNotifier {
  _AsRole(this.role);
  final UserRole role;

  @override
  UserRole? build() => role;
}
