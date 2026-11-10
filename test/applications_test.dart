import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
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
    // Told apart by institution and country (not their order in the file).
    expect(rows.where((r) => r.student == 'Brian Sample').map((r) => r.key), [
      'brian sample · npa · australia',
      'brian sample · avta · australia',
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
    expect(repo.historyOf('brian sample · npa · australia'), hasLength(2));
    // The second Brian is untouched.
    expect(repo.historyOf('brian sample · avta · australia'), isEmpty);
  });

  test('a renamed column still reads; a missing one never clears data', () {
    final repo = ApplicationRepository(db)..importCsv(sample);
    final coes = repo.all().where((a) => a.coeDate != null).length;
    expect(coes, 2);

    // Airtable renamed "COE issue date" to "COE /CAS issue date".
    final renamed = sample.replaceFirst(
      'COE issue date',
      'COE /CAS issue date',
    );
    expect(renamed, contains('COE /CAS issue date'));
    final r = repo.importCsv(renamed);
    expect((r.added, r.changed, r.removed), (0, 0, 0));
    expect(repo.all().where((a) => a.coeDate != null), hasLength(coes));

    // A column left out of the export altogether keeps what's there.
    final header = sample.split('\n').first;
    final withoutCoe = sample.replaceFirst(
      header,
      header.replaceFirst('COE issue date', 'Unrelated column'),
    );
    final r2 = repo.importCsv(withoutCoe);
    expect(r2.changed, 0);
    expect(repo.all().where((a) => a.coeDate != null), hasLength(coes));
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
    // Opens on its quick view; the full list is the other tab.
    expect(find.text('Needs attention'), findsOneWidget);
    await tester.tap(find.text('All applications'));
    await tester.pumpAndSettle();
    expect(find.text('In progress'), findsOneWidget);
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
    expect(find.text('In progress, by stage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the admin team can upload; empty until then', (tester) async {
    await pumpApp(tester, UserRole.adminTeam);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('upload-applications')), findsOneWidget);
    expect(find.textContaining('Download CSV'), findsOneWidget);
  });

  testWidgets('the applications quick view: today, the week, attention', (
    tester,
  ) async {
    final now = DateTime.now();
    String long(DateTime d) => DateFormat('MMMM d, y').format(d);
    String short(DateTime d) => DateFormat('dd/MM/yyyy').format(d);
    final old = now.subtract(const Duration(days: 40));
    final csv =
        'Student name,RTO name,Country,Doc submit date,App submitted date,'
        'Offer letter received date,COE issue date,Status,Assignee,To do list\n'
        'Today Coe,Reach,Australia,,,,"${long(now)}",COE ISSUED/DONE,Mourine,\n'
        'Today Offer,NPA,Australia,,,"${long(now)}",,To pay school fees,Joy,\n'
        'Noted Today,WAIFS,Australia,"${long(old)}",,,,Statement building,Joy,'
        '"${short(now)}- Student sent bank statements"\n'
        'Long Wait,AVTA,Australia,"${long(old)}","${long(old)}",,,'
        'Awaiting offer letter,Ian,\n'
        'Nobody Assigned,,Australia,"${long(now)}",,,,'
        'Application to be submitted,,\n';
    ApplicationRepository(db).importCsv(csv);
    await pumpApp(tester, UserRole.director);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();

    // Today's feed: the COE, the offer, documents and the dated note.
    expect(find.text('COE issued'), findsWidgets);
    expect(find.text('Offer letter received'), findsOneWidget);
    expect(find.text('Documents submitted'), findsWidgets);
    expect(find.text('Student sent bank statements'), findsOneWidget);
    expect(find.text('3 notes dated today'), findsNothing);
    expect(find.text('1 notes dated today'), findsOneWidget);
    // Waiting longest: 40 days since the application.
    expect(find.text('40 d'), findsOneWidget);
    expect(find.text('1 in progress with no assignee'), findsOneWidget);
    // Every in-progress one here has a date; none are left unaccounted.
    expect(find.textContaining('no dates in the tracker'), findsNothing);
    // Tapping a stage lists it.
    await tester.tap(find.text('Awaiting offer letter · 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('who’s handling what: tap a name for theirs and the unassigned', (
    tester,
  ) async {
    final now = DateTime.now();
    String long(DateTime d) => DateFormat('MMMM d, y').format(d);
    final csv =
        'Student name,RTO name,Country,Doc submit date,App submitted date,'
        'Offer letter received date,COE issue date,Status,Assignee\n'
        'Amy One,Reach,Australia,"${long(now)}",,,,Awaiting offer letter,Joy\n'
        'Ben Two,NPA,Canada,"${long(now)}",,,,To pay school fees,Joy\n'
        'Cal Three,AVTA,Australia,"${long(now)}",,,,Awaiting offer letter,Ian\n'
        'Dee Four,WAIFS,Australia,"${long(now)}",,,,'
        'Application to be submitted,\n'
        'Eve Done,Reach,Australia,,,,"${long(now)}",COE ISSUED/DONE,Joy\n';
    ApplicationRepository(db).importCsv(csv);
    await pumpApp(tester, UserRole.director);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('handling-Joy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('handling-Joy')));
    await tester.pumpAndSettle();
    expect(find.text('HANDLING · 2'), findsOneWidget);
    expect(find.text('UNASSIGNED · 1'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    for (final name in ['Amy One', 'Ben Two', 'Dee Four']) {
      expect(
        find.descendant(of: dialog, matching: find.text(name)),
        findsOneWidget,
      );
    }
    // Only in-progress ones: Eve's is done; Cal is Ian's.
    expect(
      find.descendant(of: dialog, matching: find.text('Eve Done')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Cal Three')),
      findsNothing,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // "No assignee": the unassigned on their own.
    await tester.ensureVisible(
      find.byKey(const ValueKey('handling-No assignee')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('handling-No assignee')));
    await tester.pumpAndSettle();
    expect(find.text('Unassigned applications'), findsOneWidget);
    expect(find.text('HANDLING · 2'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Dee Four'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the table shows every column, sorts and searches', (
    tester,
  ) async {
    ApplicationRepository(db).importCsv(sample);
    await pumpApp(tester, UserRole.director);
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    for (final h in [
      'Student name',
      'RTO name',
      'Country',
      'Doc submit date',
      'COE / CAS issue date',
      'Status',
      'Assignee',
      'To do list',
    ]) {
      expect(find.text(h), findsWidgets, reason: h);
    }
    expect(find.text('8 rows'), findsOneWidget);
    // Airtable order: by status first (Statement building before COE).
    Offset at(String name) => tester.getTopLeft(find.text(name).first);
    expect(at('Amina Test').dy, lessThan(at('Dan Demo').dy));
    // Sort by name, A to Z.
    await tester.tap(find.byKey(const ValueKey('table-sort-Student name')));
    await tester.pumpAndSettle();
    expect(at('Amina Test').dy, lessThan(at('Brian Sample').dy));
    expect(at('Brian Sample').dy, lessThan(at('Carol Example').dy));
    // Search.
    await tester.enterText(
      find.byKey(const ValueKey('table-search')),
      'kaplan',
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of 8 rows'), findsOneWidget);
    await tester.tap(find.text('George Pilot'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Offer letter received'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _As extends SessionNotifier {
  _As(this.role);
  final UserRole role;
  @override
  UserRole? build() => role;
}
