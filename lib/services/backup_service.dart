import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';

/// Result of a backup operation.
class BackupResult {
  BackupResult({
    required this.json,
    required this.suggestedName,
    required this.createdAt,
  });

  final String json;
  final String suggestedName;
  final DateTime createdAt;
}

/// Creates and restores portable JSON backups containing all staff, weeks and
/// client counts. A backup is a single human-readable file that can be moved
/// to another computer (or re-imported in the browser).
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  /// Produces a backup payload with a suggested file name.
  BackupResult backup() {
    // Millisecond precision: two backups in the same second must not
    // overwrite each other.
    final stamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(DateTime.now());
    return BackupResult(
      json: _db.exportToJson(),
      suggestedName: 'client_tracker_backup_$stamp.json',
      createdAt: DateTime.now(),
    );
  }

  /// Restores the given backup JSON, replacing all current data. On io
  /// platforms the current data is first written to
  /// `before_restore_<timestamp>.json` next to the database so nothing can be
  /// silently lost.
  /// The current data as JSON: the safety copy the web saves itself
  /// (there is no folder to write it to there).
  String currentJson() => _db.exportToJson();

  void restoreJson(String json) {
    if (!kIsWeb) {
      try {
        final dbFolder = p.dirname(_db.file);
        if (!p.equals(_db.file, ':memory:')) {
          File(
            p.join(
              dbFolder,
              'before_restore_${DateTime.now().millisecondsSinceEpoch}.json',
            ),
          ).writeAsStringSync(_db.exportToJson());
          // Only the latest few are kept.
          final old =
              Directory(dbFolder)
                  .listSync()
                  .whereType<File>()
                  .where(
                    (f) =>
                        RegExp(r'^before_restore_\d+\.json$')
                            .hasMatch(p.basename(f.path)),
                  )
                  .toList()
                ..sort((a, b) => b.path.compareTo(a.path));
          for (final f in old.skip(5)) {
            f.deleteSync();
          }
        }
      } catch (_) {
        // Safety copy is best effort.
      }
    }
    _db.restoreFromJson(json);
  }
}
