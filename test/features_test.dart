import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/design/app_theme.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/report_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/screens/reports/reports_screen.dart';
import 'package:client_tracker/services/auto_backup.dart';
import 'package:client_tracker/services/excel_import.dart';
import 'package:client_tracker/services/export_service.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/widgets/numeric_field.dart';

import 'test_helpers.dart';

/// Future-day guard, daily summary, comparisons, staff profiles, Trends,
/// year reports, change history, automatic backups, Excel import, TV mode
/// and the brand colours.
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
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
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

  // ------------------------------------------------------- change history ---

  group('change history', () {
    test('records each change with before and after', () {
      final week = WeekRepository(db).createWeekFor(DateTime.now());
      final day = WeekRepository(db).getDays(week.id).first;
      final counts = ClientCountRepository(db);
      counts.saveCount(
        dayId: day.id,
        staffId: staffId('Joy'),
        newClients: 3,
        existingClients: 1,
      );
      final changes = counts.changes();
      expect(changes, hasLength(1));
      expect(changes.first.staffName, 'Joy');
      expect(changes.first.oldNew, 0);
      expect(changes.first.newNew, 3);
      expect(changes.first.newExisting, 1);
    });

    test('quick re-edits of one cell merge, and undoing one removes it', () {
      final week = WeekRepository(db).createWeekFor(DateTime.now());
      final day = WeekRepository(db).getDays(week.id).first;
      final counts = ClientCountRepository(db);
      final joy = staffId('Joy');
      // Typing "12" saves 1 then 12.
      for (final v in [1, 12]) {
        counts.saveCount(
          dayId: day.id,
          staffId: joy,
          newClients: v,
          existingClients: 0,
        );
      }
      expect(counts.changes(), hasLength(1));
      expect(counts.changes().first.newNew, 12);
      expect(counts.changes().first.oldNew, 0);
      // Back to where it started: no change after all.
      counts.saveCount(
        dayId: day.id,
        staffId: joy,
        newClients: 0,
        existingClients: 0,
      );
      expect(counts.changes(), isEmpty);
    });

    test('imports aren’t logged; history follows the week and backups', () {
      final weeks = WeekRepository(db);
      final a = weeks.createWeekFor(DateTime.now());
      final b = weeks.createWeekFor(
        DateTime.now().subtract(const Duration(days: 7)),
      );
      final counts = ClientCountRepository(db);
      counts.saveCount(
        dayId: weeks.getDays(a.id).first.id,
        staffId: staffId('Joy'),
        newClients: 2,
        existingClients: 0,
      );
      counts.saveCount(
        dayId: weeks.getDays(b.id).first.id,
        staffId: staffId('Ian'),
        newClients: 1,
        existingClients: 0,
      );
      counts.saveCount(
        dayId: weeks.getDays(b.id)[1].id,
        staffId: staffId('Ian'),
        newClients: 5,
        existingClients: 0,
        log: false,
      );
      expect(counts.changes(), hasLength(2));
      expect(counts.changes(weekId: a.id).single.staffName, 'Joy');

      final json = db.exportToJson();
      final copy = openInMemoryDatabase();
      addTearDown(copy.close);
      copy.restoreFromJson(json);
      expect(ClientCountRepository(copy).changes(), hasLength(2));

      StaffRepository(db).delete(staffId('Ian'));
      expect(counts.changes(), hasLength(1));
    });

    testWidgets('the tracker’s week menu opens this week’s changes', (
      tester,
    ) async {
      final week = WeekRepository(db).createWeekFor(DateTime.now());
      ClientCountRepository(db).saveCount(
        dayId: WeekRepository(db).getDays(week.id).first.id,
        staffId: staffId('Collins'),
        newClients: 4,
        existingClients: 2,
      );
      await pumpApp(tester);
      await tester.tap(find.text('Weekly tracker').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change history for this week'));
      await tester.pumpAndSettle();
      expect(find.text('Changes this week'), findsOneWidget);
      expect(find.text('Collins'), findsWidgets);
      expect(find.textContaining('0 to 4', findRichText: true), findsOneWidget);
    });
  });

  // ------------------------------------------------------ future-day guard ---

  testWidgets('future days ask before the first number goes in', (
    tester,
  ) async {
    final next = WeekRepository(db)
        .createWeekFor(DateTime.now().add(const Duration(days: 7)));
    final container = await pumpApp(tester);
    container.read(appActionsProvider).selectTab(AppTab.week, weekId: next.id);
    await tester.pumpAndSettle();

    final firstCell = find.byType(NumericField).first;
    await tester.tap(firstCell);
    await tester.pumpAndSettle();
    expect(find.textContaining('hasn’t happened yet'), findsOneWidget);

    // Cancel: still locked, nothing saved.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(unlockedDaysProvider), isEmpty);

    // Confirm: unlocked for the session, and typing saves.
    await tester.tap(firstCell);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Enter for'));
    await tester.pumpAndSettle();
    expect(container.read(unlockedDaysProvider), hasLength(1));
    await tester.enterText(firstCell, '3');
    await tester.pumpAndSettle();
    final monday = WeekRepository(db).getDays(next.id).first;
    final saved = ClientCountRepository(db).getDayWithCounts(monday.id);
    expect(saved.rows.first.newClients, 3);
  });

  // -------------------------------------------------------------- reports ---

  group('report groupings', () {
    test('months, weekday averages and a staff profile', () {
      final weeks = WeekRepository(db);
      final counts = ClientCountRepository(db);
      final joy = staffId('Joy');
      // Two past weeks: Joy sees 2 on Mondays and 6 on Tuesdays.
      for (final back in [14, 21]) {
        final w = weeks.createWeekFor(
          DateTime.now().subtract(Duration(days: back)),
        );
        final days = weeks.getDays(w.id);
        counts.saveCount(
          dayId: days[0].id,
          staffId: joy,
          newClients: 2,
          existingClients: 0,
        );
        counts.saveCount(
          dayId: days[1].id,
          staffId: joy,
          newClients: 4,
          existingClients: 2,
        );
      }
      final all = weeks.getAllWeeks();
      final r = ReportRepository(db)
          .report(all.last.startDate, all.first.endDate);
      expect(r.months.fold<int>(0, (a, m) => a + m.total), 16);
      final byDay = {for (final w in r.weekdayAverages) w.weekday: w};
      expect(byDay[DateTime.monday]!.average, 2);
      expect(byDay[DateTime.tuesday]!.average, 6);

      final p = r.profileFor(joy)!;
      expect(p.staff.total, 16);
      expect(p.bestDay!.total, 6);
      expect(p.weeks, hasLength(2));
      expect(p.weekdays.firstWhere((w) => w.weekday == 2).average, 6);
      expect(r.profileFor(staffId('Ian'))!.staff.total, 0);
    });
  });

  test('the daily summary reads like a message', () {
    final weeks = WeekRepository(db);
    final w = weeks.createWeekFor(DateTime(2026, 10, 12));
    final days = weeks.getDays(w.id);
    final counts = ClientCountRepository(db);
    counts.saveCount(
      dayId: days[3].id,
      staffId: staffId('Beatrice'),
      newClients: 1,
      existingClients: 3,
    );
    TimeOffRepository(db)
        .setDay(dayId: days[3].id, staffId: staffId('Joy'), off: true);
    final reports = ReportRepository(db);
    final thu = DateTime(2026, 10, 15);
    final text = buildDailySummary(
      day: thu,
      today: reports.report(thu, thu),
      sameDayLastWeek: null,
      weekSoFar: reports.report(DateTime(2026, 10, 12), thu),
      monthSoFar: reports.report(DateTime(2026, 10, 1), thu),
      target: 10,
    );
    expect(text, contains('Studies and Awards Limited'));
    expect(text, contains('Thursday 15 October 2026'));
    expect(
      text,
      contains('Thursday: 4 clients (1 new, 3 existing) – target 10'),
    );
    expect(text, contains('• Beatrice: 4 (1 new, 3 existing)'));
    expect(text, contains('Off: Joy'));
    expect(text, contains('This week so far: 4 clients'));
  });

  testWidgets('Reports: Year, Trends, per-staff change and last-year mode', (
    tester,
  ) async {
    final weeks = WeekRepository(db);
    final counts = ClientCountRepository(db);
    for (final back in [0, 7]) {
      final w = weeks.createWeekFor(
        DateTime.now().subtract(Duration(days: back)),
      );
      counts.saveCount(
        dayId: weeks.getDays(w.id).first.id,
        staffId: staffId('Joy'),
        newClients: back == 0 ? 5 : 2,
        existingClients: 0,
      );
    }
    await pumpApp(tester, admin: false);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    // Per-staff change vs last week.
    expect(find.text('Change'), findsOneWidget);

    // Compare with the same week last year instead.
    await tester.tap(find.text('vs previous week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare with the same week last year'));
    await tester.pumpAndSettle();
    expect(find.text('vs last year'), findsOneWidget);

    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('Clients by month'), findsOneWidget);
    expect(find.text('Month by month'), findsOneWidget);
    expect(find.text('Staff by day'), findsNothing);

    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    expect(find.text('Busiest days of the week'), findsOneWidget);
    expect(find.text('Staff: last 4 weeks vs the 4 before'), findsOneWidget);
    expect(find.text('Busiest weekday'), findsOneWidget);
  });

  testWidgets('staff profile opens from the boss’s Staff page', (tester) async {
    final w = WeekRepository(db).createWeekFor(DateTime.now());
    ClientCountRepository(db).saveCount(
      dayId: WeekRepository(db).getDays(w.id).first.id,
      staffId: staffId('Talaam'),
      newClients: 3,
      existingClients: 4,
    );
    await pumpApp(tester, admin: false);
    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talaam'));
    await tester.pumpAndSettle();
    expect(find.text('Clients, all time'), findsOneWidget);
    expect(find.text('Average by weekday'), findsOneWidget);
    expect(find.text('7'), findsWidgets);
  });

  testWidgets('summary copies and TV mode opens and closes', (tester) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpApp(tester, admin: false);
    await tester.tap(find.text('Share summary'));
    await tester.pumpAndSettle();
    expect(find.text('Daily summary'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('Summary copied — paste it anywhere'), findsOneWidget);
    expect(copied, contains('client update'));

    await tester.tap(find.text('TV mode'));
    await tester.pumpAndSettle();
    expect(find.text('Who’s seeing clients'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Who’s seeing clients'), findsNothing);
    expect(find.text('Quick view'), findsOneWidget);
  });

  // --------------------------------------------------------- excel import ---

  group('Excel import', () {
    test('a week exported by the app imports back the same numbers', () {
      final weeks = WeekRepository(db);
      final w = weeks.createWeekFor(DateTime(2026, 9, 7));
      final days = weeks.getDays(w.id);
      final counts = ClientCountRepository(db);
      counts.saveCount(
        dayId: days[0].id,
        staffId: staffId('Joy'),
        newClients: 4,
        existingClients: 2,
      );
      counts.saveCount(
        dayId: days[2].id,
        staffId: staffId('Director/Eve'),
        newClients: 1,
        existingClients: 7,
      );
      TimeOffRepository(db)
          .setDay(dayId: days[4].id, staffId: staffId('Ian'), off: true);
      final bytes = ExportService(counts.getWeekWithDays).exportWeek(w).bytes;

      final data = parseExcelImport(bytes);
      expect(data.days, hasLength(5));
      expect(data.total, 14);
      expect(data.warnings, isEmpty);

      // Into a fresh database.
      final fresh = openInMemoryDatabase();
      addTearDown(fresh.close);
      final staff = StaffRepository(fresh).getAll();
      final targets = {for (final n in data.names) n: suggestTarget(n, staff)};
      expect(targets.values.whereType<AddFormerStaff>(), isEmpty);
      final out = applyExcelImport(fresh, data, targets, overwrite: false);
      expect(out.weeksCreated, 1);
      expect(out.clients, 14);
      final r = ReportRepository(fresh)
          .report(DateTime(2026, 9, 7), DateTime(2026, 9, 11));
      expect(r.total, 14);
      final ian = StaffRepository(fresh)
          .getAll()
          .firstWhere((s) => s.name == 'Ian');
      expect(r.staff.firstWhere((s) => s.staffId == ian.id).daysOff, 1);
      // Nothing logged as edits.
      expect(ClientCountRepository(fresh).changes(), isEmpty);
    });

    test('existing numbers are kept unless replacing is chosen', () {
      final weeks = WeekRepository(db);
      final w = weeks.createWeekFor(DateTime(2026, 9, 7));
      final day = weeks.getDays(w.id).first;
      final counts = ClientCountRepository(db);
      counts.saveCount(
        dayId: day.id,
        staffId: staffId('Joy'),
        newClients: 9,
        existingClients: 0,
      );
      final data = ExcelImport(
        days: [
          ImportDay(DateTime(2026, 9, 7))
            ..entries['Joy'] = const ImportEntry(
              newClients: 1,
              existingClients: 1,
            ),
        ],
        warnings: const [],
      );
      final targets = {'Joy': MatchStaff(staffId('Joy'))};
      final kept = applyExcelImport(db, data, targets, overwrite: false);
      expect(kept.kept, 1);
      expect(counts.countValues(day.id, staffId('Joy')).newClients, 9);
      applyExcelImport(db, data, targets, overwrite: true);
      expect(counts.countValues(day.id, staffId('Joy')).newClients, 1);
    });

    test('names: close matches, and unknown people become former staff', () {
      final staff = StaffRepository(db).getAll();
      expect(
        suggestTarget('eve', staff),
        isA<MatchStaff>().having(
          (t) => t.staffId,
          'id',
          staffId('Director/Eve'),
        ),
      );
      expect(
        suggestTarget('  JOY ', staff),
        isA<MatchStaff>().having((t) => t.staffId, 'id', staffId('Joy')),
      );
      expect(suggestTarget('Mercy Atieno', staff), isA<AddFormerStaff>());

      final data = ExcelImport(
        days: [
          ImportDay(DateTime(2026, 9, 8))
            ..entries['Mercy Atieno'] = const ImportEntry(
              newClients: 2,
              existingClients: 0,
            ),
        ],
        warnings: const [],
      );
      final out = applyExcelImport(db, data, {
        'Mercy Atieno': const AddFormerStaff(),
      }, overwrite: false);
      expect(out.staffAdded, 1);
      final mercy = StaffRepository(db)
          .getAll()
          .firstWhere((s) => s.name == 'Mercy Atieno');
      expect(mercy.active, isFalse);
      // Former staff aren't put on this week's board.
      final now = WeekRepository(db).createWeekFor(DateTime.now());
      final board = ClientCountRepository(db).weekDaysWithCounts(now.id);
      expect(board.first.rows.map((r) => r.staffId), isNot(contains(mercy.id)));
    });

    test('a file that isn’t a workbook explains itself', () {
      expect(
        () => parseExcelImport([1, 2, 3, 4]),
        throwsA(isA<ExcelImportException>()),
      );
    });
  });

  // ------------------------------------------------------ automatic backups ---

  test('one automatic backup a day, listed for restore', () async {
    final dir = await Directory.systemTemp.createTemp('ct_auto');
    final fileDb = openPlatformDatabase(dir.path);
    addTearDown(() {
      fileDb.close();
      dir.deleteSync(recursive: true);
    });
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(fileDb)],
    );
    addTearDown(container.dispose);
    final backups = container.read(autoBackupProvider.notifier);
    await backups.ensureToday();
    await backups.ensureToday();
    final state = container.read(autoBackupProvider);
    expect(state.entries, hasLength(1));
    expect(state.location, endsWith('auto_backups'));
    final json = await backups.read(state.entries.first.id);
    expect(json, contains('client-tracker-backup'));
    await backups.backupNow();
    expect(container.read(autoBackupProvider).entries, hasLength(2));
  });

  // -------------------------------------------------------------- brand ---

  test('brand colours drive primary actions', () {
    final light = buildAppTheme(Brightness.light);
    final dark = buildAppTheme(Brightness.dark);
    // The Studies and Awards navy on light; its gold on dark, navy text.
    expect(light.colorScheme.primary, Dt.brandNavy);
    expect(dark.colorScheme.primary, Dt.brandGold);
    expect(dark.colorScheme.onPrimary, Dt.brandNavy);
  });
}
