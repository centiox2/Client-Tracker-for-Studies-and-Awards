// A wider visual check than screenshots_test: every tab, the main dialogs,
// the profile picker, and tablet / phone / dark variants. Each run also
// notes any layout overflow. Not part of the test suite:
//
//   flutter test tool/audit_test.dart --update-goldens
//
// Writes tool/shots/audit/<name>.png and tool/shots/audit/problems.txt.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
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
  final root = Platform.environment['FLUTTER_ROOT']!;
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      f('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'),
    );
  await icons.load();
}

void _seed(AppDatabase db) {
  final weeks = WeekRepository(db);
  final counts = ClientCountRepository(db);
  final staff = StaffRepository(db).getAll().where((s) => s.active).toList();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
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
  ApplicationRepository(
    db,
  ).importCsv(File('test/fixtures/applications_sample.csv').readAsStringSync());
  final revenue = RevenueRepository(db);
  for (var i = 1; i <= 8; i++) {
    final d = today.subtract(Duration(days: i));
    revenue.add(
      DateTime(d.year, d.month, d.day, 9 + i),
      (i * 3500 + 5000) * 100,
      note: 'M-Pesa · Student Number $i · UK${i}ABCDEFG',
    );
  }
}

/// One thing to look at: where to go and how big the screen is.
class _Shot {
  const _Shot(
    this.name, {
    this.size = const Size(1440, 1000),
    this.ratio = 1,
    this.dark = false,
    this.steps = const [],
    this.signedIn = true,
  });
  final String name;
  final Size size;
  final double ratio;
  final bool dark;
  final List<Object> steps; // String: tap text (last); Key: tap key
  final bool signedIn;
}

const _phone = Size(390, 844);
const _tablet = Size(1024, 768);

// Tall screens show a whole page in one picture (for the mobile review).
const _tallPhone = Size(390, 2200);
const _tallTablet = Size(820, 2000);

List<_Shot> _pages(
  String prefix,
  Size size,
  double ratio, {
  bool dark = false,
}) => [
  _Shot('$prefix-overview', size: size, ratio: ratio),
  _Shot(
    '$prefix-tracker',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Tracker'],
  ),
  _Shot(
    '$prefix-apps',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Applications'],
  ),
  _Shot(
    '$prefix-apps-all',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Applications', 'All applications'],
  ),
  _Shot(
    '$prefix-apps-table',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Applications', 'Table'],
  ),
  _Shot(
    '$prefix-apps-details',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [
      ValueKey('more'),
      'Applications',
      'All applications',
      'Brian Sample',
    ],
  ),
  _Shot(
    '$prefix-reports',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Reports'],
  ),
  _Shot(
    '$prefix-reports-details',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Reports', 'Details'],
  ),
  _Shot(
    '$prefix-reports-trends',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Reports', 'Trends'],
  ),
  _Shot(
    '$prefix-revenue',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Revenue'],
  ),
  _Shot(
    '$prefix-revenue-all',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Revenue', size.width < 600 ? 'All' : 'All transactions'],
  ),
  _Shot(
    '$prefix-revenue-insights',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: ['Revenue', 'Insights'],
  ),
  _Shot(
    '$prefix-history',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'History'],
  ),
  _Shot(
    '$prefix-staff',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Staff'],
  ),
  _Shot(
    '$prefix-settings',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Settings'],
  ),
  _Shot(
    '$prefix-more',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more')],
  ),
  _Shot(
    '$prefix-menu',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('phone-menu')],
  ),
  for (final p in ['Day', 'Month', 'Year'])
    _Shot(
      '$prefix-reports-details-${p.toLowerCase()}',
      size: size,
      ratio: ratio,
      dark: dark,
      steps: ['Reports', 'Details', p],
    ),
  for (final p in ['Week', 'Year'])
    _Shot(
      '$prefix-revenue-insights-${p.toLowerCase()}',
      size: size,
      ratio: ratio,
      dark: dark,
      steps: ['Revenue', 'Insights', p],
    ),
  _Shot(
    '$prefix-whats-new',
    size: size,
    ratio: ratio,
    dark: dark,
    steps: [ValueKey('more'), 'Settings', 'What’s new'],
  ),
];

final _shots = <_Shot>[
  if (Platform.environment['MOBILE_ONLY'] != null) ...[
    ..._pages('s', const Size(360, 2400), 1),
    ..._pages('m', _tallPhone, 1),
    ..._pages('d', _tallPhone, 1, dark: true),
    ..._pages('t', _tallTablet, 1),
    ..._pages('l', const Size(1024, 1500), 1),
  ] else ...[
    const _Shot('profiles', signedIn: false),
    const _Shot('profiles-phone', size: _phone, ratio: 2, signedIn: false),
    const _Shot('revenue-all', steps: ['Revenue', 'All transactions']),
    const _Shot('revenue-insights', steps: ['Revenue', 'Insights']),
    const _Shot(
      'revenue-insights-dark',
      dark: true,
      steps: ['Revenue', 'Insights'],
    ),
    const _Shot('apps-list', steps: ['Applications', 'All applications']),
    const _Shot(
      'apps-list-dark',
      dark: true,
      steps: ['Applications', 'All applications'],
    ),
    const _Shot('apps-table', steps: ['Applications', 'Table']),
    const _Shot('apps-details', steps: ['Applications', 'Brian Sample']),
    const _Shot('reports-details', steps: ['Reports', 'Details']),
    const _Shot(
      'reports-details-dark',
      dark: true,
      steps: ['Reports', 'Details'],
    ),
    const _Shot('reports-trends', steps: ['Reports', 'Trends']),
    const _Shot('quick-search', steps: [ValueKey('sidebar-search')]),
    const _Shot(
      'new-week',
      steps: ['Weekly tracker', ValueKey('header-new-week')],
    ),
    const _Shot('week-menu', steps: [ValueKey('week-picker')]),
    const _Shot('account-menu', steps: [ValueKey('account-menu')]),
    const _Shot('sidebar-closed', steps: [ValueKey('sidebar-collapse')]),
    const _Shot(
      'sidebar-closed-dark',
      dark: true,
      steps: [ValueKey('sidebar-collapse'), ValueKey('strip-week')],
    ),
    const _Shot('tablet-overview', size: _tablet),
    const _Shot('tablet-tracker', size: _tablet, steps: ['Tracker']),
    const _Shot(
      'tablet-apps',
      size: _tablet,
      steps: [ValueKey('more'), 'Applications'],
    ),
    const _Shot('tablet-reports', size: _tablet, steps: ['Reports']),
    const _Shot('tablet-revenue', size: _tablet, steps: ['Revenue']),
    const _Shot(
      'tablet-settings',
      size: _tablet,
      steps: [ValueKey('more'), 'Settings'],
    ),
    const _Shot(
      'phone-revenue-insights',
      size: _phone,
      ratio: 2,
      steps: ['Revenue', 'Insights'],
    ),
    const _Shot(
      'phone-apps',
      size: _phone,
      ratio: 2,
      steps: [ValueKey('more'), 'Applications'],
    ),
    const _Shot(
      'phone-apps-list',
      size: _phone,
      ratio: 2,
      steps: [ValueKey('more'), 'Applications', 'All applications'],
    ),
    const _Shot(
      'phone-reports-details',
      size: _phone,
      ratio: 2,
      steps: ['Reports', 'Details'],
    ),
    const _Shot(
      'phone-history',
      size: _phone,
      ratio: 2,
      steps: [ValueKey('more'), 'History'],
    ),
    const _Shot('phone-dark', size: _phone, ratio: 2, dark: true),
    const _Shot('revenue-all', steps: ['Revenue', 'All transactions']),
    const _Shot(
      'phone-revenue-all',
      size: _phone,
      ratio: 2,
      steps: ['Revenue', 'All'],
    ),
    const _Shot(
      'settings-about',
      steps: ['Settings', ValueKey('about-section')],
    ),
  ],
];

void main() {
  final problems = <String>[];
  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    Directory('tool/shots/audit').createSync(recursive: true);
  });
  tearDownAll(() {
    File('tool/shots/audit/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'No problems.\n' : problems.join('\n'),
    );
  });

  for (final shot in _shots) {
    testWidgets(shot.name, (tester) async {
      final db = openInMemoryDatabase();
      addTearDown(db.close);
      _seed(db);
      tester.view.physicalSize = shot.size * shot.ratio;
      tester.view.devicePixelRatio = shot.ratio;
      tester.platformDispatcher.platformBrightnessTestValue = shot.dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      // Note layout problems instead of failing, so every shot is taken.
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        final first = details.exceptionAsString().split('\n').first;
        final full = details.toString();
        final m = RegExp(r'The relevant error-causing widget was:\s*\n\s*(.+)')
            .firstMatch(full);
        final where = [
          details.context?.toDescription() ?? '',
          if (m != null) m[1]!.trim(),
        ].where((s) => s.isNotEmpty).join(' · ');
        problems.add('${shot.name}: $first ${where.isEmpty ? '' : '($where)'}');
      };
      addTearDown(() => FlutterError.onError = previous);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            if (shot.signedIn)
              adminSessionProvider.overrideWith(SignedInSession.new),
          ],
          child: const ClientTrackerApp(),
        ),
      );
      await tester.pumpAndSettle();
      for (final step in shot.steps) {
        final Finder f;
        if (step is ValueKey<String> && step.value == 'more') {
          f = find.byTooltip('More pages');
        } else if (step is Key) {
          f = find.byKey(step);
        } else {
          f = find.text(step as String);
        }
        if (f.evaluate().isEmpty) {
          problems.add('${shot.name}: could not find $step');
          break;
        }
        await tester.ensureVisible(f.last);
        await tester.pumpAndSettle();
        await tester.tap(f.last, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      // Every text cut short with "…" (or clipped) on this screen.
      // (Not the hidden choices a dropdown keeps for its width.)
      void visit(RenderObject r) {
        if (r is RenderIndexedStack || r is RenderOffstage) return;
        if (r is RenderParagraph && r.didExceedMaxLines) {
          final text = r.text.toPlainText().replaceAll('\n', ' ');
          problems.add(
            '${shot.name}: cut "${text.length > 70 ? text.substring(0, 70) : text}"',
          );
        }
        r.visitChildren(visit);
      }

      for (final view in tester.binding.renderViews) {
        visit(view);
      }
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/audit/${shot.name}.png'),
      );
    });
  }
}
