import 'dart:async';
import 'dart:collection';
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
/// - **downloads again** when another device signals a change.
///
/// Rules that keep data safe:
/// - While a device is joined, local edits not yet sent go up before any
///   download, so cloud data never overwrites them.
/// - A device joins ("connects") once: if the cloud already has data, it
///   replaces this device's data; if the cloud is empty, the first admin
///   device uploads everything it has. That join, and "Download fresh
///   copy", are the two moments cloud data replaces edits that weren't
///   sent: they are then kept whole as a recovery copy ([recovery]) to
///   save or restore, never silently dropped.
/// - A change the online database refuses on its own is set aside with
///   the reason ([heldBack]) so it can't block everything after it.
/// - Uploads go one at a time (and never alongside a download), so an
///   older upload can't land after a newer one.
class SyncEngine {
  SyncEngine(this._db, this._api);

  final AppDatabase _db;
  final CloudApi _api;

  static const _connectedKey = 'connected';
  static const _recoveryKey = 'recovery_json';
  static const _recoveryAtKey = 'recovery_at';

  /// One upload or download at a time: when one is running, the next
  /// waits its turn; when none is, it starts straight away.
  bool _busy = false;
  final _waiting = Queue<Completer<void>>();

  Future<T> _serial<T>(Future<T> Function() action) async {
    if (_busy) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _busy = true;
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _busy = false;
      }
    }
  }

  /// This device's data as it was before cloud data replaced unsent work
  /// (a backup file's contents), and when; null when there is none.
  ({String json, DateTime at})? get recovery {
    final json = _state(_recoveryKey);
    if (json == null || json.isEmpty) return null;
    return (
      json: json,
      at: DateTime.tryParse(_state(_recoveryAtKey) ?? '') ?? DateTime.now(),
    );
  }

  /// The recovery copy has been saved elsewhere or isn't wanted.
  void clearRecovery() {
    _db.raw.execute('DELETE FROM sync_state WHERE k IN (?, ?);', [
      _recoveryKey,
      _recoveryAtKey,
    ]);
  }

  /// Keeps this device's data before it is replaced while changes are
  /// still waiting to be sent (only the newest such copy is kept).
  void _keepRecovery() {
    if (pending == 0 || !_hasWork()) return;
    _setState(_recoveryKey, _db.exportToJson());
    _setState(_recoveryAtKey, DateTime.now().toIso8601String());
  }

  /// Waiting changes that are more than the first-launch staff list.
  bool _hasWork() =>
      _db.raw
          .select("SELECT 1 FROM sync_outbox WHERE tbl <> 'staff' LIMIT 1;")
          .isNotEmpty ||
      _db.raw
          .select(
            "SELECT 1 FROM sync_outbox o WHERE o.tbl = 'staff' AND NOT EXISTS "
            "(SELECT 1 FROM sync_state WHERE k = 'staff_seeded') LIMIT 1;",
          )
          .isNotEmpty;

  bool get connected => _state(_connectedKey) == '1';

  /// Local changes waiting to be sent.
  int get pending =>
      _db.raw.select('SELECT COUNT(*) AS c FROM sync_outbox;').first['c']!
          as int;

  /// Downloads the cloud's data (read with the profile's [readToken]) and
  /// brings this device up to date. [token] (devices that edit) lets
  /// waiting local changes go up first. Returns true when local data
  /// changed.
  Future<bool> pull({String? token, required String readToken}) =>
      _serial(() => _pull(token: token, readToken: readToken));

  Future<bool> _pull({String? token, required String readToken}) async {
    if (connected && pending > 0) {
      if (token == null) {
        // Can't send them yet; keep them, and take live updates only.
        return false;
      }
      await _flush(token);
    }
    final seqBefore = _lastSeq();
    final snap = await _api.snapshot(readToken);
    // Edited while downloading: those edits go up first (the next pull
    // brings everything), rather than being overwritten here.
    if (_lastSeq() != seqBefore) return false;
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
    // Joining for the first time with changes made here offline: the
    // cloud's data is the team's, but this device's work is kept.
    if (!connected) _keepRecovery();
    _replaceLocal(snap);
    _setState(_connectedKey, '1');
    return true;
  }

  /// Sends waiting local changes. Returns how many rows went up.
  Future<int> flush(String token) => _serial(() => _flush(token));

  /// Refusals about the sign-in or the app's version, not one change: the
  /// whole queue waits for those.
  static const _waitCodes = {'not_signed_in', 'needs_update'};

  Future<int> _flush(String token) async {
    final entries = _db.raw.select(
      'SELECT seq, tbl, pk FROM sync_outbox ORDER BY seq;',
    );
    if (entries.isEmpty) return 0;
    final maxSeq = entries.last['seq']! as int;
    final waiting = <String, Set<String>>{};
    for (final e in entries) {
      waiting
          .putIfAbsent(e['tbl']! as String, () => {})
          .add(e['pk']! as String);
    }
    // Parents before children for new rows; children before parents for
    // deletes (the order the online database checks them in).
    final changes = <_Change>[];
    final deletes = <_Change>[];
    for (final MapEntry(key: table, value: pkCol)
        in AppDatabase.syncedTables.entries) {
      for (final pk in waiting[table] ?? const <String>{}) {
        final row = _readRow(table, pkCol, pk);
        (row == null ? deletes : changes).add(_Change(table, pkCol, pk, row));
      }
    }
    changes.addAll(deletes.reversed);
    try {
      await _api.push(token, _payload(changes));
    } on CloudException catch (e) {
      if (_waitCodes.contains(e.code)) rethrow;
      // Refused: find which change it was, one at a time, so one bad row
      // can't hold up everything else. The ones refused on their own are
      // set aside ([heldBack]); the rest go up.
      return _sendOneByOne(token, changes, maxSeq);
    }
    // Only what was sent; anything edited meanwhile stays queued.
    _db.raw.execute('DELETE FROM sync_outbox WHERE seq <= ?;', [maxSeq]);
    if (!connected) _setState(_connectedKey, '1');
    return changes.length;
  }

  Future<int> _sendOneByOne(
    String token,
    List<_Change> changes,
    int maxSeq,
  ) async {
    var sent = 0;
    void done(_Change c) => _db.raw.execute(
      'DELETE FROM sync_outbox WHERE seq <= ? AND tbl = ? AND pk = ?;',
      [maxSeq, c.table, c.pk],
    );
    for (final c in changes) {
      try {
        await _api.push(token, _payload([c]));
        sent++;
      } on CloudException catch (e) {
        if (_waitCodes.contains(e.code)) rethrow;
        _holdBack(c, e);
      }
      // Sent, or set aside: either way it no longer blocks the queue. A
      // lost connection part-way keeps the rest queued (thrown above).
      done(c);
    }
    return sent;
  }

  Map<String, Object?> _payload(List<_Change> changes) {
    final upserts = <String, List<Map<String, Object?>>>{};
    final deletes = <String, List<Object?>>{};
    for (final c in changes) {
      if (c.row == null) {
        deletes.putIfAbsent(c.table, () => []).add(_key(c.pkCol, c.pk));
      } else {
        upserts.putIfAbsent(c.table, () => []).add(c.row!);
      }
    }
    return {'upserts': upserts, 'deletes': deletes};
  }

  /// The row as it is now, or null when it has been deleted. Compared
  /// without a cast, so the primary key's index is used.
  Map<String, Object?>? _readRow(String table, String pkCol, String pk) {
    final key = _keyOrNull(pkCol, pk);
    if (key == null) return null;
    final rows = _db.raw.select('SELECT * FROM $table WHERE $pkCol = ?;', [
      key,
    ]);
    return rows.isEmpty ? null : _row(rows.first);
  }

  // ---- Changes the online database refused --------------------------------

  static const _heldBackKey = 'held_back';

  /// Changes the online database refused on their own (newest last): kept
  /// here, with the reason, until they are sent again or discarded.
  List<HeldBackChange> get heldBack {
    final raw = _state(_heldBackKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          HeldBackChange.fromJson((j as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _holdBack(_Change c, CloudException e) {
    final list = [
      for (final h in heldBack)
        if (h.table != c.table || h.pk != c.pk) h,
      HeldBackChange(
        table: c.table,
        pk: c.pk,
        row: c.row,
        reason: e.code,
        detail: e.detail,
        at: DateTime.now().toUtc(),
      ),
    ];
    // A runaway list never grows without end: the oldest go first.
    final kept = list.length > 500 ? list.sublist(list.length - 500) : list;
    _setState(_heldBackKey, jsonEncode([for (final h in kept) h.toJson()]));
  }

  /// Puts the set-aside changes back as they were and queues them to be
  /// sent again (after, say, the admin fixed what was wrong).
  void retryHeldBack() {
    final list = heldBack;
    if (list.isEmpty) return;
    _db.transaction(() {
      for (final h in list) {
        final pkCol = AppDatabase.syncedTables[h.table];
        if (pkCol == null) continue;
        final key = _keyOrNull(pkCol, h.pk);
        if (key == null) continue;
        final row = h.row;
        if (row == null) {
          _db.raw.execute('DELETE FROM ${h.table} WHERE $pkCol = ?;', [key]);
        } else {
          final cols = _columns(h.table).where(row.containsKey).toList();
          final updates = [
            for (final c in cols)
              if (c != pkCol) '$c = excluded.$c',
          ].join(', ');
          _db.raw.execute(
            'INSERT INTO ${h.table} (${cols.join(', ')}) '
            'VALUES (${List.filled(cols.length, '?').join(', ')}) '
            'ON CONFLICT($pkCol) DO '
            '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET $updates'};',
            [for (final c in cols) row[c]],
          );
        }
        // Queued again even if nothing changed here.
        _db.raw.execute('INSERT INTO sync_outbox (tbl, pk) VALUES (?, ?);', [
          h.table,
          h.pk,
        ]);
      }
      clearHeldBack();
    });
  }

  void clearHeldBack() =>
      _db.raw.execute('DELETE FROM sync_state WHERE k = ?;', [_heldBackKey]);

  /// Takes the cloud's data as it is in place of waiting local changes —
  /// the way out if a change can't be sent. Nothing changes here until the
  /// cloud's data has arrived, and what was waiting is kept as the
  /// recovery copy. False (and nothing changed) when the cloud has no data.
  Future<bool> resetFromCloud(String readToken) => _serial(() async {
    final snap = await _api.snapshot(readToken);
    if (snap.values.every((rows) => rows.isEmpty)) return false;
    _keepRecovery();
    _replaceLocal(snap);
    _setState(_connectedKey, '1');
    return true;
  });

  // ---------------------------------------------------------------------

  Future<void> _uploadAll(String token) async {
    final upserts = <String, List<Map<String, Object?>>>{};
    for (final table in AppDatabase.syncedTables.keys) {
      upserts[table] = [
        for (final r in _db.raw.select('SELECT * FROM $table;')) _row(r),
      ];
    }
    final maxSeq = _lastSeq();
    await _api.push(token, {'upserts': upserts, 'deletes': {}});
    // Sent: only now are the waiting notes done with (edits made meanwhile
    // stay queued).
    _db.raw.execute('DELETE FROM sync_outbox WHERE seq <= ?;', [maxSeq]);
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

  int _lastSeq() =>
      _db.raw.select('SELECT MAX(seq) AS s FROM sync_outbox;').first['s']
          as int? ??
      0;

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

  static Object _key(String pkCol, String pk) => _keyOrNull(pkCol, pk) ?? pk;

  /// The key as stored: text for settings, a number for everything else
  /// (null for a damaged note, which is then skipped, not thrown).
  static Object? _keyOrNull(String pkCol, String pk) =>
      pkCol == 'key' ? pk : int.tryParse(pk);

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

class _Change {
  _Change(this.table, this.pkCol, this.pk, this.row);
  final String table;
  final String pkCol;
  final String pk;

  /// Null: deleted.
  final Map<String, Object?>? row;
}

/// A change the online database refused on its own, set aside so the rest
/// of the queue could go up.
class HeldBackChange {
  const HeldBackChange({
    required this.table,
    required this.pk,
    required this.row,
    required this.reason,
    required this.at,
    this.detail,
  });

  final String table;
  final String pk;

  /// The row as it was sent (null: a delete).
  final Map<String, Object?>? row;
  final String reason;
  final String? detail;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'table': table,
    'pk': pk,
    'row': row,
    'reason': reason,
    'detail': ?detail,
    'at': at.toIso8601String(),
  };

  factory HeldBackChange.fromJson(Map<String, Object?> j) => HeldBackChange(
    table: j['table'] as String,
    pk: '${j['pk']}',
    row: (j['row'] as Map?)?.cast<String, Object?>(),
    reason: j['reason'] as String? ?? 'other',
    detail: j['detail'] as String?,
    at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
  );
}
