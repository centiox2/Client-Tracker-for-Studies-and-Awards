import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/export_actions.dart';

/// A full backup is the device's data plus, for the admin online, what
/// lives only online. The file must still restore anywhere.
void main() {
  test('a full backup restores the device part and keeps the online part', () {
    final source = openInMemoryDatabase();
    addTearDown(source.close);
    WeekRepository(source).createWeekFor(DateTime(2026, 11, 9));
    final doc = jsonDecode(source.exportToJson()) as Map<String, Object?>;
    doc['online'] = {
      'departments': [
        {'id': 1, 'name': 'Admissions'},
      ],
      'activity_reports': [
        {'id': 7, 'description': 'Lodged visas'},
      ],
    };
    final json = jsonEncode(doc);

    final target = openInMemoryDatabase();
    addTearDown(target.close);
    target.restoreFromJson(json);
    expect(WeekRepository(target).getAllWeeks(), hasLength(1));
    expect(StaffRepository(target).getAll(), isNotEmpty);

    final online = onlinePartOf(json)!;
    expect(online['departments'], hasLength(1));
    expect(online['activity_reports'], hasLength(1));
  });

  test('an older backup has no online part', () {
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    expect(onlinePartOf(db.exportToJson()), isNull);
    expect(onlinePartOf('not json'), isNull);
  });
}
