import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/state/app_state.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  final sample = File('test/fixtures/applications_sample.csv')
      .readAsStringSync();

  test('reads the Airtable export: quotes, line breaks, dates, duplicates', () {
    final rows = ApplicationRepository.parseApplicationsCsv(sample);
    expect(rows, hasLength(8));
    final amina = rows.first;
    expect(amina.student, 'Amina Test');
    expect(amina.fields[2], '2026-08-19'); // doc date
    expect(amina.fields[8], contains('\n')); // multi-line note kept
    expect(amina.fields[8], contains('"Perth"'));
    // The same name twice: told apart.
    expect(rows.where((r) => r.student == 'Brian Sample').map((r) => r.key), [
      'brian sample',
      'brian sample #2',
    ]);
    // "Drop out " keeps no stray space.
    expect(rows.last.status, 'Drop out');
    expect(ApplicationRepository.parseDate('2/11/2026'), '2026-11-02');
    expect(ApplicationRepository.parseDate('nonsense'), isNull);
    expect(
      () => ApplicationRepository.parseApplicationsCsv('a,b\n1,2'),
      throwsA(isA<ApplicationCsvException>()),
    );
  });

  test('each upload notes what changed since the last one', () {
    final repo = ApplicationRepository(db);
    final first = repo.importCsv(sample);
    expect(first.first, isTrue);
    expect(first.total, 8);
    expect(repo.changesFor(repo.latestImport!.id), isEmpty);
    expect(repo.all().where((a) => a.inProgress), hasLength(4));

    // Next week's export: Amina applied, Brian got an offer and moved on,
    // Faith is gone, Hana is new.
    final next = sample
        .replaceFirst(
          'Amina Test,WAIFS,Australia,"August 19, 2026",,',
          'Amina Test,WAIFS,Australia,"August 19, 2026","November 3, 2026",',
        )
        .replaceFirst(
          'Brian Sample,NPA,Australia,"July 6, 2026","August 4, 2026",,,'
              'Awaiting offer letter',
          'Brian Sample,NPA,Australia,"July 6, 2026","August 4, 2026",'
              '"November 4, 2026",,To pay school fees',
        )
        .replaceFirst(RegExp(r'Faith Trial[^\n]*\n'), '')
        .replaceFirst(
          'George Pilot',
          'Hana New,NPA,Australia,,,,,Statement building,Joy,,,,,,,\r\n'
              'George Pilot',
        );
    final r = repo.importCsv(next, fileName: 'week2.csv');
    expect(r.first, isFalse);
    expect((r.added, r.changed, r.removed), (1, 2, 1));
    final changes = repo.changesFor(repo.latestImport!.id);
    String? find(String student, String field) => changes
        .where((c) => c.student == student && c.field == field)
        .map((c) => '${c.oldValue}|${c.newValue}')
        .firstOrNull;
    expect(find('Amina Test', 'app_date'), '|2026-11-03');
    expect(
      find('Brian Sample', 'status'),
      'Awaiting offer letter|To pay school fees',
    );
    expect(find('Brian Sample', 'offer_date'), '|2026-11-04');
    expect(find('Faith Trial', 'removed'), 'Withdrawn|');
    expect(find('Hana New', 'added'), '|Statement building');
    expect(repo.historyOf('brian sample'), hasLength(2));
    // The second Brian is untouched.
    expect(repo.historyOf('brian sample #2'), isEmpty);
  });

  Future<void> pumpApp(WidgetTester tester, UserRole role) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(() => _As(role)),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the boss sees applications, grouped by status, read-only', (
    tester,
  ) async {
    final repo = ApplicationRepository(db)..importCsv(sample);
    repo.importCsv(
      sample.replaceFirst('Awaiting offer letter', 'To pay school fees'),
    );
    await pumpApp(tester, UserRole.director);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('upload-applications')), findsNothing);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('Brian Sample'), findsWidgets);
    // Grouped like Airtable, each group a status tag with its count.
    expect(find.text('COE ISSUED/DONE'), findsWidgets);
    expect(find.text('Statement building'), findsWidgets);

    // Search narrows the list.
    await tester.enterText(
      find.byKey(const ValueKey('applications-search')),
      'carol',
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of 8'), findsOneWidget);

    // A student's details and history.
    await tester.tap(find.text('Carol Example').last);
    await tester.pumpAndSettle();
    expect(find.text('Offer letter received'), findsOneWidget);
    expect(find.text('1 Sep 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Quick view shows applications and the latest updates', (
    tester,
  ) async {
    final repo = ApplicationRepository(db)..importCsv(sample);
    repo.importCsv(
      sample.replaceFirst('Awaiting offer letter', 'To pay school fees'),
    );
    await pumpApp(tester, UserRole.team);
    expect(find.byKey(const ValueKey('quick-applications')), findsOneWidget);
    expect(find.text('Applications in progress'), findsOneWidget);
    expect(find.text('Application updates'), findsOneWidget);
    expect(find.text('To pay school fees'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('quick-applications')));
    await tester.pumpAndSettle();
    expect(find.text('By stage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the admin team can upload; empty until then', (tester) async {
    await pumpApp(tester, UserRole.adminTeam);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('upload-applications')), findsOneWidget);
    expect(find.textContaining('Download CSV'), findsOneWidget);
  });
}

class _As extends SessionNotifier {
  _As(this.role);
  final UserRole role;
  @override
  UserRole? build() => role;
}
