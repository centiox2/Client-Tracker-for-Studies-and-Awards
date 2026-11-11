import '../database/database.dart';
import '../models/staff.dart';
import 'row_snapshot.dart';
import 'time_off_repository.dart';
import 'week_repository.dart';

/// Data access for staff records.
class StaffRepository {
  StaffRepository(this._db);

  final AppDatabase _db;

  /// All staff, optionally including deactivated ones, ordered by
  /// display_order (then name for stable ties).
  List<Staff> getAll({bool includeInactive = true}) {
    final rows = _db.raw.select(
      'SELECT * FROM staff ${includeInactive ? '' : 'WHERE active = 1'} '
      'ORDER BY display_order, name COLLATE NOCASE;',
    );
    return rows.map(Staff.fromRow).toList();
  }

  /// Active staff only — used when populating a brand-new week.
  List<Staff> getActive() => getAll(includeInactive: false);

  /// Returns the new staff id. [active] false adds a former member (e.g.
  /// from an Excel import) who isn't put on this week's board.
  int add(String name, {bool active = true}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Staff name cannot be empty.');
    }
    final order =
        _db.raw
                .select(
                  'SELECT COALESCE(MAX(display_order), -1) + 1 AS next '
                  'FROM staff;',
                )
                .first['next']!
            as int;
    _db.raw.execute(
      'INSERT INTO staff (id, name, active, display_order, created_at) '
      'VALUES (new_id(), ?, ?, ?, ?);',
      [trimmed, active ? 1 : 0, order, DateTime.now().toIso8601String()],
    );
    final id = _db.raw.lastInsertRowId;
    // Recordable straight away, not only from the next new week.
    if (active) WeekRepository(_db).addStaffToOpenWeeks(id);
    return id;
  }

  void rename(int id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Staff name cannot be empty.');
    }
    _db.raw.execute('UPDATE staff SET name = ? WHERE id = ?;', [trimmed, id]);
  }

  /// Deactivating keeps them on weeks already created (history stays);
  /// reactivating puts them back on this week and any later ones.
  void setActive(int id, bool active) {
    _db.raw.execute('UPDATE staff SET active = ? WHERE id = ?;', [
      active ? 1 : 0,
      id,
    ]);
    if (active) WeekRepository(_db).addStaffToOpenWeeks(id);
  }

  /// Permanently deletes a staff member together with all their client
  /// counts and time-off marks. The UI must confirm before calling this
  /// (and suggests marking them inactive instead, which keeps history).
  ///
  /// Returns what was removed, so the delete can be undone.
  RowSnapshot delete(int id) {
    final snapshot = RowSnapshot.take(_db, [
      ('staff', 'id = ?', [id]),
      ('client_counts', 'staff_id = ?', [id]),
      ('staff_day_off', 'staff_id = ?', [id]),
      ('count_changes', 'staff_id = ?', [id]),
    ]);
    _db.transaction(() {
      TimeOffRepository(_db).deleteForStaff(id);
      _db.raw.execute('DELETE FROM client_counts WHERE staff_id = ?;', [id]);
      _db.raw.execute('DELETE FROM count_changes WHERE staff_id = ?;', [id]);
      _db.raw.execute('DELETE FROM staff WHERE id = ?;', [id]);
    });
    return snapshot;
  }

  /// Persists a full new ordering of staff by id.
  void reorder(List<int> orderedIds) {
    _db.transaction(() {
      for (var i = 0; i < orderedIds.length; i++) {
        _db.raw.execute('UPDATE staff SET display_order = ? WHERE id = ?;', [
          i,
          orderedIds[i],
        ]);
      }
    });
  }
}
