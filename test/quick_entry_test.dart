import 'package:client_tracker/screens/daily_reports/quick_entry.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Monday.
  final today = DateTime(2026, 11, 9);
  const visas = Department(
    id: 2,
    name: 'Visa Processing',
    outputs: [OutputField('visa_lodgements', 'Visa lodgements')],
  );
  const admissions = Department(
    id: 1,
    name: 'Admissions',
    outputs: [
      OutputField('applications_submitted', 'Applications submitted'),
      OutputField('coes_issued', 'COEs issued'),
    ],
  );

  QuickEntry parse(String text, [Department? d]) =>
      parseQuickEntry(text, today: today, department: d);

  test('a plain title stays as it is', () {
    final e = parse('Follow up the pending COEs');
    expect(e.title, 'Follow up the pending COEs');
    expect(e.understood, isFalse);
  });

  test('done and a count', () {
    final e = parse('Lodged visas 3 done', visas);
    expect(e.title, 'Lodged visas');
    expect(e.done, isTrue);
    expect(e.outputs, {'visa_lodgements': 3});
    expect(e.due, isNull);
  });

  test('a count goes to the output its name matches', () {
    expect(parse('Issued COEs 4', admissions).outputs, {'coes_issued': 4});
    expect(parse('Submitted applications 7 done', admissions).outputs, {
      'applications_submitted': 7,
    });
    // Not clear which: the number stays in the title.
    final e = parse('Calls 5', admissions);
    expect(e.outputs, isEmpty);
    expect(e.title, 'Calls 5');
  });

  test('due days and urgency', () {
    final e = parse('Call embassy tomorrow urgent');
    expect(e.title, 'Call embassy');
    expect(e.urgency, TaskUrgency.urgent);
    expect(e.due, DateTime(2026, 11, 10));
    expect(parse('Send the report by Friday').due, DateTime(2026, 11, 13));
    // Its own weekday means next week's.
    expect(parse('Team meeting monday').due, DateTime(2026, 11, 16));
    expect(parse('Tidy the files low').urgency, TaskUrgency.low);
    expect(parse('Pay rent today high').due, today);
  });

  test('a lone keyword is a title, not a rule', () {
    expect(parse('done').title, 'done');
    expect(parse('urgent').understood, isFalse);
    expect(parse('Done: renewed 2 passports').done, isTrue);
    expect(parse('Done: renewed 2 passports').title, 'renewed 2 passports');
  });
}
