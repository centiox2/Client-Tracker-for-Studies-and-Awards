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

/// Rotating file copy: current -> .bak1 -> .bak2 … .bakN.
/// Best-effort: never blocks the app from starting.
void makeRollingBackup(String dbPath) {
  try {
    final f = File(dbPath);
    if (!f.existsSync()) return;
    for (var i = AppDatabase.rollingBackupCount - 1; i >= 1; i--) {
      final src = File('$dbPath.bak$i');
      if (src.existsSync()) {
        src.copySync('$dbPath.bak${i + 1}');
      }
    }
    f.copySync('$dbPath.bak1');
  } catch (_) {
    // ignore - backups are best effort
  }
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
