import 'dart:convert';

import '../../database/database.dart';
import 'cloud_api.dart';

/// Keeps the local database and the online one in step.
///
/// The local database stays the one the screens read (instant, and it works
/// offline). This class:
/// - **sends** local changes (noted in `sync_outbox` by triggers) to the
///   cloud — only with an admin token, since only the admin edits;
/// - **downloads** the cloud's data when a device starts (or reconnects);
/// - **applies** live changes from other devices as they arrive.
///
/// Rules that keep data safe:
/// - Local edits not yet sent are never overwritten by cloud data.
/// - A device joins ("connects") once: if the cloud already has data, it
///   replaces this device's starter data; if the cloud is empty, the first
///   admin device uploads everything it has.
class SyncEngine {
  SyncEngine(this._db, this._api);

  final AppDatabase _db;
  final CloudApi _api;

  static const _connectedKey = 'connected';

  bool get connected => _state(_connectedKey) == '1';

  /// Local changes waiting to be sent.
  int get pending =>
      _db.raw.select('SELECT COUNT(*) AS c FROM sync_outbox;').first['c']!
          as int;

  /// Downloads the cloud's data and brings this device up to date.
  /// [token] (admin devices) lets waiting local changes go up first.
  /// Returns true when local data changed.
  Future<bool> pull({String? token}) async {
    if (connected && pending > 0) {
      if (token == null) {
        // Can't send them yet; keep them, and take live updates only.
        return false;
      }
      await flush(token);
    }
    final snap = await _api.snapshot();
    final remoteEmpty = snap.values.every((rows) => rows.isEmpty);
    final localEmpty = _localIsEmpty();

    if (remoteEmpty) {
      // The cloud is new (or was emptied): the admin's device seeds it.
      if (token != null && !localEmpty) {
        await _uploadAll(token);
        _setState(_connectedKey, '1');
      }
      return false;
    }
    _replaceLocal(snap);
    _setState(_connectedKey, '1');
    return true;
  }

  /// Sends waiting local changes. Returns how many rows went up.
  Future<int> flush(String token) async {
    final entries = _db.raw.select(
      'SELECT seq, tbl, pk FROM sync_outbox ORDER BY seq;',
    );
    if (entries.isEmpty) return 0;
    final maxSeq = entries.last['seq']! as int;
    final keys = <String, Set<String>>{};
    for (final e in entries) {
      keys.putIfAbsent(e['tbl']! as String, () => {}).add(e['pk']! as String);
    }
    final upserts = <String, List<Map<String, Object?>>>{};
    final deletes = <String, List<Object?>>{};
    var count = 0;
    for (final MapEntry(key: table, value: pks) in keys.entries) {
      final pkCol = AppDatabase.syncedTables[table];
      if (pkCol == null) continue;
      for (final pk in pks) {
        final rows = _db.raw.select(
          'SELECT * FROM $table WHERE CAST($pkCol AS TEXT) = ?;',
          [pk],
        );
        if (rows.isEmpty) {
          deletes.putIfAbsent(table, () => []).add(_key(pkCol, pk));
        } else {
          upserts.putIfAbsent(table, () => []).add(_row(rows.first));
        }
        count++;
      }
    }
    await _api.push(token, {'upserts': upserts, 'deletes': deletes});
    // Only what was sent; anything edited meanwhile stays queued.
    _db.raw.execute('DELETE FROM sync_outbox WHERE seq <= ?;', [maxSeq]);
    if (!connected) _setState(_connectedKey, '1');
    return count;
  }

  /// Applies one live change from another device. Returns false when the
  /// change couldn't be applied in place (the caller then pulls everything).
  bool apply(CloudChange change) {
    final pkCol = AppDatabase.syncedTables[change.table];
    if (pkCol == null) return true;
    final pk = change.row[pkCol];
    if (pk == null) return false;
    // This device has newer, unsent edits to the same row: keep them.
    final waiting = _db.raw.select(
      'SELECT 1 FROM sync_outbox WHERE tbl = ? AND pk = ? LIMIT 1;',
      [change.table, '$pk'],
    );
    if (waiting.isNotEmpty) return true;
    try {
      _db.applyingRemote(() {
        if (change.deleted) {
          _db.raw.execute('DELETE FROM ${change.table} WHERE $pkCol = ?;', [
            pk,
          ]);
          return;
        }
        final cols = _columns(change.table);
        final row = {
          for (final c in cols)
            if (change.row.containsKey(c)) c: change.row[c],
        };
        final names = row.keys.toList();
        final updates = names
            .where((c) => c != pkCol)
            .map((c) => '$c = excluded.$c')
            .join(', ');
        _db.raw.execute(
          'INSERT INTO ${change.table} (${names.join(', ')}) '
          'VALUES (${List.filled(names.length, '?').join(', ')}) '
          'ON CONFLICT($pkCol) DO '
          '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET $updates'};',
          [for (final c in names) row[c]],
        );
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drops waiting local changes and takes the cloud's data as it is —
  /// the way out if a change can't be sent.
  Future<void> resetFromCloud() async {
    _db.raw.execute('DELETE FROM sync_outbox;');
    final snap = await _api.snapshot();
    if (snap.values.any((rows) => rows.isNotEmpty)) _replaceLocal(snap);
    _setState(_connectedKey, '1');
  }

  // ---------------------------------------------------------------------

  Future<void> _uploadAll(String token) async {
    final upserts = <String, List<Map<String, Object?>>>{};
    for (final table in AppDatabase.syncedTables.keys) {
      upserts[table] = [
        for (final r in _db.raw.select('SELECT * FROM $table;')) _row(r),
      ];
    }
    _db.raw.execute('DELETE FROM sync_outbox;');
    await _api.push(token, {'upserts': upserts, 'deletes': {}});
  }

  void _replaceLocal(Map<String, List<Map<String, Object?>>> snap) {
    final json = jsonEncode({
      'format': 'client-tracker-backup',
      'version': AppDatabase.schemaVersion,
      'tables': {
        // Only tables the cloud sent: tables it doesn't have yet (an online
        // database set up before they existed) keep their local rows.
        for (final table in AppDatabase.syncedTables.keys)
          if (snap.containsKey(table)) table: snap[table],
      },
    });
    _db.applyingRemote(() => _db.restoreFromJson(json));
    _db.raw.execute('DELETE FROM sync_outbox;');
  }

  /// Nothing worth uploading (the staff list alone counts — it's the team).
  bool _localIsEmpty() => AppDatabase.syncedTables.keys.every(
    (t) => _db.raw.select('SELECT COUNT(*) AS c FROM $t;').first['c'] == 0,
  );

  final _columnCache = <String, List<String>>{};

  List<String> _columns(String table) => _columnCache.putIfAbsent(
    table,
    () => [
      for (final r in _db.raw.select('PRAGMA table_info($table);'))
        r['name']! as String,
    ],
  );

  static Object _key(String pkCol, String pk) =>
      pkCol == 'key' ? pk : int.parse(pk);

  static Map<String, Object?> _row(Map<String, Object?> r) => {
    for (final k in r.keys) k: r[k],
  };

  String? _state(String key) {
    final rows = _db.raw.select('SELECT v FROM sync_state WHERE k = ?;', [key]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  void _setState(String key, String value) => _db.raw.execute(
    'INSERT INTO sync_state (k, v) VALUES (?, ?) '
    'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
    [key, value],
  );
}
