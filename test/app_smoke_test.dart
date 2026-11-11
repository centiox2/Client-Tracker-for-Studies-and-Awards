import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

import 'package:intl/intl.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = openInMemoryDatabase();
  });

  tearDown(() => db.close());

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1600, 1000),
  }) async {
    // Desktop-sized surface so the shell uses the icon rail and the tracker
    // uses the full-week board.
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

  testWidgets('dashboard shows week stats and staff count on first launch', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('New clients'), findsOneWidget);
    expect(find.text('Total clients'), findsOneWidget);
    expect(find.text('Clients this month'), findsOneWidget);
    expect(find.text('Active staff'), findsOneWidget);
  });

  testWidgets('wide dashboard metrics fit one row without clipping', (
    tester,
  ) async {
    const size = Size(1864, 884);
    await pumpApp(tester, size: size);

    final metricLabels = [
      'New clients',
      'Existing clients',
      'Total clients',
      'Clients this month',
      'Active staff',
    ];
    final labelTops = metricLabels
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList();
    expect(
      labelTops.every((top) => (top - labelTops.first).abs() < 1),
      isTrue,
      reason: 'all five metric cards should use one row at wide widths',
    );
    expect(
      tester.getBottomRight(find.text('Enter today’s numbers')).dy,
      lessThan(size.height - 10),
      reason: 'the main action should remain above the viewport edge',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Refresh reloads data added since the screen was opened', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.textContaining('No week yet'), findsOneWidget);

    // Simulate an external update to the local database, then use the
    // refresh in the account menu to notify providers and refresh.
    WeekRepository(db).createWeekFor(DateTime.now());
    await tester.tap(find.byKey(const ValueKey('account-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh data'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No week yet'), findsNothing);
    expect(find.text('This week'), findsOneWidget);
  });

  testWidgets('New week dialog lists Mon–Fri and creates the week', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('week-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-week-menu')));
    await tester.pumpAndSettle();

    final fmt = DateFormat('EEEE – dd/MM/yyyy');
    final monday = WeekRepository.mondayOf(DateTime.now());
    for (var i = 0; i < 5; i++) {
      expect(
        find.textContaining(fmt.format(monday.add(Duration(days: i)))),
        findsOneWidget,
      );
    }

    await tester.tap(find.text('Create Week'));
    await tester.pumpAndSettle();

    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Enter today’s numbers'), findsOneWidget);
  });

  testWidgets('tracker board: typing a number updates totals instantly', (
    tester,
  ) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);

    // Open the Week tab (icon rail on desktop).
    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();

    // The board lays fields out as [Mon New, Mon Existing, Tue New, …] per
    // staff, staff in display order.
    final joyIndex =
        db.raw.select('SELECT display_order FROM staff WHERE name = ?;', [
              'Joy',
            ]).first['display_order']!
            as int;
    final allFields = find.byType(TextField);
    expect(tester.widgetList(allFields).length, greaterThan(10));

    // The grid's fields are the first on the page (the sidebar search is
    // a button, not a field).
    await tester.enterText(allFields.at(joyIndex * 10), '7');
    await tester.pumpAndSettle();

    // The compact summary line under the stat strip must now show 7 new.
    final summaryTexts = tester.widgetList<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains(' new ·') ?? false),
      ),
    );
    expect(
      summaryTexts.any((t) => t.data!.startsWith('7 new')),
      isTrue,
      reason: 'weekly totals must update instantly',
    );

    // The write reached the database.
    final monday = WeekRepository(db).getDays(week.id).first;
    final joyId =
        db.raw.select('SELECT id FROM staff WHERE name = ?;', [
              'Joy',
            ]).first['id']!
            as int;
    final stored =
        db.raw.select(
              'SELECT new_clients FROM client_counts WHERE day_id = ? AND staff_id = ?;',
              [monday.id, joyId],
            ).first['new_clients']!
            as int;
    expect(stored, 7);
    expect(find.textContaining(RegExp(r'^Week \d+$')), findsOneWidget);
  });

  testWidgets('show zeros toggle refreshes even the focused count field', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);

    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();

    final firstCountField = find.byType(TextField).at(1);
    expect(tester.widget<TextField>(firstCountField).controller!.text, '0');

    // Keep a grid cell focused while switching display preference. On web,
    // tapping the toggle does not always clear the TextField's focus, and the
    // field still needs to redraw its zero as a dash.
    await tester.tap(firstCountField);
    await tester.pump();
    await tester.tap(find.text('Hide zeros'));
    await tester.pumpAndSettle();
    expect(find.text('Show zeros'), findsOneWidget);
    expect(tester.widget<TextField>(firstCountField).controller!.text, '');

    await tester.tap(find.text('Show zeros'));
    await tester.pumpAndSettle();
    expect(find.text('Hide zeros'), findsOneWidget);
    expect(tester.widget<TextField>(firstCountField).controller!.text, '0');
  });

  testWidgets('history lists the week after creation', (tester) async {
    WeekRepository(db).createWeekFor(DateTime(2026, 9, 28));
    await pumpApp(tester);

    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('September 28 – October 2, 2026'),
      findsOneWidget,
    );
  });

  testWidgets('staff screen lists seeded staff', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();

    expect(find.text('Beatrice'), findsOneWidget);
    expect(find.text('14 active · 0 inactive'), findsOneWidget);
    // Scroll to the last row (list is lazy).
    await tester.scrollUntilVisible(
      find.text('Cinthia'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ReorderableListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Cinthia'), findsOneWidget);
  });

  testWidgets('board: tapping a name opens time off and marks the day Off', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester);

    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();

    // Open the time-off editor from the first staff name on the board.
    await tester.tap(find.text('Beatrice'));
    await tester.pumpAndSettle();

    expect(find.text('Time off — Beatrice'), findsOneWidget);

    // Toggle Monday off (first checkbox after the whole-week switch) and save.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The board shows the Off cell and the mark reached the database.
    expect(find.text('Off'), findsWidgets);
    final marks = db.raw.select('SELECT COUNT(*) AS c FROM staff_day_off;');
    expect(marks.first['c'], 1);
  });

  testWidgets('narrow screens keep both tracker fields and staff rows usable', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull, reason: 'mobile shell');

    // The phone's bottom bar uses short labels.
    await tester.tap(find.text('Tracker').last);
    await tester.pumpAndSettle();
    final trackerLayoutError = tester.takeException();
    expect(trackerLayoutError, isNull, reason: '$trackerLayoutError');
    final visibleNewFields = find.text('New').evaluate().length;
    expect(visibleNewFields, greaterThan(0));
    expect(find.text('Exist.'), findsWidgets);
    expect(find.byType(TextField), findsWidgets);

    // Staff is under "More" in the phone's bottom bar.
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Staff').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Beatrice'), findsOneWidget);
  });

  testWidgets('tablet width keeps every primary screen renderable', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, size: const Size(800, 1000));

    // Tablet width still uses the bottom bar: short labels, and the pages
    // that don't fit are under "More".
    for (final screen in [
      'Tracker',
      'Revenue',
      'History',
      'Staff',
      'Settings',
      'Home',
    ]) {
      if (const {'History', 'Staff', 'Settings'}.contains(screen)) {
        await tester.tap(find.byTooltip('More pages'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(screen).last);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '$screen should render without layout exceptions at tablet width',
      );
    }
  });

  testWidgets('fullscreen tracker rail has no overlay scrollbar', (
    tester,
  ) async {
    WeekRepository(db).createWeekFor(DateTime.now());
    await pumpApp(tester, size: const Size(1920, 1080));

    await tester.tap(find.text('Weekly tracker').first);
    await tester.pumpAndSettle();

    expect(find.text('Most clients this week'), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
