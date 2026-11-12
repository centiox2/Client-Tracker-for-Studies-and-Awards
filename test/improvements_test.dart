import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/notes_settings_repository.dart';
import 'package:client_tracker/repositories/report_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/report_export.dart';
import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

/// The batch of fixes and features: staff joining open weeks, browsing that
/// doesn't create weeks, shortcuts while typing, +1, saved indicator, open
/// on today, copying time off, notes, targets, report files and backups.
void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryDatabase();
  });
  tearDown(() => db.close());

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    bool admin = true,
  }) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        adminSessionProvider.overrideWith(
          admin ? SignedInSession.new : DirectorSession.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  int staffId(String name) =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [name]).first['id']!
          as int;

  Set<int> staffOnWeek(int weekId) => {
    for (final d in ClientCountRepository(db).weekDaysWithCounts(weekId))
      for (final r in d.rows) r.staffId,
  };

  // ---------------------------------------------------------------- fixes ---

  test('staff added mid-week join this week, and holidays stay holidays', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime.now());
    final days = weeks.getDays(week.id);
    // Make Monday a holiday for everyone currently on the team.
    final timeOff = TimeOffRepository(db);
    for (final s in StaffRepository(db).getActive()) {
      timeOff.setDay(dayId: days.first.id, staffId: s.id, off: true);
    }

    final newId = StaffRepository(db).add('Faith');
    expect(staffOnWeek(week.id), contains(newId));
    expect(timeOff.offStaffIds(days.first.id), contains(newId));
    expect(timeOff.offStaffIds(days[1].id), isNot(contains(newId)));
  });

  test('reactivated staff rejoin this week; past weeks are left alone', () {
    final weeks = WeekRepository(db);
    final past = weeks.createWeekFor(
      DateTime.now().subtract(const Duration(days: 21)),
    );
    final repo = StaffRepository(db);
    final joy = staffId('Joy');
    repo.setActive(joy, false);
    final current = weeks.createWeekFor(DateTime.now());
    expect(staffOnWeek(current.id), isNot(contains(joy)));

    repo.setActive(joy, true);
    expect(staffOnWeek(current.id), contains(joy));
    // Joy was already on the past week (created while active); nothing new
    // is added there.
    expect(staffOnWeek(past.id).length, 14);
  });

  testWidgets('week arrows only move between existing weeks', (tester) async {
    final weeks = WeekRepository(db);
    final now = DateTime.now();
    weeks.createWeekFor(now.subtract(const Duration(days: 14)));
    weeks.createWeekFor(now);
    await pumpApp(tester);
    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();

    // Back skips the missing week in between, creating nothing.
    await tester.tap(find.byTooltip('Previous week'));
    await tester.pumpAndSettle();
    expect(weeks.getAllWeeks(), hasLength(2));
    expect(find.byTooltip('No earlier weeks'), findsOneWidget);

    // Forward from the newest week offers to start one instead.
    await tester.tap(find.byTooltip('Next week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start next week…'));
    await tester.pumpAndSettle();
    expect(find.text('Create week'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(weeks.getAllWeeks(), hasLength(2));
  });

  testWidgets('Ctrl+1–6 don’t switch pages while typing a name', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Name');
    await tester.tap(name);
    await tester.enterText(name, 'Faith');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);
  });

  // ------------------------------------------------------------- tracker ---

  testWidgets('+1 adds a client and the Saved time appears', (tester) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved ·'), findsNothing);

    // Hover a cell to reveal its "+", then tap it twice.
    final cell = find.byType(TextField).at(0);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(cell));
    addTearDown(gesture.removePointer);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add one').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add one').first);
    await tester.pumpAndSettle();

    final monday = WeekRepository(db).getDays(week.id).first;
    final first = StaffRepository(db).getAll().first;
    expect(
      ClientCountRepository(db).countValues(monday.id, first.id).newClients,
      2,
    );
    expect(find.textContaining('Saved ·'), findsOneWidget);
  });

  testWidgets('the tracker opens with today’s first cell ready to type', (
    tester,
  ) async {
    final now = DateTime.now();
    if (now.weekday > DateTime.friday) return; // no "today" column at weekends
    WeekRepository(db).createWeekFor(now);
    await pumpApp(tester);
    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
      reason: 'a number cell has the cursor',
    );
  });

  test('copy last week’s time off repeats the same weekdays', () {
    final weeks = WeekRepository(db);
    final last = weeks.createWeekFor(
      DateTime.now().subtract(const Duration(days: 7)),
    );
    final current = weeks.createWeekFor(DateTime.now());
    final lastFriday = weeks.getDays(last.id).last;
    TimeOffRepository(db)
        .setDay(dayId: lastFriday.id, staffId: staffId('Ian'), off: true);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final marked = container
        .read(appActionsProvider)
        .copyPreviousWeekTimeOff(current.id);
    expect(marked, 1);
    final thisFriday = weeks.getDays(current.id).last;
    expect(
      TimeOffRepository(db).offStaffIds(thisFriday.id),
      contains(staffId('Ian')),
    );
    // Running it again adds nothing new.
    expect(
      container.read(appActionsProvider).copyPreviousWeekTimeOff(current.id),
      0,
    );
  });

  // ------------------------------------------------- notes, target, files ---

  test('notes and the daily target are stored, reported and backed up', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final monday = weeks.getDays(week.id).first;
    DayNotesRepository(db).setNote(monday.id, '  System down 2–4pm  ');
    AppSettingsRepository(db).dailyTarget = 40;

    final report = ReportRepository(db)
        .report(DateTime(2026, 9, 28), DateTime(2026, 10, 2));
    expect(report.days.first.note, 'System down 2–4pm');
    expect(report.days[1].note, isNull);

    // Round-trip through a backup into a fresh database.
    final json = db.exportToJson();
    final other = openInMemoryDatabase();
    addTearDown(other.close);
    other.restoreFromJson(json);
    final restoredDay = WeekRepository(other).getAllWeeks().first;
    final restoredMonday = WeekRepository(other).getDays(restoredDay.id).first;
    expect(
      DayNotesRepository(other).noteFor(restoredMonday.id),
      'System down 2–4pm',
    );
    expect(AppSettingsRepository(other).dailyTarget, 40);

    // Blank text removes the note; 0 clears the target.
    DayNotesRepository(db).setNote(monday.id, '   ');
    AppSettingsRepository(db).dailyTarget = 0;
    expect(DayNotesRepository(db).noteFor(monday.id), isNull);
    expect(AppSettingsRepository(db).dailyTarget, isNull);
  });

  test('restoring an older backup keeps the current settings', () {
    AppSettingsRepository(db).dailyTarget = 25;
    final doc = jsonDecode(db.exportToJson()) as Map<String, Object?>;
    (doc['tables']! as Map).remove('app_settings');
    db.restoreFromJson(jsonEncode(doc));
    expect(AppSettingsRepository(db).dailyTarget, 25);
  });

  test('report files: Excel workbook and printable page', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final day = weeks.getDays(week.id).first;
    ClientCountRepository(db).saveCount(
      dayId: day.id,
      staffId: staffId('Joy'),
      newClients: 3,
      existingClients: 2,
    );
    DayNotesRepository(db).setNote(day.id, 'Outreach <day> & more');
    final report = ReportRepository(db)
        .report(DateTime(2026, 9, 28), DateTime(2026, 10, 2));

    final xlsx = reportToExcel(report, title: 'Week of 28 Sep', target: 40);
    expect(xlsx.length, greaterThan(1000));
    // An .xlsx is a zip archive.
    expect(String.fromCharCodes(xlsx.take(2)), 'PK');

    final html = utf8.decode(
      reportToPrintableHtml(report, title: 'Week of 28 Sep', target: 40),
    );
    expect(html, contains('Week of 28 Sep'));
    expect(html, contains('Joy'));
    expect(html, contains('window.print()'));
    // Notes are escaped, never injected as HTML.
    expect(html, contains('Outreach &lt;day&gt; &amp; more'));
    expect(html, isNot(contains('<day>')));
  });

  testWidgets('Quick view shows progress toward the daily target', (
    tester,
  ) async {
    AppSettingsRepository(db).dailyTarget = 40;
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, admin: false);
    expect(find.text('Target 40'), findsOneWidget);
  });

  testWidgets('Settings: set the daily target', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-cat-workspace')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Clients per day'),
      '35',
    );
    // The Save beside the field (Settings has another for the currency).
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(
              of: find.widgetWithText(TextField, 'Clients per day'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.widgetWithText(OutlinedButton, 'Save'),
      ),
    );
    await tester.pumpAndSettle();
    expect(AppSettingsRepository(db).dailyTarget, 35);
  });

  // ------------------------------------------------------------- backups ---

  testWidgets('backup reminder shows until a backup is saved', (tester) async {
    final container = await pumpApp(tester);
    expect(find.byKey(const ValueKey('backup-notice')), findsOneWidget);
    expect(find.text('No backup yet'), findsOneWidget);

    container.read(lastBackupProvider.notifier).markNow();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup-notice')), findsNothing);
  });

  testWidgets('a recent backup means no reminder', (tester) async {
    SharedPreferences.setMockInitialValues({
      'last_backup_at': DateTime.now()
          .subtract(const Duration(days: 2))
          .toIso8601String(),
    });
    await pumpApp(tester);
    expect(find.textContaining('backup'), findsNothing);
  });

  testWidgets('History and Settings scroll bars work on desktop', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    for (final page in ['History', 'Settings']) {
      await tester.tap(find.text(page).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: page);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
