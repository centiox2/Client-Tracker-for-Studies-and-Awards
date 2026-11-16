import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/services/todo_model.dart';

void main() {
  // Monday 16 November 2026, 10:00.
  final now = DateTime(2026, 11, 16, 10);
  tearDown(() => todoClock = DateTime.now);

  group('typing a to-do', () {
    test('plain text stays as it is', () {
      final d = parseTodoLine('Call the embassy', now: now);
      expect(d.title, 'Call the embassy');
      expect(d.understood, isFalse);
    });

    test('a day and a time', () {
      final d = parseTodoLine('Call the embassy tomorrow 3pm', now: now);
      expect(d.title, 'Call the embassy');
      expect(d.day, DateTime(2026, 11, 17));
      expect(d.due, DateTime(2026, 11, 17, 15));
      expect(d.dueTime, isTrue);
    });

    test('"at" and "on" are dropped with what they go with', () {
      final d = parseTodoLine('Meet Grace on friday at 14:30', now: now);
      expect(d.title, 'Meet Grace');
      expect(d.day, DateTime(2026, 11, 20));
      expect(d.due, DateTime(2026, 11, 20, 14, 30));
    });

    test('"by" makes a deadline, not a planned day', () {
      final d = parseTodoLine('Lodge the visa by wednesday', now: now);
      expect(d.title, 'Lodge the visa');
      expect(d.day, isNull);
      expect(d.due, DateTime(2026, 11, 18));
      expect(d.dueTime, isFalse);
    });

    test('today is the default, so it is not stored', () {
      final d = parseTodoLine('Print letters today', now: now);
      expect(d.title, 'Print letters');
      expect(d.day, isNull);
    });

    test('the same weekday means next week', () {
      expect(
        parseTodoLine('Team meeting monday', now: now).day,
        DateTime(2026, 11, 23),
      );
    });

    test('stars, later and repeats', () {
      var d = parseTodoLine('Send invoices urgent', now: now);
      expect((d.title, d.starred), ('Send invoices', true));
      d = parseTodoLine('Tidy the files someday', now: now);
      expect((d.title, d.later), ('Tidy the files', true));
      d = parseTodoLine('Check email daily !', now: now);
      expect(
        (d.title, d.repeat, d.starred),
        ('Check email', TodoRepeat.daily, true),
      );
      d = parseTodoLine('Weekly report every friday', now: now);
      expect(d.title, 'Weekly report');
      expect(d.repeat, TodoRepeat.weekly);
      expect(d.day, DateTime(2026, 11, 20));
    });

    test('#team only where there is a team list', () {
      expect(parseTodoLine('Restock paper #team', now: now).team, isFalse);
      final d = parseTodoLine('#team Restock paper', now: now, allowTeam: true);
      expect((d.title, d.team), ('Restock paper', true));
    });

    test('a line that is only a keyword is kept as the title', () {
      expect(parseTodoLine('tomorrow', now: now).title, 'tomorrow');
      expect(parseTodoLine('3pm', now: now).title, '3pm');
    });

    test('a bad time is just a word', () {
      final d = parseTodoLine('Room 25:99', now: now);
      expect(d.title, 'Room 25:99');
      expect(d.due, isNull);
    });
  });

  group('repeats', () {
    test('the next day for each kind', () {
      final fri = DateTime(2026, 11, 20, 17);
      expect(TodoRepeat.daily.next(fri), DateTime(2026, 11, 21));
      expect(TodoRepeat.weekdays.next(fri), DateTime(2026, 11, 23));
      expect(TodoRepeat.weekly.next(fri), DateTime(2026, 11, 27));
      expect(TodoRepeat.monthly.next(fri), DateTime(2026, 12, 20));
      // The 31st goes to the last day of a shorter month.
      expect(
        TodoRepeat.monthly.next(DateTime(2027, 1, 31)),
        DateTime(2027, 2, 28),
      );
    });
  });

  group('an item', () {
    test('survives being saved and read back', () {
      final t = TodoItem(
        id: 7,
        title: 'Book interview',
        notes: 'Bring the passport',
        day: DateTime(2026, 11, 18),
        due: DateTime(2026, 11, 19, 9, 30),
        dueTime: true,
        starred: true,
        repeat: TodoRepeat.weekdays,
        steps: const [TodoStep('Call'), TodoStep('Email', done: true)],
        outputs: const {'visa_lodgements': 2},
        clientKey: 'app-1',
        clientName: 'Otieno',
        pos: 3.5,
      );
      final back = TodoItem.fromJson(t.toJson());
      expect(back.title, 'Book interview');
      expect(back.notes, 'Bring the passport');
      expect(back.day, DateTime(2026, 11, 18));
      expect(back.due, DateTime(2026, 11, 19, 9, 30));
      expect(back.dueTime, isTrue);
      expect(back.starred, isTrue);
      expect(back.repeat, TodoRepeat.weekdays);
      expect(back.steps.map((s) => (s.title, s.done)), [
        ('Call', false),
        ('Email', true),
      ]);
      expect(back.outputs, {'visa_lodgements': 2});
      expect(back.clientName, 'Otieno');
      expect(back.pos, 3.5);
    });

    test('without a day, belongs to the day it was added', () {
      todoClock = () => now;
      final monday = DateTime(2026, 11, 16, 9).microsecondsSinceEpoch;
      final friday = DateTime(2026, 11, 13, 9).microsecondsSinceEpoch;
      expect(TodoItem(id: monday, title: 'a').planned, DateTime(2026, 11, 16));
      expect(TodoItem(id: friday, title: 'a').planned, DateTime(2026, 11, 13));
      expect(
        TodoItem(id: friday, title: 'a', day: DateTime(2026, 11, 16)).planned,
        DateTime(2026, 11, 16),
      );
      expect(TodoItem(id: friday, title: 'a', later: true).planned, isNull);
      // Old small ids: today.
      expect(TodoItem(id: 3, title: 'a').planned, DateTime(2026, 11, 16));
    });

    test('is overdue only once its deadline has passed', () {
      todoClock = () => now;
      expect(
        TodoItem(id: 1, title: 'a', due: DateTime(2026, 11, 16)).overdue,
        isFalse,
      );
      expect(
        TodoItem(id: 1, title: 'a', due: DateTime(2026, 11, 15)).overdue,
        isTrue,
      );
      expect(
        TodoItem(
          id: 1,
          title: 'a',
          due: DateTime(2026, 11, 16, 9),
          dueTime: true,
        ).overdue,
        isTrue,
      );
      expect(
        TodoItem(
          id: 1,
          title: 'a',
          due: DateTime(2026, 11, 15),
          done: true,
        ).overdue,
        isFalse,
      );
    });
  });
}
