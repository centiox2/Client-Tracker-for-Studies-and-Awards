import 'dart:io';
import 'dart:convert';

import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/daily_reports_service.dart';
import 'package:client_tracker/services/todo_service.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';
import 'ai_summary_test.dart' show summaryFixture;

import 'package:client_tracker/services/ai_summary_service.dart';

class _InitialTab extends NavTabNotifier {
  _InitialTab(this.tab);
  final AppTab tab;
  @override
  AppTab build() => tab;
}

void _seed(AppDatabase db) {
  final today = DateUtils.dateOnly(DateTime.now());
  final weeks = WeekRepository(db);
  final counts = ClientCountRepository(db);
  final staff = StaffRepository(db).getAll();
  for (final offset in [7, 0]) {
    final week = weeks.createWeekFor(today.subtract(Duration(days: offset)));
    for (final day in weeks.getDays(week.id)) {
      if (day.date.isAfter(today)) continue;
      for (final person in staff) {
        counts.saveCount(
          dayId: day.id,
          staffId: person.id,
          newClients: 2,
          existingClients: 3,
          log: false,
        );
      }
    }
  }
  ApplicationRepository(
    db,
  ).importCsv(File('test/fixtures/applications_sample.csv').readAsStringSync());
  RevenueRepository(db)
      .add(today, 1250000, note: 'M-Pesa · Brian Sample · UK123ABCDEFG');
}

ReportsStart _reports() {
  final today = DateUtils.dateOnly(DateTime.now());
  return ReportsStart(
    meta: ReportsMeta(
      today: today,
      myId: 1,
      myName: 'Amina Wanjiku',
      myDepartmentId: 1,
      scope: ReportScope.all,
      canAssign: true,
      departments: const [Department(id: 1, name: 'Applications')],
      people: const [],
    ),
    badge: const ReportBadge(),
    tasks: [
      ActivityReport(
        id: 1,
        userId: 1,
        departmentId: 1,
        description: 'Follow up outstanding university application documents',
        dueDate: today,
        status: ReportStatus.inProgress,
      ),
      ActivityReport(
        id: 2,
        userId: 1,
        departmentId: 1,
        description: 'Confirm offer letter with the admissions team',
        dueDate: today.subtract(const Duration(days: 1)),
        status: ReportStatus.blocked,
        blocker: 'Waiting for confirmation',
      ),
    ],
    submissions: [
      ActivityReport(
        id: 3,
        userId: 1,
        departmentId: 1,
        description: 'Submitted student visa application',
        date: today,
        status: ReportStatus.done,
        review: ReviewState.submitted,
      ),
    ],
  );
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final weight in [400, 500, 600, 700]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await inter.load();
    final root =
        Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable)
            .parent
            .parent
            .parent
            .parent
            .parent
            .path;
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });

  final views = <(AppTab, String, List<String>)>[
    for (final tab in AppTab.values) (tab, tab.name, []),
    (AppTab.revenue, 'revenue-all', ['All']),
    (AppTab.revenue, 'revenue-insights', ['Insights']),
    (AppTab.applications, 'applications-list', ['All applications']),
    (AppTab.applications, 'applications-table', ['Table']),
    (AppTab.reports, 'reports-details', ['Details']),
    (AppTab.reports, 'reports-trends', ['Trends']),
    (AppTab.settings, 'settings-workspace', ['Workspace']),
    (AppTab.settings, 'settings-data', ['Data']),
    (AppTab.settings, 'settings-team', ['Team']),
    (AppTab.settings, 'settings-ai', ['Team']),
    (AppTab.settings, 'settings-about', ['About']),
    (AppTab.dailyReports, 'daily-submissions', ['My submissions']),
    (AppTab.todo, 'todo-history', ['History']),
    (AppTab.applications, 'application-details', ['Brian Sample']),
    (AppTab.settings, 'navigation-editor', ['Customize bottom bar']),
    (AppTab.home, 'overview-empty', []),
  ];
  for (final (mode, size, scale) in [
    ('desktop', const Size(1440, 1000), 1.0),
    ('tablet', const Size(820, 1180), 1.0),
    ('phone', const Size(390, 844), 1.0),
    ('small', const Size(360, 740), 1.0),
    ('large-text', const Size(390, 844), 1.3),
    ('dark', const Size(1440, 1000), 1.0),
    ('phone-dark', const Size(390, 844), 1.0),
    ('landscape', const Size(740, 390), 1.0),
  ]) {
    for (final (tab, name, steps) in views) {
      testWidgets('$name at $mode has no layout errors', (tester) async {
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().contains('overflow')) {
            debugPrint(details.toString());
          }
          previousErrorHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = previousErrorHandler);
        final today = DateUtils.dateOnly(DateTime.now());
        SharedPreferences.setMockInitialValues({
          'todo_list_device': jsonEncode({
            'team': 'Applications',
            'team_id': 1,
            'items': [
              for (final item in [
                TodoItem(
                  id: 1,
                  title: 'Call the embassy about visa documents',
                  day: today,
                  starred: true,
                ),
                TodoItem(
                  id: 2,
                  title: 'Confirm outstanding university offer letters',
                  day: today,
                  due: today.subtract(const Duration(days: 1)),
                ),
                TodoItem(
                  id: 3,
                  title: 'Prepare the department weekly performance summary',
                  day: today,
                  team: true,
                ),
              ])
                item.toJson(),
            ],
          }),
        });
        final db = openInMemoryDatabase();
        addTearDown(db.close);
        if (name != 'overview-empty') _seed(db);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.platformBrightnessTestValue =
            mode.contains('dark') ? Brightness.dark : Brightness.light;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              adminSessionProvider.overrideWith(SignedInSession.new),
              navTabProvider.overrideWith(() => _InitialTab(tab)),
              accountsEnabledProvider.overrideWithValue(
                tab == AppTab.dailyReports ||
                    tab == AppTab.aiSummary ||
                    name == 'settings-ai',
              ),
              reportViewProvider.overrideWithValue(_reports()),
              aiSummaryAccessProvider.overrideWith((ref) async => true),
              aiSummariesProvider.overrideWith((ref) async => summaryFixture()),
              aiSummarySettingsProvider.overrideWith(
                (ref) async => {
                  'enabled': false,
                  'configured': false,
                  'model': 'gemini-3.8-flash',
                  'users': [],
                },
              ),
            ],
            child: const ClientTrackerApp(),
          ),
        );
        await tester.pumpAndSettle();
        for (var label in steps) {
          if (label == 'All' && size.width >= 600) label = 'All transactions';
          final target = label == 'Customize bottom bar'
              ? find.byKey(const ValueKey('customize-navigation'))
              : tab == AppTab.settings
              ? find.byKey(ValueKey('settings-cat-${label.toLowerCase()}'))
              : tab == AppTab.todo
              ? find.byKey(const ValueKey('todo-history'))
              : find.text(label).last;
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }
        if (name == 'settings-ai') {
          await tester.ensureVisible(find.text('AI daily summary'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        if (name == 'application-details') {
          final status = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Awaiting offer letter'),
          );
          expect(
            tester.renderObject<RenderParagraph>(status).didExceedMaxLines,
            isFalse,
            reason: 'The full application status must remain readable.',
          );
        }
        if (Platform.environment['UI_REVIEW_CAPTURE'] == '1') {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../tool/shots/review/$mode-$name.png'),
          );
        }
        // Exercise the remainder of each page, including controls below the fold.
        final scrollables = find.byType(Scrollable);
        var scrolled = false;
        for (final element in scrollables.evaluate().toList()) {
          if (!element.mounted) continue;
          final state = (element as StatefulElement).state as ScrollableState;
          if (state.position.axis == Axis.vertical &&
              state.position.maxScrollExtent > 0) {
            state.position.jumpTo(state.position.maxScrollExtent);
            scrolled = true;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
        if (scrolled && Platform.environment['UI_REVIEW_CAPTURE'] == '1') {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../tool/shots/review/$mode-$name-end.png'),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
