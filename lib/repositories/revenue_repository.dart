import '../database/database.dart';

/// One transaction (e.g. read off a WhatsApp payment photo).
class RevenueEntry {
  const RevenueEntry({
    required this.id,
    required this.date,
    required this.amountCents,
    required this.note,
    required this.createdAt,
    this.purpose = '',
  });

  final int id;

  /// The calendar day the money came in (date only).
  final DateTime date;

  /// Negative for a refund (money paid back).
  final int amountCents;

  /// Optional, e.g. "M-Pesa · Jane W." — empty when not given.
  final String note;

  /// When the payment happened (or was typed in).
  final DateTime createdAt;

  /// What it was for, e.g. "Application fee"; empty when not set.
  final String purpose;

  bool get isRefund => amountCents < 0;

  static RevenueEntry fromRow(Map<String, Object?> r) => RevenueEntry(
    id: r['id']! as int,
    date: DateTime.parse(r['date']! as String),
    amountCents: r['amount_cents']! as int,
    note: r['note']! as String,
    createdAt: DateTime.parse(r['created_at']! as String),
    purpose: (r['purpose'] as String?) ?? '',
  );
}

/// One change to the revenue: added, edited, deleted or restored.
class RevenueChange {
  const RevenueChange({
    required this.entryId,
    required this.action,
    required this.amountCents,
    required this.date,
    required this.note,
    required this.device,
    required this.changedAt,
    this.oldAmountCents,
    this.oldDate,
    this.oldNote,
  });

  final int entryId;

  /// 'added', 'edited', 'deleted' or 'restored'.
  final String action;
  final int amountCents;
  final DateTime date;
  final String note;
  final int? oldAmountCents;
  final DateTime? oldDate;
  final String? oldNote;

  /// Which device made the change, e.g. "Windows PC".
  final String device;
  final DateTime changedAt;
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

  /// The day's transactions, in time order.
  List<RevenueEntry> entriesFor(DateTime day) => entriesBetween(day, day);

  /// Every transaction from [from] to [to] (inclusive), in time order.
  List<RevenueEntry> entriesBetween(DateTime from, DateTime to) => [
    for (final r in _db.raw.select(
      'SELECT * FROM revenue_entries WHERE date BETWEEN ? AND ? '
      'ORDER BY date, created_at, id;',
      [_key(from), _key(to)],
    ))
      RevenueEntry.fromRow(r),
  ];

  /// Monthly totals from [from]'s month to [to]'s month, every month
  /// included (0 when nothing came in), oldest first.
  List<RevenueDay> monthsBetween(DateTime from, DateTime to) {
    final rows = _db.raw.select(
      'SELECT substr(date, 1, 7) AS m, SUM(amount_cents) AS total, '
      'COUNT(*) AS n FROM revenue_entries WHERE date BETWEEN ? AND ? '
      'GROUP BY m;',
      [
        _key(DateTime(from.year, from.month, 1)),
        _key(DateTime(to.year, to.month + 1, 0)),
      ],
    );
    final byMonth = {
      for (final r in rows)
        r['m']! as String: (r['total']! as int, r['n']! as int),
    };
    final out = <RevenueDay>[];
    var m = DateTime(from.year, from.month, 1);
    final end = DateTime(to.year, to.month, 1);
    while (!m.isAfter(end)) {
      final k = _key(m).substring(0, 7);
      final (total, n) = byMonth[k] ?? (0, 0);
      out.add(RevenueDay(m, total, n));
      m = DateTime(m.year, m.month + 1, 1);
    }
    return out;
  }

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

  /// Which device this is, recorded with every change ("Windows PC",
  /// "Android phone"…). Set at start-up.
  static String deviceLabel = 'This device';

  RevenueEntry? entry(int id) {
    final rows = _db.raw.select('SELECT * FROM revenue_entries WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : RevenueEntry.fromRow(rows.first);
  }

  /// [at] is when the payment happened, when known (e.g. read from the
  /// payment message); otherwise now. Entries are listed in that order.
  /// A negative amount is a refund.
  int add(
    DateTime day,
    int amountCents, {
    String note = '',
    DateTime? at,
    String purpose = '',
  }) {
    _check(amountCents);
    final now = DateTime.now().toIso8601String();
    final when = (at ?? DateTime.now()).toIso8601String();
    return _db.transaction(() {
      _db.raw.execute(
        'INSERT INTO revenue_entries '
        '(id, date, amount_cents, note, created_at, updated_at, purpose) '
        'VALUES (new_id(), ?, ?, ?, ?, ?, ?);',
        [
          _key(day),
          amountCents,
          _clean(note),
          when,
          now,
          _cleanPurpose(purpose),
        ],
      );
      final id = _db.raw.lastInsertRowId;
      _log(id, 'added', after: entry(id));
      return id;
    });
  }

  /// Changes an entry; [at] (when given) moves it to that date and time.
  void update(
    int id, {
    required int amountCents,
    required String note,
    DateTime? at,
    String? purpose,
  }) {
    _check(amountCents);
    final now = DateTime.now().toIso8601String();
    _db.transaction(() {
      final before = entry(id);
      _db.raw.execute(
        'UPDATE revenue_entries SET amount_cents = ?, note = ?, '
        'date = COALESCE(?, date), created_at = COALESCE(?, created_at), '
        'purpose = COALESCE(?, purpose), updated_at = ? WHERE id = ?;',
        [
          amountCents,
          _clean(note),
          at == null ? null : _key(at),
          at?.toIso8601String(),
          purpose == null ? null : _cleanPurpose(purpose),
          now,
          id,
        ],
      );
      final after = entry(id);
      if (before != null &&
          after != null &&
          (before.amountCents != after.amountCents ||
              before.note != after.note ||
              before.date != after.date ||
              before.createdAt != after.createdAt ||
              before.purpose != after.purpose)) {
        _log(id, 'edited', before: before, after: after);
      }
    });
  }

  /// Which of [codes] (transaction codes) are already in a saved note —
  /// so the same message can't be added twice. Letter O and zero count as
  /// the same: text readers mix them up ("UK3JPO8PVA" vs "UK3JP08PVA"), and
  /// the phone and the PC may read the same photo differently.
  Set<String> existingCodes(Iterable<String> codes) => {
    for (final c in codes)
      if (c.isNotEmpty &&
          _db.raw.select(
            "SELECT 1 FROM revenue_entries "
            "WHERE instr(replace(upper(note), 'O', '0'), ?) > 0 LIMIT 1;",
            [c.toUpperCase().replaceAll('O', '0')],
          ).isNotEmpty)
        c,
  };

  void delete(int id) => _db.transaction(() {
    final before = entry(id);
    _db.raw.execute('DELETE FROM revenue_entries WHERE id = ?;', [id]);
    if (before != null) _log(id, 'deleted', before: before);
  });

  /// Puts back a deleted entry exactly as it was (Undo).
  void restore(RevenueEntry e) => _db.transaction(() {
    _db.raw.execute(
      'INSERT INTO revenue_entries '
      '(id, date, amount_cents, note, created_at, updated_at, purpose) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        e.id,
        _key(e.date),
        e.amountCents,
        e.note,
        e.createdAt.toIso8601String(),
        DateTime.now().toIso8601String(),
        e.purpose,
      ],
    );
    _log(e.id, 'restored', after: e);
  });

  /// Records one change in the history (synced, so every device sees it).
  void _log(
    int entryId,
    String action, {
    RevenueEntry? before,
    RevenueEntry? after,
  }) {
    final shown = after ?? before!;
    _db.raw.execute(
      'INSERT INTO revenue_changes (id, entry_id, action, amount_cents, '
      'date, note, old_amount_cents, old_date, old_note, device, changed_at) '
      'VALUES (new_id(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        entryId,
        action,
        shown.amountCents,
        _key(shown.date),
        shown.note,
        if (before != null && after != null) ...[
          before.amountCents,
          _key(before.date),
          before.note,
        ] else ...[
          null,
          null,
          null,
        ],
        deviceLabel,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  /// The change history, newest first.
  List<RevenueChange> changes({int limit = 300}) => [
    for (final r in _db.raw.select(
      'SELECT * FROM revenue_changes ORDER BY changed_at DESC, id DESC '
      'LIMIT ?;',
      [limit],
    ))
      RevenueChange(
        entryId: r['entry_id']! as int,
        action: r['action']! as String,
        amountCents: r['amount_cents']! as int,
        date: DateTime.parse(r['date']! as String),
        note: r['note']! as String,
        oldAmountCents: r['old_amount_cents'] as int?,
        oldDate: r['old_date'] == null
            ? null
            : DateTime.parse(r['old_date']! as String),
        oldNote: r['old_note'] as String?,
        device: r['device']! as String,
        changedAt: DateTime.parse(r['changed_at']! as String),
      ),
  ];

  /// Transactions on any date whose note, purpose or amount matches
  /// [query] (all words must match), newest first. A number also matches
  /// the amount ("45740" or "45,740").
  List<RevenueEntry> search(String query, {int limit = 200}) {
    final words = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final where = <String>[];
    final args = <Object?>[];
    for (final w in words) {
      final cents = parseAmount(w);
      final digitsOnly = RegExp(r'^[\d,.]+$').hasMatch(w);
      if (digitsOnly && cents != null) {
        where.add(
          '(lower(note) LIKE ? OR lower(purpose) LIKE ? '
          'OR abs(amount_cents) = ?)',
        );
        args.addAll(['%$w%', '%$w%', cents]);
      } else {
        where.add(
          "(replace(lower(note), 'o', '0') LIKE ? OR lower(note) LIKE ? "
          'OR lower(purpose) LIKE ?)',
        );
        args.addAll(['%${w.replaceAll('o', '0')}%', '%$w%', '%$w%']);
      }
    }
    return [
      for (final r in _db.raw.select(
        'SELECT * FROM revenue_entries WHERE ${where.join(' AND ')} '
        'ORDER BY date DESC, created_at DESC LIMIT ?;',
        [...args, limit],
      ))
        RevenueEntry.fromRow(r),
    ];
  }

  static void _check(int cents) {
    if (cents == 0 || cents.abs() > maxAmountCents) {
      throw ArgumentError.value(cents, 'amountCents', 'out of range');
    }
  }

  static String _cleanPurpose(String p) {
    final t = p.trim();
    return t.length > 40 ? t.substring(0, 40) : t;
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

/// "KSh 45.7k", "KSh 1.2M" — for chart labels where space is short.
String formatMoneyShort(int cents, String currency) {
  final v = cents / 100;
  String trim(double x) {
    final s = x.toStringAsFixed(x >= 100 ? 0 : 1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (v >= 1000000) return '$currency ${trim(v / 1000000)}M';
  if (v >= 1000) return '$currency ${trim(v / 1000)}k';
  return '$currency ${v.round()}';
}

/// How a payment came in, from its note ("M-Pesa · …" from a scanned
/// message, or whatever was typed): M-Pesa, Bank, Airtel Money, Cash, Card,
/// or Not noted.
String paymentMethodOf(String note) {
  final n = note.toLowerCase();
  if (n.contains('m-pesa') || n.contains('mpesa')) return 'M-Pesa';
  if (n.contains('airtel')) return 'Airtel Money';
  if (RegExp(r'\b(bank|equity|kcb|co-?op|ncba|absa|stanbic|family|transfer)\b')
      .hasMatch(n)) {
    return 'Bank';
  }
  if (RegExp(r'\bcash\b').hasMatch(n)) return 'Cash';
  if (RegExp(r'\b(card|visa|mastercard|pdq)\b').hasMatch(n)) return 'Card';
  if (n.startsWith('payment')) return 'Other';
  return 'Not noted';
}
