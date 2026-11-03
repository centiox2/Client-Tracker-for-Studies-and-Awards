/// Domain models for the weekly client tracker.
///
/// Dates are stored as ISO-8601 `yyyy-MM-dd` strings in SQLite but are always
/// proper [DateTime] objects inside the app, so the spreadsheet's
/// month/day-swap data-entry bug can never happen here.
library;

/// A staff member. Rows are never hard-coded; they live in the `staff` table.
class Staff {
  const Staff({
    required this.id,
    required this.name,
    required this.active,
    required this.displayOrder,
    required this.createdAt,
  });

  final int id;
  final String name;

  /// Inactive staff keep all historical numbers but are not added to new
  /// weeks.
  final bool active;

  /// Sort key for lists; user can reorder staff.
  final int displayOrder;
  final DateTime createdAt;

  Staff copyWith({
    int? id,
    String? name,
    bool? active,
    int? displayOrder,
    DateTime? createdAt,
  }) {
    return Staff(
      id: id ?? this.id,
      name: name ?? this.name,
      active: active ?? this.active,
      displayOrder: displayOrder ?? this.displayOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'active': active ? 1 : 0,
    'display_order': displayOrder,
    'created_at': createdAt.toIso8601String(),
  };

  factory Staff.fromRow(Map<String, Object?> row) => Staff(
    id: row['id']! as int,
    name: row['name']! as String,
    active: (row['active']! as int) != 0,
    displayOrder: row['display_order']! as int,
    createdAt: DateTime.parse(row['created_at']! as String),
  );

  @override
  String toString() => 'Staff($id, $name, active: $active)';
}

/// A Monday–Friday working week.
class Week {
  const Week({
    required this.id,
    required this.startDate,
    required this.endDate,
    required DateTime this._createdAt,
    required DateTime this._updatedAt,
    this.showZeros = true,
  });

  /// From a database row: the audit timestamps stay as their stored strings
  /// until read (they almost never are), so loading weeks doesn't pay for
  /// parsing them.
  const Week._raw({
    required this.id,
    required this.startDate,
    required this.endDate,
    required String this._createdAt,
    required String this._updatedAt,
    required this.showZeros,
  });

  final int id;

  /// Always a Monday.
  final DateTime startDate;

  /// Always the Friday of the same week.
  final DateTime endDate;

  /// A [DateTime], or the stored ISO string until first read.
  final Object _createdAt;
  final Object _updatedAt;
  DateTime get createdAt => _asDateTime(_createdAt);
  DateTime get updatedAt => _asDateTime(_updatedAt);

  /// When true, everyday day cells in the Week board, mobile view, dashboard
  /// strips, history rows and the Excel export show `0` instead of a blank
  /// placeholder. Stored per week so the user's choice survives a reload.
  final bool showZeros;

  /// Date-only containment (a [DateTime] with a time-of-day, e.g. now,
  /// still counts as "inside" its own day — including the end date itself).
  bool containsDate(DateTime d) {
    final date = DateTime(d.year, d.month, d.day);
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    return !date.isBefore(start) && !date.isAfter(end);
  }

  Week copyWith({DateTime? updatedAt, bool? showZeros}) => Week(
    id: id,
    startDate: startDate,
    endDate: endDate,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    showZeros: showZeros ?? this.showZeros,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'start_date': _dateKey(startDate),
    'end_date': _dateKey(endDate),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'show_zeros': showZeros ? 1 : 0,
  };

  factory Week.fromRow(Map<String, Object?> row) => Week._raw(
    id: row['id']! as int,
    startDate: _parseDateKey(row['start_date']! as String),
    endDate: _parseDateKey(row['end_date']! as String),
    createdAt: row['created_at']! as String,
    updatedAt: row['updated_at']! as String,
    showZeros: (row['show_zeros'] as int? ?? 1) != 0,
  );

  @override
  String toString() =>
      'Week($id, ${_dateKey(startDate)}..${_dateKey(endDate)})';
}

/// One working day inside a week.
class WorkDay {
  const WorkDay({
    required this.id,
    required this.weekId,
    required this.date,
    required this.weekday,
  });

  final int id;
  final int weekId;

  /// Proper date, stored as `yyyy-MM-dd`.
  final DateTime date;

  /// 1 = Monday … 7 = Sunday (DateTime.weekday).
  final int weekday;

  Map<String, Object?> toRow() => {
    'id': id,
    'week_id': weekId,
    'date': _dateKey(date),
    'weekday': weekday,
  };

  factory WorkDay.fromRow(Map<String, Object?> row) => WorkDay(
    id: row['id']! as int,
    weekId: row['week_id']! as int,
    date: _parseDateKey(row['date']! as String),
    weekday: row['weekday']! as int,
  );
}

/// The cumulative New/Existing counts for one staff member on one day.
///
/// Values are *cumulative for the day*: editing 3 → 5 stores 5, not 8.
class ClientCount {
  const ClientCount({
    required this.id,
    required this.dayId,
    required this.staffId,
    required this.newClients,
    required this.existingClients,
    required DateTime this._updatedAt,
  });

  /// From a database row; see [Week._raw] — the timestamp is parsed lazily.
  const ClientCount._raw({
    required this.id,
    required this.dayId,
    required this.staffId,
    required this.newClients,
    required this.existingClients,
    required String this._updatedAt,
  });

  final int id;
  final int dayId;
  final int staffId;
  final int newClients;
  final int existingClients;

  /// A [DateTime], or the stored ISO string until first read.
  final Object _updatedAt;
  DateTime get updatedAt => _asDateTime(_updatedAt);

  int get total => newClients + existingClients;

  ClientCount copyWith({
    int? id,
    int? dayId,
    int? staffId,
    int? newClients,
    int? existingClients,
    DateTime? updatedAt,
  }) {
    return ClientCount(
      id: id ?? this.id,
      dayId: dayId ?? this.dayId,
      staffId: staffId ?? this.staffId,
      newClients: newClients ?? this.newClients,
      existingClients: existingClients ?? this.existingClients,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'day_id': dayId,
    'staff_id': staffId,
    'new_clients': newClients,
    'existing_clients': existingClients,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ClientCount.fromRow(Map<String, Object?> row) => ClientCount._raw(
    id: row['id']! as int,
    dayId: row['day_id']! as int,
    staffId: row['staff_id']! as int,
    newClients: row['new_clients']! as int,
    existingClients: row['existing_clients']! as int,
    updatedAt: row['updated_at']! as String,
  );
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `yyyy-MM-dd` → local midnight. Cached: the same few hundred dates are
/// read over and over (every week load), and building a local [DateTime] is
/// comparatively expensive because it consults the time zone. [DateTime] is
/// immutable, so sharing instances is safe.
DateTime _parseDateKey(String s) => _dateKeyCache.putIfAbsent(s, () {
  final parts = s.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
});

final _dateKeyCache = <String, DateTime>{};

DateTime _asDateTime(Object v) =>
    v is DateTime ? v : DateTime.parse(v as String);
