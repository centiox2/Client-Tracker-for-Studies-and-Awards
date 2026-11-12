import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/report_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/app_info.dart';
import 'package:client_tracker/services/print_views.dart';
import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

/// Version, undo after deleting, printable PDFs, keyboard shortcuts,
/// guided empty states and the Revenue month bar.
void main() {
  late AppDatabase db;

  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  int staffId(String name) =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [name]).first['id']!
          as int;

  int count(String table) =>
      db.raw.select('SELECT COUNT(*) AS c FROM $table;').first['c']! as int;

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
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

  test('the version shown in the app is the one being built', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*([0-9.]+)',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(AppInfo.version, version);
    expect(
      AppInfo.releases.first.version,
      AppInfo.version,
      reason: 'What’s new lists this version first',
    );
  });

  test('a deleted week comes back whole after Undo', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final days = weeks.getDays(week.id);
    ClientCountRepository(db).saveCount(
      dayId: days[1].id,
      staffId: staffId('Joy'),
      newClients: 4,
      existingClients: 2,
    );
    TimeOffRepository(db)
        .setDay(dayId: days[2].id, staffId: staffId('Ian'), off: true);
    final before = [
      for (final t in [
        'weeks',
        'work_days',
        'client_counts',
        'staff_day_off',
        'count_changes',
      ])
        count(t),
    ];

    final removed = weeks.deleteWeek(week.id);
    expect(count('weeks'), 0);
    expect(count('client_counts'), 0);

    removed.restore(db);
    expect([
      for (final t in [
        'weeks',
        'work_days',
        'client_counts',
        'staff_day_off',
        'count_changes',
      ])
        count(t),
    ], before);
    expect(ClientCountRepository(db).weekTotals(week.id).total, 6);
  });

  test('a deleted staff member comes back with their numbers after Undo', () {
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final day = weeks.getDays(week.id).first;
    final joy = staffId('Joy');
    ClientCountRepository(
      db,
    ).saveCount(dayId: day.id, staffId: joy, newClients: 7, existingClients: 1);
    final removed = StaffRepository(db).delete(joy);
    expect(StaffRepository(db).getAll().any((s) => s.id == joy), isFalse);

    removed.restore(db);
    expect(
      StaffRepository(db).getAll().any((s) => s.id == joy && s.name == 'Joy'),
      isTrue,
    );
    expect(ClientCountRepository(db).weekTotals(week.id).total, 8);
  });

  test('printable week, report and application PDFs are made', () async {
    final regular = ByteData.sublistView(
      File('assets/fonts/Inter-400.ttf').readAsBytesSync(),
    );
    final bold = ByteData.sublistView(
      File('assets/fonts/Inter-700.ttf').readAsBytesSync(),
    );
    final weeks = WeekRepository(db);
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    ClientCountRepository(db).saveCount(
      dayId: weeks.getDays(week.id).first.id,
      staffId: staffId('Joy'),
      newClients: 3,
      existingClients: 2,
    );
    final report = ReportRepository(db).report(week.startDate, week.endDate);
    bool isPdf(Uint8List b) => String.fromCharCodes(b.take(5)) == '%PDF-';

    expect(
      isPdf(await weekToPdf(report, regular: regular, bold: bold)),
      isTrue,
    );
    expect(
      isPdf(
        await reportToPdf(
          report,
          title: 'September 2026',
          regular: regular,
          bold: bold,
        ),
      ),
      isTrue,
    );
    expect(
      isPdf(
        await applicationToPdf(
          Application(
            id: 1,
            key: 'a',
            student: 'Jane Doe',
            status: 'Offer pending',
            appDate: DateTime(2026, 9, 1),
          ),
          const [],
          regular: regular,
          bold: bold,
        ),
      ),
      isTrue,
    );
  });

  testWidgets('deleting a week offers Undo, which brings it back', (
    tester,
  ) async {
    final week = WeekRepository(db).createWeekFor(DateTime(2026, 9, 28));
    await pumpApp(tester);
    ProviderScope.containerOf(tester.element(find.byType(ClientTrackerApp)))
        .read(navTabProvider.notifier)
        .set(AppTab.history);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete week').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(WeekRepository(db).getWeek(week.id), isNull);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(WeekRepository(db).getWeek(week.id), isNotNull);
  });

  testWidgets('"/" opens quick search, "?" the shortcuts, and N on Revenue '
      'puts the cursor in the amount', (tester) async {
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(find.textContaining('staff, weeks (28/09)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientTrackerApp)),
    );
    container.read(navTabProvider.notifier).set(AppTab.revenue);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    final amount = find.descendant(
      of: find.byKey(const ValueKey('revenue-amount')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(amount).focusNode.hasFocus, isTrue);

    // Typing "n" in the box is just typing, not another shortcut.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(find.textContaining('staff, weeks (28/09)'), findsNothing);
  });

  testWidgets('empty Revenue day guides to yesterday; month arrows sit by the '
      'name', (tester) async {
    await pumpApp(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientTrackerApp)),
    );
    container.read(navTabProvider.notifier).set(AppTab.revenue);
    await tester.pumpAndSettle();

    expect(find.text('No payments yet today'), findsOneWidget);
    await tester.tap(find.text('See yesterday’s payments'));
    await tester.pumpAndSettle();
    final today = DateTime.now();
    expect(
      container.read(revenueDateProvider),
      DateTime(today.year, today.month, today.day - 1),
    );
    expect(find.text('Back to today'), findsOneWidget);

    await tester.tap(find.text('All transactions'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('all-revenue-empty')), findsOneWidget);
    final prev = tester.getRect(find.byKey(const ValueKey('all-revenue-prev')));
    final month = tester.getRect(
      find.byKey(const ValueKey('all-revenue-month')),
    );
    final next = tester.getRect(find.byKey(const ValueKey('all-revenue-next')));
    expect(month.left - prev.right, lessThan(16));
    expect(next.left - month.right, lessThan(16));
  });

  testWidgets('summary cards can be dragged into a new order, kept and reset', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    Offset at(String label) => tester.getCenter(find.text(label).first);
    expect(at('New clients').dx, lessThan(at('Total clients').dx));

    // Tests run as Android: press and hold, then drag.
    final gesture = await tester.startGesture(at('New clients'));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(at('Total clients'));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(at('New clients').dx, greaterThan(at('Total clients').dx));
    final saved = db.raw.select(
      "SELECT v FROM sync_state WHERE k = 'ui.cards.overview';",
    );
    expect(saved, isNotEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientTrackerApp)),
    );
    container.read(uiPrefProvider).clearPrefix('cards.');
    container.read(cardOrderVersionProvider.notifier).bump();
    await tester.pumpAndSettle();
    expect(at('New clients').dx, lessThan(at('Total clients').dx));
  });

  testWidgets('phone bottom bar: Applications where Daily reports was', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          adminSessionProvider.overrideWith(SignedInSession.new),
          accountsEnabledProvider.overrideWithValue(true),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    final bar = find.byType(NavigationBar);
    List<String> labels() => [
      for (final d in tester.widgetList<NavigationDestination>(
        find.descendant(of: bar, matching: find.byType(NavigationDestination)),
      ))
        d.label,
    ];
    expect(labels(), ['Home', 'Apps', 'Tracker', 'Reports', 'More']);

    await tester.tap(find.byTooltip('More pages'));
    await tester.pumpAndSettle();
    expect(find.text('Daily reports'), findsOneWidget);
  });

  testWidgets('on a Windows PC a card drags straight away with the mouse', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);
    Offset at(String label) => tester.getCenter(find.text(label).first);
    final gesture = await tester.startGesture(
      at('Existing clients'),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(at('Active staff'));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(at('Existing clients').dy, at('Active staff').dy);
    expect(at('Existing clients').dx, greaterThan(at('Active staff').dx));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final size in const [Size(390, 844), Size(820, 1180)]) {
    testWidgets('Reports › Details: switching period never moves the bar '
        '(${size.width.toInt()} wide)', (tester) async {
      WeekRepository(db).createWeekFor(DateTime.now());
      await pumpApp(tester, size: size);
      ProviderScope.containerOf(tester.element(find.byType(ClientTrackerApp)))
          .read(navTabProvider.notifier)
          .set(AppTab.reports);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();

      final tops = <String, double>{};
      for (final p in ['Day', 'Week', 'Month', 'Year', 'Week']) {
        await tester.tap(find.text(p).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final y = tester.getTopLeft(find.text('Download')).dy;
        tops[p] = y;
        expect(y, tops.values.first, reason: '$p moved the Download button');
      }
    });
  }
}
