// Renders the main screens to PNGs with the real fonts, for checking the
// design by eye. Not part of the test suite:
//
//   flutter test tool/screenshots_test.dart --update-goldens
//
// Writes tool/shots/<screen>-<light|dark|phone>.png (git-ignored).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/state/app_state.dart';

import '../test/test_helpers.dart';

Future<void> _loadFonts() async {
  Future<ByteData> f(String path) async =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final inter = FontLoader('Inter');
  for (final w in [400, 500, 600, 700]) {
    inter.addFont(f('assets/fonts/Inter-$w.ttf'));
  }
  await inter.load();
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      f(
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
}

void _seed(AppDatabase db) {
  final weeks = WeekRepository(db);
  final counts = ClientCountRepository(db);
  final staff = StaffRepository(db).getAll().where((s) => s.active).toList();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  // Last week: every day; this week: up to yesterday.
  final last = weeks.createWeekFor(today.subtract(const Duration(days: 7)));
  final cur = weeks.createWeekFor(today);
  var seed = 7;
  int next(int max) => (seed = (seed * 31 + 11) % 97) % (max + 1);
  for (final w in [last, cur]) {
    for (final day in weeks.getDays(w.id)) {
      if (w == cur && !day.date.isBefore(today)) continue;
      for (final s in staff.take(9)) {
        counts.saveCount(
          dayId: day.id,
          staffId: s.id,
          newClients: next(2),
          existingClients: next(3),
          log: false,
        );
      }
    }
  }
  final csv = File('test/fixtures/applications_sample.csv').readAsStringSync();
  ApplicationRepository(db).importCsv(csv);
}

void main() {
  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
  });

  final screens = <String, String>{
    'overview': 'Overview',
    'tracker': 'Weekly tracker',
    'revenue': 'Revenue',
    'applications': 'Applications',
    'history': 'History',
    'staff': 'Staff',
    'reports': 'Reports',
    'settings': 'Settings',
  };

  for (final mode in ['light', 'dark', 'phone']) {
    for (final MapEntry(key: name, value: label) in screens.entries) {
      testWidgets('$name $mode', (tester) async {
        final db = openInMemoryDatabase();
        addTearDown(db.close);
        _seed(db);
        final phone = mode == 'phone';
        tester.view.physicalSize = phone
            ? const Size(390 * 2, 844 * 2)
            : const Size(1440, 1000);
        tester.view.devicePixelRatio = phone ? 2 : 1;
        tester.platformDispatcher.platformBrightnessTestValue = mode == 'dark'
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
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
        if (name != 'overview') {
          final target = find.text(label);
          if (phone && name == 'tracker') {
            await tester.tap(find.text('Tracker').last);
            await tester.pumpAndSettle();
          } else if (target.evaluate().isEmpty && phone) {
            await tester.tap(find.byTooltip('More pages'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/$name-$mode.png'),
        );
      });
    }
  }
}
