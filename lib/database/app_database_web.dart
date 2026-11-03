import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqlite3/wasm.dart';

import 'database.dart';

/// Opens the SQLite database on the web: the sqlite3 WASM module is fetched
/// from the app's `web/` folder and the database file persists in IndexedDB,
/// so entries survive closing the tab. Exposed through a conditional import
/// in `database_bootstrap.dart`.
Future<AppDatabase> openPlatformDatabase(String directory) async {
  assert(kIsWeb);

  final fs = await IndexedDbFileSystem.open(dbName: 'client_tracker_db');
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));

  sqlite.registerVirtualFileSystem(fs, makeDefault: true);

  const dbPath = '/client_tracker.db';
  final raw = sqlite.open(dbPath);
  raw.execute('PRAGMA foreign_keys = ON;');
  AppDatabase.migrate(raw);
  AppDatabase.seedStaff(raw);

  // IndexedDB writes are asynchronous and flushed continuously; a failure to
  // persist is surfaced by the browser, not by sqlite3 here.
  return AppDatabase.internal(dbPath, raw);
}

/// True: the browser build stores its database in IndexedDB.
bool get isWebDatabase => true;
