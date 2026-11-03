import '../database/database.dart';

/// Short notes on working days ("System down 2–4pm", "Outreach day"), so
/// Reports can explain why a day was unusually low or high.
class DayNotesRepository {
  DayNotesRepository(this._db);

  final AppDatabase _db;

  static const int maxLength = 200;

  String? noteFor(int dayId) {
    final rows = _db.raw.select(
      'SELECT note FROM day_notes WHERE day_id = ?;',
      [dayId],
    );
    return rows.isEmpty ? null : rows.first['note']! as String;
  }

  /// Notes for every day of a week, keyed by day id.
  Map<int, String> notesForWeek(int weekId) => {
    for (final r in _db.raw.select(
      '''
      SELECT dn.day_id AS day_id, dn.note AS note
      FROM day_notes dn JOIN work_days wd ON wd.id = dn.day_id
      WHERE wd.week_id = ?;
    ''',
      [weekId],
    ))
      r['day_id']! as int: r['note']! as String,
  };

  /// Saves the note; blank text removes it.
  void setNote(int dayId, String note) {
    final text = note.trim();
    if (text.isEmpty) {
      _db.raw.execute('DELETE FROM day_notes WHERE day_id = ?;', [dayId]);
      return;
    }
    _db.raw.execute(
      'INSERT INTO day_notes (day_id, note, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(day_id) DO UPDATE SET note = excluded.note, '
      'updated_at = excluded.updated_at;',
      [
        dayId,
        text.length > maxLength ? text.substring(0, maxLength) : text,
        DateTime.now().toIso8601String(),
      ],
    );
  }
}

/// Simple app-wide settings stored in the database (so they travel with
/// backups), e.g. the daily client target.
class AppSettingsRepository {
  AppSettingsRepository(this._db);

  final AppDatabase _db;

  static const _dailyTargetKey = 'daily_target';

  /// Clients per day the team aims for; null when no target is set.
  int? get dailyTarget {
    final rows = _db.raw.select(
      'SELECT value FROM app_settings WHERE key = ?;',
      [_dailyTargetKey],
    );
    if (rows.isEmpty) return null;
    final v = int.tryParse(rows.first['value']! as String);
    return v == null || v <= 0 ? null : v;
  }

  /// Sets the daily target; null or 0 clears it.
  set dailyTarget(int? value) {
    if (value == null || value <= 0) {
      _db.raw.execute('DELETE FROM app_settings WHERE key = ?;', [
        _dailyTargetKey,
      ]);
      return;
    }
    _db.raw.execute(
      'INSERT INTO app_settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      [_dailyTargetKey, '$value'],
    );
  }

  static const _currencyKey = 'currency';

  /// Shown before revenue amounts. Kenyan shillings unless changed.
  static const defaultCurrency = 'KSh';

  String get currency {
    final rows = _db.raw.select(
      'SELECT value FROM app_settings WHERE key = ?;',
      [_currencyKey],
    );
    final v = rows.isEmpty ? '' : (rows.first['value']! as String).trim();
    return v.isEmpty ? defaultCurrency : v;
  }

  set currency(String value) {
    final v = value.trim();
    if (v.isEmpty || v == defaultCurrency) {
      _db.raw.execute('DELETE FROM app_settings WHERE key = ?;', [
        _currencyKey,
      ]);
      return;
    }
    _db.raw.execute(
      'INSERT INTO app_settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      [_currencyKey, v.length > 8 ? v.substring(0, 8) : v],
    );
  }
}
