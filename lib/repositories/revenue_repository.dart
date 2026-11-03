import '../database/database.dart';

/// One transaction (e.g. read off a WhatsApp payment photo).
class RevenueEntry {
  const RevenueEntry({
    required this.id,
    required this.date,
    required this.amountCents,
    required this.note,
    required this.createdAt,
  });

  final int id;

  /// The calendar day the money came in (date only).
  final DateTime date;
  final int amountCents;

  /// Optional, e.g. "M-Pesa · Jane W." — empty when not given.
  final String note;
  final DateTime createdAt;
}

/// Money in on one day: the total and how many transactions made it.
class RevenueDay {
  const RevenueDay(this.date, this.totalCents, this.count);
  final DateTime date;
  final int totalCents;
  final int count;
}

/// Revenue transactions. Totals are always added up from the entries,
/// never stored, so they can't drift.
class RevenueRepository {
  RevenueRepository(this._db);

  final AppDatabase _db;

  static const int maxNoteLength = 120;

  /// Largest single amount accepted (100 million), to catch typos like a
  /// pasted phone number.
  static const int maxAmountCents = 100000000 * 100;

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime _parse(String s) => DateTime.parse(s);

  /// The day's transactions, oldest first (the order they were entered).
  List<RevenueEntry> entriesFor(DateTime day) => [
    for (final r in _db.raw.select(
      'SELECT * FROM revenue_entries WHERE date = ? ORDER BY created_at, id;',
      [_key(day)],
    ))
      RevenueEntry(
        id: r['id']! as int,
        date: _parse(r['date']! as String),
        amountCents: r['amount_cents']! as int,
        note: r['note']! as String,
        createdAt: DateTime.parse(r['created_at']! as String),
      ),
  ];

  /// Totals for every day from [from] to [to] (inclusive), including days
  /// with nothing (total 0), oldest first.
  List<RevenueDay> daysBetween(DateTime from, DateTime to) {
    final rows = _db.raw.select(
      'SELECT date, SUM(amount_cents) AS total, COUNT(*) AS n '
      'FROM revenue_entries WHERE date BETWEEN ? AND ? GROUP BY date;',
      [_key(from), _key(to)],
    );
    final byDate = {
      for (final r in rows)
        r['date']! as String: (r['total']! as int, r['n']! as int),
    };
    final out = <RevenueDay>[];
    var d = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);
    while (!d.isAfter(end)) {
      final (total, n) = byDate[_key(d)] ?? (0, 0);
      out.add(RevenueDay(d, total, n));
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out;
  }

  /// One day's total and count.
  RevenueDay day(DateTime day) => daysBetween(day, day).single;

  int add(DateTime day, int amountCents, {String note = ''}) {
    _check(amountCents);
    final now = DateTime.now().toIso8601String();
    _db.raw.execute(
      'INSERT INTO revenue_entries '
      '(id, date, amount_cents, note, created_at, updated_at) '
      'VALUES (new_id(), ?, ?, ?, ?, ?);',
      [_key(day), amountCents, _clean(note), now, now],
    );
    return _db.raw.lastInsertRowId;
  }

  void update(int id, {required int amountCents, required String note}) {
    _check(amountCents);
    _db.raw.execute(
      'UPDATE revenue_entries SET amount_cents = ?, note = ?, updated_at = ? '
      'WHERE id = ?;',
      [amountCents, _clean(note), DateTime.now().toIso8601String(), id],
    );
  }

  /// Which of [codes] (transaction codes) are already in a saved note —
  /// so the same message can't be added twice.
  Set<String> existingCodes(Iterable<String> codes) => {
    for (final c in codes)
      if (c.isNotEmpty &&
          _db.raw.select(
            'SELECT 1 FROM revenue_entries WHERE instr(upper(note), ?) > 0 '
            'LIMIT 1;',
            [c.toUpperCase()],
          ).isNotEmpty)
        c,
  };

  void delete(int id) =>
      _db.raw.execute('DELETE FROM revenue_entries WHERE id = ?;', [id]);

  /// Puts back a deleted entry exactly as it was (Undo).
  void restore(RevenueEntry e) => _db.raw.execute(
    'INSERT INTO revenue_entries '
    '(id, date, amount_cents, note, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?);',
    [
      e.id,
      _key(e.date),
      e.amountCents,
      e.note,
      e.createdAt.toIso8601String(),
      DateTime.now().toIso8601String(),
    ],
  );

  static void _check(int cents) {
    if (cents <= 0 || cents > maxAmountCents) {
      throw ArgumentError.value(cents, 'amountCents', 'out of range');
    }
  }

  static String _clean(String note) {
    final t = note.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > maxNoteLength ? t.substring(0, maxNoteLength) : t;
  }

  /// Reads a typed amount: "1,500", "1500.50", "KSh 2 000". Returns cents,
  /// or null when it isn't a positive amount with at most two decimals.
  static int? parseAmount(String text) {
    final t = text.replaceAll(RegExp(r'[^0-9.]'), '');
    if (t.isEmpty || '.'.allMatches(t).length > 1) return null;
    final parts = t.split('.');
    if (parts.length == 2 && parts[1].length > 2) return null;
    final whole = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    if (whole == null) return null;
    final frac = parts.length == 2 ? parts[1].padRight(2, '0') : '00';
    final cents = whole * 100 + int.parse(frac.isEmpty ? '0' : frac);
    return cents <= 0 || cents > maxAmountCents ? null : cents;
  }
}

/// "KSh 45,300" — or "KSh 45,300.50" when there are cents.
String formatMoney(int cents, String currency) {
  final whole = cents ~/ 100;
  final frac = (cents % 100).abs();
  final digits = whole.abs().toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  final sign = cents < 0 ? '-' : '';
  final tail = frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}';
  return '$currency $sign$grouped$tail';
}
