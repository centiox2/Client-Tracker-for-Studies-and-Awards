/// SQLite data layer (package:sqlite3 + sqlite3_flutter_libs).
///
/// Platform bootstrap lives in `app_database_io.dart` (Windows / Android /
/// iOS) and `app_database_web.dart` (browser build), selected by the
/// conditional import in `database_bootstrap.dart`.
///
/// Design notes:
/// - WAL mode for durable, crash-safe writes on io platforms.
/// - `PRAGMA foreign_keys = ON` on every connection.
/// - Totals are never stored; they are derived from `client_counts` rows.
/// - On io platforms, a rotating rolling backup of the database file is made
///   (`client_tracker.db.bak1` … `bak5`, one per app launch) so a corrupt
///   write can never destroy more than the last few sessions.
library;

import 'dart:convert';

import 'package:sqlite3/common.dart' as common;

/// Thrown when the database schema cannot be created or migrated.
class DatabaseExceptionApp implements Exception {
  DatabaseExceptionApp(this.message);
  final String message;

  @override
  String toString() => 'DatabaseExceptionApp: $message';
}

class AppDatabase {
  /// Public so the platform bootstrap files (same package, different
  /// libraries) can construct instances.
  AppDatabase.internal(this.file, this._db) {
    _db.createFunction(
      functionName: 'new_id',
      argumentCount: const common.AllowedArgumentCount(0),
      function: (_) => nextId(),
    );
  }

  static int _lastId = 0;

  /// A new row id that won't clash with one made on another device.
  ///
  /// Each device used to number new rows 1, 2, 3… on its own, so the phone
  /// and the PC could both create "revenue entry 12" before syncing, and
  /// online one silently replaced the other (or, for client numbers, the
  /// upload failed outright). Ids now come from the microsecond clock,
  /// strictly increasing on this device: two devices would have to insert in
  /// the same microsecond to collide. Still below 2^53, so exact everywhere
  /// (including the web build), and still in creation order. Inserts use it
  /// in SQL as `new_id()`.
  static int nextId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _lastId = now > _lastId ? now : _lastId + 1;
    return _lastId;
  }

  final String file;
  final common.CommonDatabase _db;

  static const int schemaVersion = 11;
  static const int rollingBackupCount = 5;

  /// Runs [action] inside a transaction; rolls back on any error.
  /// Inside an outer transaction, [action] simply joins it.
  T transaction<T>(T Function() action) {
    if (!_db.autocommit) return action();
    _db.execute('BEGIN');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  common.CommonDatabase get raw => _db;

  // ---- schema & seed -------------------------------------------------------

  static void migrate(common.CommonDatabase db) {
    db.execute('BEGIN');
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS staff (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          name          TEXT NOT NULL,
          active        INTEGER NOT NULL DEFAULT 1,
          display_order INTEGER NOT NULL DEFAULT 0,
          created_at    TEXT NOT NULL
        );
      ''');

      db.execute('''
        CREATE TABLE IF NOT EXISTS weeks (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          start_date  TEXT NOT NULL UNIQUE,
          end_date    TEXT NOT NULL,
          created_at  TEXT NOT NULL,
          updated_at  TEXT NOT NULL,
          show_zeros  INTEGER NOT NULL DEFAULT 1
        );
      ''');

      db.execute('''
        CREATE TABLE IF NOT EXISTS work_days (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          week_id INTEGER NOT NULL REFERENCES weeks(id) ON DELETE CASCADE,
          date    TEXT NOT NULL UNIQUE,
          weekday INTEGER NOT NULL
        );
      ''');

      db.execute('''
        CREATE TABLE IF NOT EXISTS client_counts (
          id               INTEGER PRIMARY KEY AUTOINCREMENT,
          day_id           INTEGER NOT NULL REFERENCES work_days(id) ON DELETE CASCADE,
          staff_id         INTEGER NOT NULL REFERENCES staff(id),
          new_clients      INTEGER NOT NULL DEFAULT 0,
          existing_clients INTEGER NOT NULL DEFAULT 0,
          updated_at       TEXT NOT NULL,
          UNIQUE(day_id, staff_id)
        );
      ''');

      // v2: per-staff time off. One row = a staff member is off on that
      // working day of that week. Numbers already entered for the day are
      // kept but excluded from every total until the mark is removed.
      db.execute('''
        CREATE TABLE IF NOT EXISTS staff_day_off (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          day_id   INTEGER NOT NULL REFERENCES work_days(id) ON DELETE CASCADE,
          staff_id INTEGER NOT NULL REFERENCES staff(id),
          UNIQUE(day_id, staff_id)
        );
      ''');

      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_staff_day_off_day
          ON staff_day_off(day_id);
      ''');

      // v3: per-week show-zeros toggle. SQLite does not support
      // `ADD COLUMN IF NOT EXISTS`, so inspect the existing schema before
      // adding the column. The old try/catch silently left upgraded databases
      // without this column, making the toggle's UPDATE fail at runtime.
      final weekColumns = db.select('PRAGMA table_info(weeks);');
      final hasShowZeros = weekColumns.any(
        (column) => column['name'] == 'show_zeros',
      );
      if (!hasShowZeros) {
        db.execute(
          'ALTER TABLE weeks ADD COLUMN show_zeros INTEGER NOT NULL DEFAULT 1;',
        );
      }

      // v4: the admin login (guards the workspace; Reports need no login).
      // Only a salted PBKDF2 hash is stored. Deliberately excluded from JSON
      // backups so a backup file never carries credentials. The 'boss' role
      // is unused (an earlier design) but kept in the CHECK so existing
      // databases stay valid.
      db.execute('''
        CREATE TABLE IF NOT EXISTS app_accounts (
          role          TEXT PRIMARY KEY CHECK (role IN ('admin', 'boss')),
          password_hash TEXT NOT NULL,
          salt          TEXT NOT NULL,
          updated_at    TEXT NOT NULL
        );
      ''');

      // v5: a short note per working day ("System down 2–4pm"), shown in
      // the tracker and Reports; and simple app-wide settings (e.g. the
      // daily client target). Both travel with backups.
      db.execute('''
        CREATE TABLE IF NOT EXISTS day_notes (
          day_id     INTEGER PRIMARY KEY REFERENCES work_days(id) ON DELETE CASCADE,
          note       TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');

      // v6: change history — every edit to a client number, with the value
      // before and after. Quick re-edits of one cell are merged (see
      // ClientCountRepository.saveCount), so typing "12" is one change.
      db.execute('''
        CREATE TABLE IF NOT EXISTS count_changes (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          day_id       INTEGER NOT NULL REFERENCES work_days(id) ON DELETE CASCADE,
          staff_id     INTEGER NOT NULL,
          old_new      INTEGER NOT NULL,
          old_existing INTEGER NOT NULL,
          new_new      INTEGER NOT NULL,
          new_existing INTEGER NOT NULL,
          changed_at   TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_count_changes_at
          ON count_changes(changed_at);
      ''');

      // v8: revenue — one row per transaction (e.g. from a WhatsApp
      // payment photo). Keyed by calendar date, not working day, so money
      // received on any day counts. Amounts are whole cents to avoid
      // rounding; daily totals are derived, never stored.
      db.execute('''
        CREATE TABLE IF NOT EXISTS revenue_entries (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          date         TEXT NOT NULL,
          amount_cents INTEGER NOT NULL,
          note         TEXT NOT NULL DEFAULT '',
          created_at   TEXT NOT NULL,
          updated_at   TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_revenue_entries_date
          ON revenue_entries(date);
      ''');

      // v9: what a payment was for ("Application fee"), and the revenue
      // change history (added / edited / deleted / restored, by which
      // device). A refund is simply a negative amount.
      final revenueColumns = db.select('PRAGMA table_info(revenue_entries);');
      if (!revenueColumns.any((c) => c['name'] == 'purpose')) {
        db.execute('ALTER TABLE revenue_entries ADD COLUMN purpose TEXT;');
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS revenue_changes (
          id               INTEGER PRIMARY KEY AUTOINCREMENT,
          entry_id         INTEGER NOT NULL,
          action           TEXT NOT NULL,
          amount_cents     INTEGER NOT NULL,
          date             TEXT NOT NULL,
          note             TEXT NOT NULL DEFAULT '',
          old_amount_cents INTEGER,
          old_date         TEXT,
          old_note         TEXT,
          device           TEXT NOT NULL DEFAULT '',
          changed_at       TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_revenue_changes_at
          ON revenue_changes(changed_at);
      ''');

      // v10: passwords for the Admin team, Director and Team profiles, as
      // the admin set them (or open: locked = 0). Kept on the device so a
      // locked profile still opens offline; like app_accounts, never synced
      // or put in backups. A locked row without a hash: locked online, but
      // not yet opened on this device.
      db.execute('''
        CREATE TABLE IF NOT EXISTS profile_passwords (
          role          TEXT PRIMARY KEY,
          locked        INTEGER NOT NULL DEFAULT 0,
          password_hash TEXT,
          salt          TEXT,
          updated_at    TEXT NOT NULL
        );
      ''');
      // v11: "Keep me signed in on this device" for a profile, with the
      // password's online version then (a newer one asks again).
      final profileColumns = db.select('PRAGMA table_info(profile_passwords);');
      if (!profileColumns.any((c) => c['name'] == 'stay_signed_in')) {
        db.execute(
          'ALTER TABLE profile_passwords '
          'ADD COLUMN stay_signed_in INTEGER NOT NULL DEFAULT 0;',
        );
        db.execute('ALTER TABLE profile_passwords ADD COLUMN version TEXT;');
      }

      _createSyncTables(db);

      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_work_days_week
          ON work_days(week_id);
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_client_counts_day
          ON client_counts(day_id);
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS idx_client_counts_staff
          ON client_counts(staff_id);
      ''');

      db.execute('PRAGMA user_version = $schemaVersion;');
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      throw DatabaseExceptionApp('Schema migration failed: $e');
    }
  }

  // ---- Online sync (Supabase) --------------------------------------------

  /// The tables that sync online, parents first, with their primary key.
  /// (The admin password, `app_accounts`, never leaves the device.)
  static const syncedTables = <String, String>{
    'staff': 'id',
    'weeks': 'id',
    'work_days': 'id',
    'client_counts': 'id',
    'staff_day_off': 'id',
    'day_notes': 'day_id',
    'app_settings': 'key',
    'count_changes': 'id',
    'revenue_entries': 'id',
    'revenue_changes': 'id',
  };

  /// v7: every change to a synced row is noted in `sync_outbox` by a
  /// trigger, so nothing can be missed, whichever screen made it. Changes
  /// arriving *from* the cloud are applied with `sync_state.applying = 1`,
  /// which the triggers skip (no echo back).
  static void _createSyncTables(common.CommonDatabase db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        tbl TEXT NOT NULL,
        pk  TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      );
    ''');
    db.execute(
      "INSERT OR IGNORE INTO sync_state (k, v) VALUES ('applying', '0');",
    );
    const skip = "(SELECT v FROM sync_state WHERE k = 'applying') = '0'";
    for (final MapEntry(key: table, value: pk) in syncedTables.entries) {
      for (final (op, row) in [
        ('INSERT', 'NEW'),
        ('UPDATE', 'NEW'),
        ('DELETE', 'OLD'),
      ]) {
        db.execute('''
          CREATE TRIGGER IF NOT EXISTS sync_${table}_${op.toLowerCase()}
          AFTER $op ON $table WHEN $skip
          BEGIN
            INSERT INTO sync_outbox (tbl, pk) VALUES ('$table', $row.$pk);
          END;
        ''');
      }
    }
  }

  /// Runs [action] without recording its changes for upload (they came from
  /// the cloud).
  T applyingRemote<T>(T Function() action) {
    _db.execute("UPDATE sync_state SET v = '1' WHERE k = 'applying';");
    try {
      return action();
    } finally {
      _db.execute("UPDATE sync_state SET v = '0' WHERE k = 'applying';");
    }
  }

  /// First-launch convenience only: seeds the current spreadsheet's staff so
  /// the app is immediately usable. These are editable records, not constants.
  static void seedStaff(common.CommonDatabase db) {
    final existing = db.select('SELECT COUNT(*) AS c FROM staff;');
    if (existing.first['c']! as int > 0) return;

    const seed = [
      'Beatrice',
      'Collins',
      'Dennis',
      'Ian',
      'Joy',
      'Joyner',
      'Whitney',
      'Rhab',
      'Talaam',
      'Winne',
      'Karren',
      'Director/Eve',
      'Canisius Yego',
      'Cinthia',
    ];
    final now = DateTime.now().toIso8601String();
    final stmt = db.prepare(
      'INSERT INTO staff (name, active, display_order, created_at) '
      'VALUES (?, 1, ?, ?);',
    );
    db.execute('BEGIN');
    try {
      for (var i = 0; i < seed.length; i++) {
        stmt.execute([seed[i], i, now]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.dispose();
    }
  }

  // ---- Backup / restore ---------------------------------------------------

  /// Export of the full logical database contents as JSON (portable across
  /// machines and browsers, and across schema versions better than raw
  /// database files).
  String exportToJson() {
    List<Map<String, Object?>> dump(String sql) =>
        _db.select(sql).map(_rowToJson).toList();
    final tables = <String, List<Map<String, Object?>>>{
      'staff': dump('SELECT * FROM staff ORDER BY id;'),
      'weeks': dump('SELECT * FROM weeks ORDER BY id;'),
      'work_days': dump('SELECT * FROM work_days ORDER BY id;'),
      'client_counts': dump('SELECT * FROM client_counts ORDER BY id;'),
      'staff_day_off': dump('SELECT * FROM staff_day_off ORDER BY id;'),
      'day_notes': dump('SELECT * FROM day_notes ORDER BY day_id;'),
      'app_settings': dump('SELECT * FROM app_settings ORDER BY key;'),
      'count_changes': dump('SELECT * FROM count_changes ORDER BY id;'),
      'revenue_entries': dump('SELECT * FROM revenue_entries ORDER BY id;'),
      'revenue_changes': dump('SELECT * FROM revenue_changes ORDER BY id;'),
    };
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'client-tracker-backup',
      'version': schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'tables': tables,
    });
  }

  /// Replaces all data with the contents of a JSON backup. Rows keep their
  /// original IDs so cross-references stay intact.
  ///
  /// Table and column names come from the (potentially untrusted) backup
  /// file, so they are validated against this allowlist before being
  /// interpolated into SQL.
  static const Map<String, Set<String>> _restorableColumns = {
    'staff': {'id', 'name', 'active', 'display_order', 'created_at'},
    'weeks': {
      'id',
      'start_date',
      'end_date',
      'created_at',
      'updated_at',
      'show_zeros',
    },
    'work_days': {'id', 'week_id', 'date', 'weekday'},
    'client_counts': {
      'id',
      'day_id',
      'staff_id',
      'new_clients',
      'existing_clients',
      'updated_at',
    },
    'staff_day_off': {'id', 'day_id', 'staff_id'},
    'day_notes': {'day_id', 'note', 'updated_at'},
    'app_settings': {'key', 'value'},
    'count_changes': {
      'id',
      'day_id',
      'staff_id',
      'old_new',
      'old_existing',
      'new_new',
      'new_existing',
      'changed_at',
    },
    'revenue_entries': {
      'id',
      'date',
      'amount_cents',
      'note',
      'created_at',
      'updated_at',
      'purpose',
    },
    'revenue_changes': {
      'id',
      'entry_id',
      'action',
      'amount_cents',
      'date',
      'note',
      'old_amount_cents',
      'old_date',
      'old_note',
      'device',
      'changed_at',
    },
  };

  void restoreFromJson(String json) {
    final Map<String, Object?> doc;
    try {
      doc = jsonDecode(json) as Map<String, Object?>;
    } catch (e) {
      throw DatabaseExceptionApp('Backup file is not valid JSON: $e');
    }
    if (doc['format'] != 'client-tracker-backup') {
      throw DatabaseExceptionApp('Not a Client Tracker backup file.');
    }
    final tables = doc['tables'];
    if (tables is! Map<String, Object?>) {
      throw DatabaseExceptionApp('Backup is missing table data.');
    }

    transaction(() {
      // Older backups (before v8) carry no revenue — keep what's here.
      if (tables['revenue_entries'] is List) {
        _db.execute('DELETE FROM revenue_entries;');
      }
      if (tables['revenue_changes'] is List) {
        _db.execute('DELETE FROM revenue_changes;');
      }
      _db.execute('DELETE FROM count_changes;');
      _db.execute('DELETE FROM day_notes;');
      // Older backups (before v5) carry no settings — keep the current ones
      // (e.g. the daily target) rather than wiping them.
      if (tables['app_settings'] is List) {
        _db.execute('DELETE FROM app_settings;');
      }
      _db.execute('DELETE FROM staff_day_off;');
      _db.execute('DELETE FROM client_counts;');
      _db.execute('DELETE FROM work_days;');
      _db.execute('DELETE FROM weeks;');
      _db.execute('DELETE FROM staff;');
      const order = [
        'staff',
        'weeks',
        'work_days',
        'client_counts',
        'staff_day_off',
        'day_notes',
        'app_settings',
        'count_changes',
        'revenue_entries',
        'revenue_changes',
      ];
      for (final name in order) {
        final rows = tables[name];
        if (rows is! List) continue;
        final allowed = _restorableColumns[name]!;
        for (final row in rows) {
          final map = (row as Map).cast<String, Object?>();
          final cols = map.keys.where((c) => allowed.contains(c)).toList();
          if (cols.isEmpty) {
            throw DatabaseExceptionApp(
              'Backup row for "$name" has no valid columns.',
            );
          }
          final placeholders = List.filled(cols.length, '?').join(', ');
          _db.execute(
            'INSERT INTO $name (${cols.join(', ')}) VALUES ($placeholders);',
            [for (final c in cols) map[c]],
          );
        }
        // Only AUTOINCREMENT tables (those with an `id`) have a sequence;
        // day_notes and app_settings are keyed differently.
        if (!allowed.contains('id')) continue;
        _db.execute('DELETE FROM sqlite_sequence WHERE name = ?;', [name]);
        _db.execute(
          'INSERT INTO sqlite_sequence(name, seq) '
          "SELECT ?, COALESCE(MAX(id), 0) FROM $name;",
          [name],
        );
      }
    });
  }

  static Map<String, Object?> _rowToJson(common.Row row) => {
    for (final col in row.keys) col: row[col],
  };

  void close() => _db.dispose();
}
