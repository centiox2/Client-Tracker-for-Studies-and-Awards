import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// "No change in 14+ days" on Applications: anything the team did counts as
/// work, so an application someone is working on is never flagged.
void main() {
  final today = DateTime(2026, 11, 30);
  final oldStep = DateTime(2026, 9, 1);

  ApplicationChange change(String field, String value, DateTime at) =>
      ApplicationChange(
        id: 1,
        importId: 1,
        key: 'amina',
        student: 'Amina',
        field: field,
        oldValue: '',
        newValue: value,
        at: at,
      );

  Application app({String todo = '', String followUp = '', DateTime? seen}) =>
      Application(
        id: 1,
        key: 'amina',
        student: 'Amina',
        status: 'Statement building',
        appDate: oldStep,
        todo: todo,
        followUp: followUp,
        updatedAt: seen,
      );

  test('a status change in Airtable counts as work', () {
    final last = ApplicationActivity.of(
      app(),
      today,
      change: change(
        'status',
        'To pay school fees',
        DateTime(2026, 11, 27, 15),
      ),
    )!;
    expect(last.day, DateTime(2026, 11, 27));
    expect(last.what, 'Status changed to To pay school fees');
  });

  test('a follow-up or to-do edit counts, and says what was written', () {
    final last = ApplicationActivity.of(
      app(),
      today,
      change: change('follow_up', 'Called the school\nawaiting reply', today),
    )!;
    expect(last.day, today);
    expect(last.what, 'Follow-up updated: Called the school awaiting reply');
  });

  test('a date anywhere in the follow-up or to-do counts', () {
    expect(
      ApplicationActivity.of(
        app(followUp: 'Called the school 25/11/2026, awaiting reply'),
        today,
      )!.what,
      'Follow-up: Called the school 25/11/2026, awaiting reply',
    );
    expect(
      ApplicationActivity.of(app(todo: 'Paid on 26-11-26'), today)!.day,
      DateTime(2026, 11, 26),
    );
  });

  test('only real dates on their own are read', () {
    expect(Application.datesIn('03/11/2026- Paid'), [DateTime(2026, 11, 3)]);
    expect(Application.datesIn('Paid 3.11.26.'), [DateTime(2026, 11, 3)]);
    expect(Application.datesIn('ref 1/2/3/4'), isEmpty);
    expect(Application.datesIn('31/02/2026'), isEmpty);
    expect(Application.datesIn('Tel 0712/345/678'), isEmpty);
  });

  test('a date ahead (an appointment, a deadline) is not work done', () {
    final last = ApplicationActivity.of(
      app(todo: 'Visa appointment 15/12/2026'),
      today,
    )!;
    expect(last.day, oldStep);
    expect(last.what, 'Application submitted');
  });

  test('with nothing newer, the oldest sign shows and it is flagged', () {
    final last = ApplicationActivity.of(
      app(todo: '01/10/2026- Working on the statement'),
      today,
    )!;
    expect(last.day, DateTime(2026, 10, 1));
    expect(
      today.difference(last.day).inDays,
      greaterThanOrEqualTo(ApplicationActivity.staleDays),
    );
  });

  test('never counted as waiting longer than it has been in the tracker', () {
    final last = ApplicationActivity.of(
      app(seen: DateTime(2026, 11, 20, 10)),
      today,
    )!;
    expect(last.day, DateTime(2026, 11, 20));
    expect(last.what, 'No change since it came into the tracker');
    // A change that day says more than "came into the tracker".
    expect(
      ApplicationActivity.of(
        app(seen: DateTime(2026, 11, 20, 10)),
        today,
        change: change('status', 'Visa lodged', DateTime(2026, 11, 20, 10)),
      )!.what,
      'Status changed to Visa lodged',
    );
  });

  test('without any history, coming into the tracker is the last sign', () {
    final last = ApplicationActivity.of(
      const Application(id: 1, key: 'x', student: 'X', status: 'New'),
      today,
    );
    expect(last, isNull);
    final seen = ApplicationActivity.of(
      Application(
        id: 1,
        key: 'x',
        student: 'X',
        updatedAt: DateTime(2026, 11, 5),
      ),
      today,
    )!;
    expect(seen.what, 'No change since it came into the tracker');
  });

  test('the newest change for each application is read from the log', () {
    final db = openInMemoryDatabase();
    final repo = ApplicationRepository(db);
    const csv =
        'Student name,RTO name,Country,Status,Assignee,To do list\n'
        'Amina Test,WAIFS,Australia,Statement building,Joy,\n'
        'Brian Sample,NPA,Australia,Awaiting offer letter,Ian,\n';
    repo.importCsv(csv);
    expect(repo.lastChanges(), isEmpty); // the first upload isn't a change
    repo.importCsv(
      csv.replaceFirst('Statement building', 'To pay school fees'),
    );
    repo.importCsv(
      csv
          .replaceFirst('Statement building', 'To pay school fees')
          .replaceFirst('Joy,', 'Joy,Waiting on bank letter'),
    );
    final last = repo.lastChanges();
    expect(last.keys, ['amina test']);
    expect(last['amina test']!.field, 'todo');
    expect(repo.firstImportAt, isNotNull);
  });
}
