import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

import 'package:client_tracker/widgets/panels.dart';

import 'package:client_tracker/widgets/week_label.dart';

/// Quick search, week picker, start-week banner and "vs last week" deltas.
void main() {
  late AppDatabase db;

  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          adminSessionProvider.overrideWith(SignedInSession.new),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  int joyId() =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [
            'Joy',
          ]).first['id']!
          as int;

  void saveMonday(int weekId, {required int newClients}) {
    final monday = WeekRepository(db).getDays(weekId).first;
    ClientCountRepository(db).saveCount(
      dayId: monday.id,
      staffId: joyId(),
      newClients: newClients,
      existingClients: 0,
    );
  }

  test('daily application activity survives busy sync days and midnight', () {
    final repo = ApplicationRepository(db);
    final day = DateTime(2026, 11, 19);
    final nextDay = DateTime(2026, 11, 20);
    for (var id = 1; id <= 55; id++) {
      db.raw.execute(
        'INSERT INTO application_imports(id, imported_at) VALUES (?, ?)',
        [id, day.add(Duration(minutes: id)).toIso8601String()],
      );
    }
    final times = [
      day.subtract(const Duration(seconds: 1)),
      day,
      nextDay.subtract(const Duration(seconds: 1)).toUtc(),
      nextDay.toUtc(),
    ];
    for (final (id, time) in times.indexed) {
      db.raw.execute(
        "INSERT INTO application_changes(id, import_id, app_key, student, field, changed_at) "
        "VALUES (?, 1, 'client', 'Client', 'status', ?)",
        [id + 1, time.toIso8601String()],
      );
    }
    expect(repo.imports().any((i) => i.id == 1), isFalse);
    expect(repo.changesOn(day).map((c) => c.id), [3, 2]);
  });

  testWidgets('overview opens tracker without silently creating a week', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('overview-open-week')));
    await tester.pumpAndSettle();
    expect(find.text('No week selected'), findsOneWidget);
    expect(WeekRepository(db).getAllWeeks(), isEmpty);
  });

  testWidgets(
    'client chart uses the selected week rather than the previous week',
    (tester) async {
      final weeks = WeekRepository(db);
      final now = DateTime.now();
      final last = weeks.createWeekFor(now.subtract(const Duration(days: 7)));
      final current = weeks.createWeekFor(now);
      saveMonday(last.id, newClients: 2);
      saveMonday(current.id, newClients: 5);
      await pumpApp(tester);
      final card = find.byKey(const ValueKey('overview-week'));
      final chart = tester.widget<StackedDayChart>(
        find.descendant(of: card, matching: find.byType(StackedDayChart)),
      );
      expect(chart.days.first.newClients, 5);
    },
  );

  test('week and month averages divide by working days so far', () {
    final weeks = WeekRepository(db);
    final counts = ClientCountRepository(db);
    final now = DateTime.now();
    final week = weeks.createWeekFor(now);
    saveMonday(week.id, newClients: 12);

    // Mon–Fri days up to and including today (all five at the weekend).
    final elapsed = now.weekday > 5 ? 5 : now.weekday;
    expect(
      counts.weekTotals(week.id).dailyAverage,
      closeTo(12 / elapsed, 0.001),
    );

    // The month counts only this month's tracked days up to today, so a
    // week straddling the 1st can't skew it.
    final monday = weeks.getDays(week.id).first.date;
    if (monday.month == now.month) {
      final monthDays = weeks
          .getDays(week.id)
          .where((d) => d.date.month == now.month && !d.date.isAfter(now))
          .length;
      expect(
        counts.monthTotals(now).dailyAverage,
        closeTo(12 / monthDays, 0.001),
      );
    }
  });

  test('days with every staff member off are skipped in the averages', () {
    final weeks = WeekRepository(db);
    final counts = ClientCountRepository(db);
    final timeOff = TimeOffRepository(db);
    // A fixed past week, so all five days have already happened.
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final days = weeks.getDays(week.id);
    saveMonday(week.id, newClients: 12);

    final staff = StaffRepository(db).getActive();
    // Wednesday: everyone off (a holiday) — must not count.
    for (final s in staff) {
      timeOff.setDay(dayId: days[2].id, staffId: s.id, off: true);
    }
    // Thursday: only one person off — the day still counts.
    timeOff.setDay(dayId: days[3].id, staffId: staff.first.id, off: true);

    expect(counts.weekTotals(week.id).dailyAverage, closeTo(12 / 4, 0.001));
    // September's tracked days in that week are Mon 28–Wed 30; Wed is
    // skipped, leaving 2.
    expect(
      counts.monthTotals(DateTime(2026, 9)).dailyAverage,
      closeTo(12 / 2, 0.001),
    );
  });

  Future<void> openMondayDayOff(WidgetTester tester) async {
    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();
    final monday = WeekRepository.mondayOf(DateTime.now());
    await tester.tap(find.text('Mon ${monday.day}'));
    await tester.pumpAndSettle();
    expect(find.textContaining('off on Monday'), findsOneWidget);
  }

  int offMarks() =>
      db.raw.select('SELECT COUNT(*) AS c FROM staff_day_off;').first['c']!
          as int;

  testWidgets('day header: Holiday marks the whole team off', (tester) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    await openMondayDayOff(tester);

    await tester.tap(find.text('Holiday — whole team off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(offMarks(), StaffRepository(db).getActive().length);
    // Header badge plus a "Holiday" cell for every staff row.
    expect(find.text('Holiday'), findsWidgets);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('day header: mark one staff member off', (tester) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    await openMondayDayOff(tester);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('Joy')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(offMarks(), 1);
    expect(find.text('1 off'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets(
    'client graphs remain alongside revenue, applications and to-do',
    (tester) async {
      final week = WeekRepository(db).createWeekFor(DateTime.now());
      saveMonday(week.id, newClients: 6);
      await pumpApp(tester);
      expect(
        find.byKey(const ValueKey('overview-open-revenue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-open-applications')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('overview-open-todo')), findsOneWidget);
      expect(find.byKey(const ValueKey('client-mix')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-week')),
          matching: find.byType(StackedDayChart),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('overview shows client history, refunds and daily app changes', (
    tester,
  ) async {
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final weeks = WeekRepository(db);
    final lastWeek = weeks.createWeekFor(now.subtract(const Duration(days: 7)));
    saveMonday(lastWeek.id, newClients: 9);
    final revenue = RevenueRepository(db);
    revenue.add(yesterday, 7500, note: 'Payment');
    revenue.add(now, -2500, note: 'Refund');
    final applications = ApplicationRepository(db);
    const header = 'Student name,RTO name,Country,Status\n';
    applications.importCsv(
      '${header}Amina Test,WAIFS,Australia,Statement building',
    );
    applications.importCsv('${header}Amina Test,WAIFS,Australia,Visa lodged');

    await pumpApp(tester);
    Finder inPanel(String id, Finder matching) => find.descendant(
      of: find.byKey(ValueKey('overview-$id')),
      matching: matching,
    );
    final chart = tester.widget<StackedDayChart>(
      inPanel('client-trend', find.byType(StackedDayChart)),
    );
    expect(chart.byWeek, isTrue);
    expect(chart.days.map((day) => day.total), [0, 0, 9, 0]);
    final currency = ProviderScope.containerOf(
      tester.element(find.byType(ClientTrackerApp)),
    ).read(currencyProvider);
    expect(
      inPanel('revenue-trend', find.text(formatMoney(5000, currency))),
      findsOneWidget,
    );
    expect(
      inPanel('revenue-trend', find.text(formatMoney(-2500, currency))),
      findsOneWidget,
    );
    expect(
      inPanel('application-activity', find.text('Amina Test')),
      findsOneWidget,
    );
    expect(
      inPanel(
        'application-activity',
        find.text('Status changed to Visa lodged'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('total clients card shows the selected-week daily average', (
    tester,
  ) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    saveMonday(week.id, newClients: 12);
    await pumpApp(tester);
    expect(find.textContaining(' / day'), findsOneWidget);
  });

  testWidgets('week picker switches the tracker week', (tester) async {
    final weeks = WeekRepository(db);
    final now = DateTime.now();
    final older = weeks.createWeekFor(now.subtract(const Duration(days: 14)));
    weeks.createWeekFor(now.add(const Duration(days: 7)));
    await pumpApp(tester);

    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('week-picker')));
    await tester.pumpAndSettle();
    final label = shortRangeLabel(older.startDate, older.endDate);
    // The menu's entry (the dashboard's week list opens the tracker).
    await tester.tap(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.textContaining(label),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('week-picker')),
        matching: find.textContaining(label),
      ),
      findsOneWidget,
      reason: 'the week button shows the picked week',
    );
  });

  testWidgets('clicking the sidebar search box opens quick search', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('sidebar-search')));
    await tester.pumpAndSettle();
    expect(find.textContaining('staff, weeks (28/09)'), findsOneWidget);
  });

  testWidgets('Ctrl+K opens quick search and Enter jumps to a page', (
    tester,
  ) async {
    // History only shows its search field once a week exists.
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('staff, weeks (28/09)'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'hist');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.textContaining('staff, weeks (28/09)'), findsNothing);
    expect(find.textContaining('Search by month or date'), findsOneWidget);
  });
}
