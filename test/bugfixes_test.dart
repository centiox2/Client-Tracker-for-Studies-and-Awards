import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/models/staff.dart';
import 'package:client_tracker/repositories/client_count_repository.dart'
    show WeekTotals;
import 'package:client_tracker/screens/history/history_screen.dart';
import 'package:client_tracker/services/auto_backup_store.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('migration adds show-zeros column to an existing weeks table', () {
    final raw = sqlite.sqlite3.openInMemory();
    addTearDown(raw.dispose);
    raw.execute('''
      CREATE TABLE weeks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_date TEXT NOT NULL UNIQUE,
        end_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    raw.execute(
      'INSERT INTO weeks (start_date, end_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['2026-10-12', '2026-10-16', '2026-10-12', '2026-10-12'],
    );

    AppDatabase.migrate(raw);

    final db = AppDatabase.internal(':memory:', raw);
    final repo = WeekRepository(db);
    final week = repo.getWeek(1)!;
    expect(week.showZeros, isTrue);
    repo.setShowZeros(week.id, false);
    expect(repo.getWeek(week.id)!.showZeros, isFalse);
  });

  group('week containment', () {
    late Week week;

    setUp(() {
      week = Week(
        id: 1,
        startDate: DateTime(2026, 9, 28), // Monday
        endDate: DateTime(2026, 10, 2), // Friday
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
    });

    test('midnight timestamps of the end date are inside the week', () {
      // DateTime.now() during Friday midnight-to-morning previously fell
      // outside because its time-of-day exceeded the stored midnight.
      expect(week.containsDate(DateTime(2026, 10, 2, 9, 30)), isTrue);
      expect(week.containsDate(DateTime(2026, 10, 2, 23, 59)), isTrue);
      expect(week.containsDate(DateTime(2026, 9, 28, 0, 1)), isTrue);
      // Neighbouring days stay outside.
      expect(week.containsDate(DateTime(2026, 9, 27, 12)), isFalse);
      expect(week.containsDate(DateTime(2026, 10, 3, 12)), isFalse);
    });
  });

  group('history search', () {
    WeekSummary summaryFor(DateTime monday) => WeekSummary(
      week: Week(
        id: 1,
        startDate: monday,
        endDate: monday.add(const Duration(days: 4)),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      totals: const WeekTotals(
        newClients: 0,
        existingClients: 0,
        dailyAverage: 0,
        perDay: {},
      ),
    );

    test('matches by month-name label', () {
      final w = summaryFor(DateTime(2026, 9, 28));
      expect(weekMatchesQuery(w, 'sept'), isTrue);
      expect(weekMatchesQuery(w, 'October'), isTrue); // end date label
      expect(weekMatchesQuery(w, 'banana'), isFalse);
    });

    test('matches DD/MM/YYYY dates anywhere inside the week', () {
      final w = summaryFor(DateTime(2026, 9, 28));
      expect(weekMatchesQuery(w, '28/09/2026'), isTrue); // Monday
      expect(weekMatchesQuery(w, '30/09/2026'), isTrue); // Wednesday
      expect(weekMatchesQuery(w, '02/10/2026'), isTrue); // Friday
      // Single-digit day/month variants.
      expect(weekMatchesQuery(w, '1/10/2026'), isTrue);
      // Outside the week.
      expect(weekMatchesQuery(w, '05/10/2026'), isFalse);
      // Wrong year is not a match (dates include the year).
      expect(weekMatchesQuery(w, '28/09/2025'), isFalse);
    });

    test('matches DD/MM with the week year', () {
      final w = summaryFor(DateTime(2026, 9, 28));
      expect(weekMatchesQuery(w, '28/09'), isTrue);
      expect(weekMatchesQuery(w, '02/10'), isTrue);
      // No false positives on plain text that happens to contain digits.
      expect(weekMatchesQuery(w, '12/13'), isFalse);
    });

    test('matches both years in a week that crosses New Year', () {
      final w = summaryFor(DateTime(2026, 12, 28));
      expect(weekMatchesQuery(w, '31/12/2026'), isTrue);
      expect(weekMatchesQuery(w, '01/01/2027'), isTrue);
      expect(weekMatchesQuery(w, '01/01/2026'), isFalse);
    });
  });

  group('backup restore hardening', () {
    late AppDatabase db;

    setUp(() => db = openInMemoryDatabase());
    tearDown(() => db.close());

    test('unknown table names are rejected', () {
      final payload = jsonEncode({
        'format': 'client-tracker-backup',
        'version': 1,
        'tables': {
          'evil': [
            {'id': 1},
          ],
        },
      });
      expect(
        () => db.restoreFromJson(payload),
        returnsNormally,
        reason: 'unknown tables are skipped, not executed',
      );
      // Nothing was written to the real tables.
      expect(db.raw.select('SELECT * FROM staff;'), isEmpty);
    });

    test('unexpected column names are rejected', () {
      final payload = jsonEncode({
        'format': 'client-tracker-backup',
        'version': 1,
        'tables': {
          'staff': [
            {
              // A column name that is not part of the schema allowlist:
              // must never reach SQL interpolation.
              "x'); DROP TABLE staff; --": 'boom',
            },
          ],
        },
      });
      // The row has no valid columns → DatabaseExceptionApp, not a write.
      expect(
        () => db.restoreFromJson(payload),
        throwsA(isA<DatabaseExceptionApp>()),
      );
      // The transaction rolled back: the seeded staff are untouched and the
      // staff table still exists (the injected DROP TABLE never ran).
      expect(db.raw.select('SELECT COUNT(*) AS c FROM staff;').first['c'], 14);
    });

    test('valid columns still restore (legit backups unaffected)', () {
      final staffRow = {
        'id': 1,
        'name': 'Ada',
        'active': 1,
        'display_order': 0,
        'created_at': '2026-01-01T00:00:00.000',
      };
      final payload = jsonEncode({
        'format': 'client-tracker-backup',
        'version': 1,
        'tables': {
          'staff': [staffRow],
        },
      });
      db.restoreFromJson(payload);
      expect(db.raw.select('SELECT name FROM staff;').first['name'], 'Ada');
    });
  });

  group('utf-8 backup payload', () {
    test('json with non-ascii names survives codeUnit-free encoding', () {
      // The Settings screen now writes utf8.encode(json) and reads
      // utf8.decode(bytes). Verify the roundtrip on a tricky payload.
      final doc = {
        'format': 'client-tracker-backup',
        'tables': {
          'staff': [
            {'name': 'René Ω 日本語'},
          ],
        },
      };
      final json = const JsonEncoder.withIndent('  ').convert(doc);
      final bytes = utf8.encode(json);
      final decoded = utf8.decode(bytes) == json;
      expect(decoded, isTrue);
      // The old codeUnit path would mangle this: each code unit > 127
      // becomes one truncated byte. Document the difference:
      expect(
        utf8.encode(json).length,
        greaterThan(json.codeUnits.length),
      ); // true for non-ASCII
    });
  });

  group('automatic backups', () {
    test('a backup folder keeps the newest 30 files', () async {
      final dir = await Directory.systemTemp.createTemp('ct_backup_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = createAutoBackupStore(
        databaseFile: '${dir.path}/client_tracker.db',
        folder: '${dir.path}/auto',
      );
      expect(store.enabled, isTrue);
      for (var i = 0; i < 33; i++) {
        await store.save(
          'client_tracker_backup_${i.toString().padLeft(3, '0')}.json',
          '{"n": $i}',
        );
      }
      final entries = await store.list();
      expect(entries.length, 30, reason: 'older backups must be pruned');
      expect(await store.read(entries.first.id), startsWith('{"n"'));
      // Nothing outside the backup folder can be read through it.
      expect(await store.read('${dir.path}/client_tracker.db'), isNull);
    });

    test('in-memory data (tests) never writes backup files', () {
      final store = createAutoBackupStore(databaseFile: ':memory:');
      expect(store.enabled, isFalse);
    });
  });
}
