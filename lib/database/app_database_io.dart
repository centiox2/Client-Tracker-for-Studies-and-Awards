import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

/// Opens the SQLite database on io platforms (Windows, Android, iOS).
/// Exposed through a conditional import in `database_bootstrap.dart`.
AppDatabase openPlatformDatabase(String directory) {
  Directory(directory).createSync(recursive: true);
  final dbPath = p.join(directory, 'client_tracker.db');

  makeRollingBackup(dbPath);

  final raw = sqlite3.open(dbPath);
  try {
    raw.execute('PRAGMA journal_mode = WAL;');
    raw.execute('PRAGMA foreign_keys = ON;');
    raw.execute('PRAGMA busy_timeout = 5000;');
    AppDatabase.migrate(raw);
    AppDatabase.seedStaff(raw);
    return AppDatabase.internal(dbPath, raw);
  } catch (e) {
    raw.dispose();
    rethrow;
  }
}

/// Rotating copy: current -> .bak1 -> .bak2 … .bakN.
///
/// The copy is made by SQLite itself (`VACUUM INTO`), so it holds every
/// saved change, including those still in the write-ahead log after a
/// crash, and is consistent even if another copy of the app has the file
/// open. Sign-ins kept on this device (online tokens, offline password
/// checks) are taken out of each copy: a backup file must not let anyone
/// sign in as the person. Best-effort: never blocks the app from starting.
void makeRollingBackup(String dbPath) {
  final tmp = '$dbPath.bak.tmp';
  try {
    if (!File(dbPath).existsSync()) return;
    _deleteQuietly(tmp);
    final src = sqlite3.open(dbPath);
    try {
      src.execute('PRAGMA busy_timeout = 5000;');
      src.execute("VACUUM INTO '${tmp.replaceAll("'", "''")}';");
    } finally {
      src.dispose();
    }
    if (!scrubSignIns(tmp)) {
      _deleteQuietly(tmp);
      return;
    }
    for (var i = AppDatabase.rollingBackupCount - 1; i >= 1; i--) {
      final older = File('$dbPath.bak$i');
      if (older.existsSync()) older.copySync('$dbPath.bak${i + 1}');
    }
    File(tmp).copySync('$dbPath.bak1');
    _deleteQuietly(tmp);
    _scrubOldBackups(dbPath);
  } catch (_) {
    _deleteQuietly(tmp);
  }
}

/// Takes the kept sign-ins out of the database file at [path], overwriting
/// them on disk. True when the file holds none afterwards.
bool scrubSignIns(String path) {
  try {
    final db = sqlite3.open(path);
    try {
      final has = db.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'user_signins';",
      );
      if (has.isEmpty) return true;
      db.execute('PRAGMA secure_delete = ON;');
      db.execute('DELETE FROM user_signins;');
      db.execute('VACUUM;');
      return true;
    } finally {
      db.dispose();
    }
  } catch (_) {
    return false;
  }
}

/// Copies made before sign-ins were taken out: cleaned once.
void _scrubOldBackups(String dbPath) {
  final marker = File('$dbPath.bak.clean');
  if (marker.existsSync()) return;
  var all = true;
  for (var i = 2; i <= AppDatabase.rollingBackupCount; i++) {
    final f = File('$dbPath.bak$i');
    if (f.existsSync() && !scrubSignIns(f.path)) all = false;
  }
  if (all) marker.writeAsStringSync('1');
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// In-memory database for tests. Only callable on the VM (dart:io).
AppDatabase openInMemoryDatabase() {
  final raw = sqlite3.openInMemory();
  raw.execute('PRAGMA foreign_keys = ON;');
  AppDatabase.migrate(raw);
  AppDatabase.seedStaff(raw);
  return AppDatabase.internal(':memory:', raw);
}

/// False on io platforms (the file backend is used).
bool get isWebDatabase => false;
