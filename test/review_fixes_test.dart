import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/excel_import.dart';

/// Fixes from the security and bug review.
void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  group('CSV upload', () {
    const header = 'Student name,RTO name,Country,Status\n';

    test('a quote that never closes is refused, nothing changes', () {
      final repo = ApplicationRepository(db)
        ..importCsv(
          '${header}Amina,WAIFS,Australia,Lodged\nBrian,NPA,Australia,Lodged\n',
        );
      expect(
        () =>
            repo.importCsv('${header}Amina,"WAIFS,Australia,Lodged\nBrian,NPA'),
        throwsA(isA<ApplicationCsvException>()),
      );
      expect(repo.all(), hasLength(2));
    });

    test('a row with more fields than the header is refused', () {
      expect(
        () => ApplicationRepository.parseApplicationsCsv(
          '${header}Amina,WAIFS,Australia,Lodged,extra\n',
        ),
        throwsA(isA<ApplicationCsvException>()),
      );
      // Fewer fields (trailing blanks trimmed by Excel) is fine.
      expect(
        ApplicationRepository.parseApplicationsCsv('${header}Amina,WAIFS\n'),
        hasLength(1),
      );
    });

    test('wouldRemove counts removals without changing anything', () {
      final repo = ApplicationRepository(db)
        ..importCsv(
          '${header}Amina,WAIFS,Australia,Lodged\n'
          'Brian,NPA,Australia,Lodged\n'
          'Cara,AVTA,Australia,Lodged\n',
        );
      expect(repo.wouldRemove('${header}Amina,WAIFS,Australia,Lodged\n'), 2);
      expect(repo.all(), hasLength(3));
      expect(
        repo.wouldRemove(
          '${header}Amina,WAIFS,Australia,Lodged\n'
          'Brian,NPA,Australia,Lodged\n'
          'Cara,AVTA,Australia,Lodged\n',
        ),
        0,
      );
    });
  });

  test('Excel numbers for a day marked off take the mark away', () {
    final weeks = WeekRepository(db);
    final w = weeks.createWeekFor(DateTime(2026, 9, 7));
    final day = weeks.getDays(w.id).first;
    final joy = StaffRepository(db).getAll().firstWhere((s) => s.name == 'Joy');
    weeks.addStaffToWeek(w.id, [joy.id]);
    final off = TimeOffRepository(db)
      ..setDay(dayId: day.id, staffId: joy.id, off: true);
    final data = ExcelImport(
      days: [
        ImportDay(DateTime(2026, 9, 7))
          ..entries['Joy'] = const ImportEntry(
            newClients: 3,
            existingClients: 0,
          ),
      ],
      warnings: const [],
    );
    applyExcelImport(db, data, {'Joy': MatchStaff(joy.id)}, overwrite: true);
    expect(off.offStaffIds(day.id), isEmpty);
    expect(ClientCountRepository(db).countValues(day.id, joy.id).newClients, 3);
  });

  test('the rolling backup holds unsaved WAL changes but no sign-ins', () {
    final dir = Directory.systemTemp.createTempSync('backup_scrub');
    addTearDown(() => dir.deleteSync(recursive: true));
    final live = openPlatformDatabase(dir.path);
    final path = p.join(dir.path, 'client_tracker.db');
    WeekRepository(live).createWeekFor(DateTime(2026, 9, 7));
    live.raw.execute(
      'INSERT INTO user_signins (username, user_json, token, remembered, '
      "updated_at) VALUES ('amina', '{}', 'secret-token', 1, 'now');",
    );
    // An older copy from before sign-ins were taken out.
    File(path).copySync('$path.bak2');
    final old = sqlite3.open('$path.bak2');
    old.execute(
      'CREATE TABLE IF NOT EXISTS user_signins (username TEXT PRIMARY KEY, '
      'user_json TEXT NOT NULL, password_hash TEXT, salt TEXT, token TEXT, '
      'remembered INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL);',
    );
    old.execute(
      'INSERT OR REPLACE INTO user_signins (username, user_json, token, '
      "remembered, updated_at) VALUES ('old', '{}', 'old-token', 1, 'now');",
    );
    old.dispose();

    // The app is still open (changes may be only in the WAL).
    makeRollingBackup(path);
    live.close();

    final copy = sqlite3.open('$path.bak1');
    addTearDown(copy.dispose);
    expect(copy.select('SELECT * FROM weeks;'), hasLength(1));
    expect(copy.select('SELECT * FROM user_signins;'), isEmpty);
    final older = sqlite3.open('$path.bak3');
    addTearDown(older.dispose);
    expect(older.select('SELECT * FROM user_signins;'), isEmpty);
    expect(File('$path.bak.tmp').existsSync(), isFalse);
    expect(
      File('$path.bak1').readAsStringSync(encoding: latin1),
      isNot(contains('secret-token')),
    );
  });
}
