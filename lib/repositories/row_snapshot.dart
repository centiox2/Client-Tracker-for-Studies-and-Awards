import '../database/database.dart';

/// A copy of some rows taken just before a delete, so the delete can be
/// undone: [restore] writes them back with their ids, in the order they were
/// taken (parents first). Restored rows sync like any other change.
class RowSnapshot {
  RowSnapshot._(this._rows);

  final List<(String, List<Map<String, Object?>>)> _rows;

  /// [parts] are (table, `WHERE` clause, arguments), parents first.
  static RowSnapshot take(
    AppDatabase db,
    List<(String, String, List<Object?>)> parts,
  ) => RowSnapshot._([
    for (final (table, where, args) in parts)
      (
        table,
        [
          for (final r in db.raw.select(
            'SELECT * FROM $table WHERE $where;',
            args,
          ))
            {for (final k in r.keys) k: r[k]},
        ],
      ),
  ]);

  int get rowCount => _rows.fold(0, (n, p) => n + p.$2.length);

  void restore(AppDatabase db) => db.transaction(() {
    for (final (table, rows) in _rows) {
      for (final row in rows) {
        final cols = row.keys.toList();
        db.raw.execute(
          'INSERT OR REPLACE INTO $table (${cols.join(', ')}) '
          'VALUES (${List.filled(cols.length, '?').join(', ')});',
          [for (final c in cols) row[c]],
        );
      }
    }
  });
}
