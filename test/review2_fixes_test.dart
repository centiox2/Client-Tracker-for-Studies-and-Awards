import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/models/app_user.dart';
import 'package:client_tracker/models/text_clip.dart';
import 'package:client_tracker/models/user_role.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/auth_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/screens/weekly_tracker/weekly_tracker_screen.dart'
    show isoWeekNumber;
import 'package:client_tracker/services/cloud/connection_error.dart';

/// Fixes from the second code review.
void main() {
  late AppDatabase db;
  setUpAll(() => AuthRepository.iterationsForTests = 10);
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  group('passwords', () {
    test('need 8 characters', () {
      final auth = AuthRepository(db);
      expect(() => auth.setAdminPassword('1234567'), throwsArgumentError);
      auth.setAdminPassword('12345678');
      expect(auth.verifyAdmin('12345678'), isTrue);
    });

    test('a hash keeps its own rounds; an old bare hash still opens and '
        'is upgraded', () {
      final auth = AuthRepository(db);
      auth.setAdminPassword('first-pass');
      final stored =
          db.raw
                  .select(
                    "SELECT password_hash FROM app_accounts WHERE role = 'admin';",
                  )
                  .single['password_hash']!
              as String;
      expect(stored, startsWith(r'pbkdf2$10$'));

      // A hash from before rounds were stored (20,000 rounds, bare).
      final salt = Uint8List.fromList(List.filled(16, 7));
      String legacy(String password) {
        final hmac = Hmac(sha256, utf8.encode(password));
        var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
        final out = List<int>.from(u);
        for (var i = 1; i < AuthRepository.legacyIterations; i++) {
          u = hmac.convert(u).bytes;
          for (var j = 0; j < out.length; j++) {
            out[j] ^= u[j];
          }
        }
        return base64Encode(out);
      }

      db.raw.execute(
        "UPDATE app_accounts SET password_hash = ?, salt = ? "
        "WHERE role = 'admin';",
        [legacy('old1'), base64Encode(salt)],
      );
      // A short old password still opens (it was allowed then).
      expect(auth.verifyAdmin('wrong'), isFalse);
      expect(auth.verifyAdmin('old1'), isTrue);
      final upgraded =
          db.raw
                  .select(
                    "SELECT password_hash FROM app_accounts WHERE role = 'admin';",
                  )
                  .single['password_hash']!
              as String;
      expect(upgraded, startsWith(r'pbkdf2$'));
      expect(auth.verifyAdmin('old1'), isTrue);
    });

    test('marking a profile locked keeps its stored password', () {
      final auth = AuthRepository(db)
        ..setProfilePassword(UserRole.director, 'director-pass');
      auth.markProfile(UserRole.director, locked: false);
      auth.markProfile(UserRole.director, locked: true);
      expect(auth.verifyProfile(UserRole.director, 'director-pass'), isTrue);
    });
  });

  test('an empty page list means no pages, not every page', () {
    AppUser user(Object? pages) => AppUser.fromJson({
      'id': 1,
      'username': 'amina',
      'full_name': 'Amina',
      'role': 'team',
      'pages': pages,
    });
    expect(user(null).mayOpen('week'), isTrue);
    expect(user(<String>[]).pages, isEmpty);
    expect(user(<String>[]).mayOpen('week'), isFalse);
    expect(user(<String>[]).toJson()['pages'], isEmpty);
  });

  test('a failed count write leaves no history line behind', () {
    final weeks = WeekRepository(db);
    final w = weeks.createWeekFor(DateTime(2026, 9, 7));
    final day = weeks.getDays(w.id).first;
    final joy = StaffRepository(db).getAll().firstWhere((s) => s.name == 'Joy');
    final counts = ClientCountRepository(db, weekRepository: weeks);
    int lines() =>
        db.raw.select('SELECT COUNT(*) AS c FROM count_changes;').first['c']!
            as int;
    final before = lines();
    // A staff id that doesn't exist: the write fails on its foreign key.
    expect(
      () => counts.saveCount(
        dayId: day.id,
        staffId: 999999,
        newClients: 3,
        existingClients: 0,
      ),
      throwsA(anything),
    );
    expect(lines(), before);
    counts.saveCount(
      dayId: day.id,
      staffId: joy.id,
      newClients: 3,
      existingClients: 0,
    );
    expect(lines(), before + 1);
  });

  test('ISO week numbers around New Year', () {
    expect(isoWeekNumber(DateTime(2027, 1, 1)), 53); // Fri, 2026's week 53
    expect(isoWeekNumber(DateTime(2026, 12, 28)), 53);
    expect(isoWeekNumber(DateTime(2027, 1, 4)), 1);
    expect(isoWeekNumber(DateTime(2026, 1, 1)), 1); // Thu
    expect(isoWeekNumber(DateTime(2025, 12, 29)), 1); // Mon of 2026 week 1
    expect(isoWeekNumber(DateTime(2026, 9, 7)), 37);
  });

  test('amounts: a comma is a thousands mark only before three digits', () {
    expect(RevenueRepository.parseAmount('1,500'), 150000);
    expect(RevenueRepository.parseAmount('12,345,678'), 1234567800);
    expect(RevenueRepository.parseAmount('KSh 2 000'), 200000);
    expect(RevenueRepository.parseAmount('1,5'), isNull);
    expect(RevenueRepository.parseAmount('1.500'), isNull);
  });

  test('CSV dates with two-digit years', () {
    expect(ApplicationRepository.parseDate('2/2/24'), '2024-02-02');
    expect(ApplicationRepository.parseDate('2/2/2024'), '2024-02-02');
  });

  test('a short CSV row keeps the values it stops before', () {
    const header = 'Student name,RTO name,Country,Status\n';
    final repo = ApplicationRepository(db)
      ..importCsv('${header}Amina,WAIFS,Australia,Lodged\n');
    repo.importCsv('${header}Amina,WAIFS\n');
    expect(repo.all().single.status, 'Lodged');
  });

  test('undo never deletes a row that is back already', () {
    final weeks = WeekRepository(db);
    final w = weeks.createWeekFor(DateTime(2026, 9, 7));
    final revenue = RevenueRepository(db);
    final id = revenue.add(DateTime(2026, 9, 7), 50000, note: 'fee');
    final e = revenue.entriesFor(DateTime(2026, 9, 7)).single;
    expect(e.id, id);
    revenue.delete(e.id);
    revenue.restore(e);
    // A second undo of the same entry is a no-op, not an error.
    revenue.restore(e);
    expect(revenue.entriesFor(DateTime(2026, 9, 7)), hasLength(1));
    expect(weeks.getDays(w.id), isNotEmpty);
  });

  test('clipping never splits an emoji', () {
    expect(clipText('ab😀', 3), 'ab');
    expect(clipText('ab😀', 4), 'ab😀');
    expect(clipText('abc', 2), 'ab');
  });

  test('connection errors are told apart from faults', () {
    expect(isConnectionError(Exception('SocketException: Failed host')), true);
    expect(isConnectionError(StateError('bad state')), false);
    expect(isConnectionError(const FormatException('x')), false);
  });
}
