import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/design/app_theme.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/widgets/clarity.dart';
import 'package:client_tracker/widgets/panels.dart';
import 'package:client_tracker/widgets/week_label.dart';

import 'test_helpers.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
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

  test('the Clarity tokens, light and dark', () {
    final light = buildAppTheme(Brightness.light);
    final dark = buildAppTheme(Brightness.dark);
    expect(light.scaffoldBackgroundColor, const Color(0xFFF5F6F8));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF0E1116));
    expect(Clarity.of(light).seriesNew, const Color(0xFFE8833A));
    expect(Clarity.of(light).seriesExisting, const Color(0xFF3B5BDB));
    // The brand: navy accent on light, gold on dark.
    expect(Clarity.of(light).accent, Dt.brandNavy);
    expect(Clarity.of(dark).accent, Dt.brandGold);
    // Text styles carry Inter (not Roboto falling back to the system font).
    expect(light.textTheme.bodyMedium!.fontFamily, 'Inter');
    expect(light.textTheme.headlineMedium!.fontSize, 28);
  });

  test('deltas and tidy chart tops', () {
    expect(deltaVsLast(5, 12).$1, '↓ 7 (58%) vs last week');
    expect(deltaVsLast(5, 12).$2, DeltaTone.down);
    expect(deltaVsLast(15, 12).$1, '↑ 3 (25%) vs last week');
    expect(deltaVsLast(4, 0).$1, '↑ 4 vs last week');
    expect(deltaVsLast(3, 3).$1, 'Same as last week');
    expect(StackedDayChart.niceTop(17), 20);
    expect(StackedDayChart.niceTop(0), 20);
    expect(StackedDayChart.niceTop(43), 80);
    expect(StackedDayChart.niceTop(4), 4);
    expect(
      shortRangeLabel(DateTime(2026, 11, 9), DateTime(2026, 11, 13)),
      '9 – 13 Nov 2026',
    );
    expect(
      shortRangeLabel(DateTime(2026, 9, 28), DateTime(2026, 10, 2)),
      '28 Sep – 2 Oct 2026',
    );
  });

  testWidgets('Overview: each day spelled out; empty days show a dash', (
    tester,
  ) async {
    final week = WeekRepository(db).createWeekFor(DateTime.now());
    final monday = WeekRepository(db).getDays(week.id).first;
    final staff = StaffRepository(db).getAll().first;
    ClientCountRepository(db).saveCount(
      dayId: monday.id,
      staffId: staff.id,
      newClients: 2,
      existingClients: 3,
    );
    await pumpApp(tester);

    expect(find.text('Overview'), findsWidgets);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Entered'), findsOneWidget);
    // The other four days have no numbers: "—", never "0".
    expect(find.text('—'), findsNWidgets(4 * 3));
    expect(find.text('Staff performance'), findsOneWidget);
    expect(find.text('Recent weeks'), findsOneWidget);
    expect(find.text('New'), findsWidgets); // legend
    expect(tester.takeException(), isNull);
  });

  testWidgets('the moon button switches light and dark', (tester) async {
    await pumpApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    final after = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(after.themeMode, ThemeMode.dark);
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('Staff: this week at a glance; History: the month total', (
    tester,
  ) async {
    final weeks = WeekRepository(db);
    final now = DateTime.now();
    final week = weeks.createWeekFor(now);
    weeks.createWeekFor(now.subtract(const Duration(days: 7)));
    final monday = weeks.getDays(week.id).first;
    final staff = StaffRepository(db).getAll();
    ClientCountRepository(db).saveCount(
      dayId: monday.id,
      staffId: staff.first.id,
      newClients: 1,
      existingClients: 2,
    );
    await pumpApp(tester);
    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();
    final glance = find.byKey(const ValueKey('week-glance'));
    expect(glance, findsOneWidget);
    expect(
      find.descendant(
        of: glance,
        matching: find.text('${staff.first.name} · 3'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    expect(find.textContaining(' total'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sidebar closes to a strip of icons and opens again', (
    tester,
  ) async {
    await pumpApp(tester);
    double width() =>
        tester.getSize(find.byKey(const ValueKey('sidebar'))).width;
    expect(width(), 248);
    await tester.tap(find.byKey(const ValueKey('sidebar-collapse')));
    await tester.pumpAndSettle();
    expect(width(), 72);
    // Names are gone; icons still open their pages.
    expect(find.text('WORKSPACE'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('strip-staff')));
    await tester.pumpAndSettle();
    expect(find.text('Add staff member'), findsOneWidget);
    // Remembered on this device.
    final saved = db.raw.select(
      "SELECT v FROM sync_state WHERE k = 'sidebar_collapsed';",
    );
    expect(saved.first['v'], '1');
    await tester.tap(find.byKey(const ValueKey('sidebar-expand')));
    await tester.pumpAndSettle();
    expect(width(), 248);
    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
