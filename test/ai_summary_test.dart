import 'dart:async';

import 'package:client_tracker/services/ai_summary_service.dart';
import 'package:client_tracker/screens/ai_summary/ai_summary_screen.dart';
import 'package:client_tracker/screens/settings/ai_summary_settings.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/state/mobile_navigation.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> summaryFixture() => {
  'can_generate': true,
  'enabled': true,
  'configured': true,
  'today': '2026-11-18',
  'status': 'ready',
  'summaries': [
    for (final date in ['2026-11-18', '2026-11-17'])
      {
        'summary_date': date,
        'cutoff_at': '${date}T14:05:00Z',
        'generated_at': '${date}T14:05:30Z',
        'model': 'gemini-3.8-flash',
        'content': {
          'brief': 'Daily company overview for $date.',
          'highlights': ['Recorded client activity is available.'],
          'risks': ['Review overdue work.'],
          'actions': ['Follow up on open tasks.'],
          'sections': [
            for (final name in [
              'Weekly tracker',
              'Revenue',
              'Applications',
              'Daily reports',
              'Team to-do',
              'Staff',
              'History',
              'Reports',
              'Settings',
            ])
              {
                'title': name,
                'body': 'A concise summary of recorded $name activity.',
              },
          ],
        },
        'input_snapshot': {
          'staff': {'active': 5},
        },
      },
  ],
};

class _Person extends CurrentUserNotifier {
  _Person(this.user);
  final AppUser user;
  @override
  AppUser? build() => user;
}

void main() {
  for (final role in UserRole.values) {
    for (final granted in [false, true]) {
      test('${role.name}: AI summary requires explicit grant', () async {
        final db = openInMemoryDatabase();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            accountsEnabledProvider.overrideWithValue(true),
            currentUserProvider.overrideWith(
              () => _Person(
                AppUser(
                  id: 1,
                  username: 'person',
                  fullName: 'Person',
                  role: role,
                  pages: {'todo'},
                ),
              ),
            ),
            aiSummaryAccessProvider.overrideWith((ref) async => granted),
          ],
        );
        addTearDown(container.dispose);
        await container.read(aiSummaryAccessProvider.future);
        expect(
          container.read(availableAppTabsProvider).contains(AppTab.aiSummary),
          granted,
        );
        if (granted) {
          container.read(mobileNavigationProvider.notifier).save([
            AppTab.aiSummary,
          ]);
          expect(container.read(mobileBarTabsProvider), [AppTab.aiSummary]);
        }
      });
    }
  }
  test(
    'service sends only configuration fields and keeps blank key optional',
    () async {
      String? called;
      Map<String, Object?>? params;
      final service = AiSummaryService((name, [args]) async {
        called = name;
        params = args;
        return null;
      });
      await service.save(enabled: false, model: 'gemini-3.8-flash', users: [2]);
      expect(called, 'ai_summary_configure');
      expect(params, {
        'p_enabled': false,
        'p_model': 'gemini-3.8-flash',
        'p_user_ids': [2],
        'p_key': null,
      });
    },
  );
  testWidgets('unassigned summary page does not request company data', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSummaryAccessProvider.overrideWith((ref) async => false),
          aiSummariesProvider.overrideWith((ref) async {
            reads++;
            return summaryFixture();
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.textContaining('Admin must assign'), findsOneWidget);
  });
  for (final size in [
    const Size(360, 740),
    const Size(820, 1180),
    const Size(1440, 1000),
  ]) {
    testWidgets('AI summary history works at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiSummaryAccessProvider.overrideWith((ref) async => true),
            aiSummariesProvider.overrideWith((ref) async => summaryFixture()),
          ],
          child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Daily company overview for 2026-11-18.'),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-11-17').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Daily company overview for 2026-11-17.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('admin saves access assignments and clears key input', (
    tester,
  ) async {
    Map<String, Object?>? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSummarySettingsProvider.overrideWith(
            (ref) async => {
              'enabled': false,
              'configured': false,
              'model': 'gemini-3.8-flash',
              'users': [
                {
                  'id': 2,
                  'name': 'Team member',
                  'role': 'team',
                  'assigned': false,
                },
              ],
            },
          ),
          aiSummaryServiceProvider.overrideWithValue(
            AiSummaryService((name, [args]) async {
              saved = args;
              return null;
            }),
          ),
          aiSummaryAccessProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AiSummarySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'test-key-12345678901234567890',
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(find.text('Save AI settings'));
    await tester.tap(find.text('Save AI settings'));
    await tester.pumpAndSettle();
    expect(saved?['p_user_ids'], [2]);
    expect(saved?['p_key'], 'test-key-12345678901234567890');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
  });
  testWidgets(
    'Admin can generate with schedule off; repeated clicks are disabled and the previous report stays visible',
    (tester) async {
      var data = summaryFixture()..['enabled'] = false;
      var requests = 0;
      final pending = Completer<Object?>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiSummaryAccessProvider.overrideWith((ref) async => true),
            aiSummariesProvider.overrideWith((ref) async => data),
            aiSummaryServiceProvider.overrideWithValue(
              AiSummaryService((name, [args]) async {
                expect(name, 'ai_summary_generate');
                expect(args, isNull);
                requests++;
                return pending.future;
              }),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('generate-ai-report'));
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(requests, 1);
      expect(
        find.text('Daily company overview for 2026-11-18.'),
        findsOneWidget,
      );
      data = {...data, 'status': 'queued'};
      pending.complete({'status': 'queued'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(
        find.text('Daily company overview for 2026-11-18.'),
        findsOneWidget,
      );
      data = summaryFixture();
      (data['summaries'] as List).first['content']['brief'] =
          'Freshly generated report.';
      ProviderScope.containerOf(tester.element(find.byType(AiSummaryScreen)))
          .invalidate(aiSummariesProvider);
      await tester.pumpAndSettle();
      expect(find.text('Freshly generated report.'), findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    },
  );
  testWidgets('Assigned readers cannot generate reports', (tester) async {
    final data = summaryFixture()..['can_generate'] = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSummaryAccessProvider.overrideWith((ref) async => true),
          aiSummariesProvider.overrideWith((ref) async => data),
        ],
        child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generate-ai-report')), findsNothing);
  });
  testWidgets('An Admin without a saved key sees configuration guidance', (
    tester,
  ) async {
    final data = summaryFixture()..['configured'] = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSummaryAccessProvider.overrideWith((ref) async => true),
          aiSummariesProvider.overrideWith((ref) async => data),
        ],
        child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('generate-ai-report')),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Add your Gemini API key'), findsOneWidget);
  });
  testWidgets('A failed request offers retry without losing the saved report', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSummaryAccessProvider.overrideWith((ref) async => true),
          aiSummariesProvider.overrideWith((ref) async => summaryFixture()),
          aiSummaryServiceProvider.overrideWithValue(
            AiSummaryService(
              (name, [args]) async => throw StateError('offline'),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generate-ai-report')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not request the report.'),
      findsOneWidget,
    );
    expect(find.text('Daily company overview for 2026-11-18.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('generate-ai-report')),
          )
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'A running report refreshes automatically when generation completes',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountsEnabledProvider.overrideWithValue(false),
            aiSummaryAccessProvider.overrideWith((ref) async => true),
            aiSummaryServiceProvider.overrideWithValue(
              AiSummaryService((name, [args]) async {
                expect(name, 'ai_summary_read');
                reads++;
                final data = summaryFixture();
                if (reads == 1) {
                  data['status'] = 'running';
                } else {
                  (data['summaries'] as List).first['content']['brief'] =
                      'Automatically updated report.';
                }
                return data;
              }),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: AiSummaryScreen())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 1);
      expect(find.text('Generating report…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('Automatically updated report.'), findsOneWidget);
    },
  );
}
