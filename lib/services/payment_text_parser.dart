/// Reads payment confirmations (M-Pesa SMS and similar) out of text — typed,
/// pasted, or recognised from a photo — so each can become a revenue entry.
///
/// Rules:
/// - "… balance is Ksh…" figures are never the amount: balances change all
///   the time and say nothing about the payment.
/// - Money going *out* ("sent to", "paid to", "withdraw") is recognised and
///   marked, so it isn't counted as revenue by mistake.
/// - Phone numbers are not kept (the online data can be read by anyone with
///   the app); the payer's name, account and the transaction code are.
library;

/// One payment found in a message.
class ParsedPayment {
  const ParsedPayment({
    required this.amountCents,
    required this.method,
    this.code,
    this.payer,
    this.account,
    this.time,
    this.incoming = true,
  });

  final int amountCents;

  /// "M-Pesa", "Airtel Money", "Bank", or "Payment" when unknown.
  final String method;

  /// The transaction code (e.g. "UK3JPO8PVA"), used to spot duplicates.
  final String? code;

  /// Who paid, e.g. "DAVID KIMURKONG KANGOGO".
  final String? payer;

  /// The paybill/till account reference, e.g. a student's name.
  final String? account;

  /// When the payment happened, if the message says.
  final DateTime? time;

  /// False for money going out (sent, paid, withdrawn).
  final bool incoming;

  /// The same payment with some details corrected (by the admin, in the
  /// review). Empty text clears a detail.
  ParsedPayment copyWith({
    int? amountCents,
    String? method,
    String? code,
    String? payer,
    String? account,
    bool? incoming,
  }) {
    String? clean(String? v, String? old) =>
        v == null ? old : (v.trim().isEmpty ? null : v.trim());
    return ParsedPayment(
      amountCents: amountCents ?? this.amountCents,
      method: method ?? this.method,
      code: clean(code, this.code),
      payer: clean(payer, this.payer),
      account: clean(account, this.account),
      time: time,
      incoming: incoming ?? this.incoming,
    );
  }

  /// The note saved with the revenue entry. The transaction code comes
  /// first: notes are cut to a set length, and the code is how a payment
  /// already added is recognised, so it must never be the part cut off.
  String get note => [
    ?code,
    method,
    ?_title(payer),
    if (account != null) 'Acc: $account',
  ].join(' · ');

  static String? _title(String? name) {
    if (name == null) return null;
    // "DAVID KIMURKONG KANGOGO" → "David Kimurkong Kangogo"
    return name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }
}

// An M-Pesa style transaction code: 10 capitals/digits with at least one
// digit and one letter, followed by "Confirmed".
final _codeConfirmed = RegExp(
  r'\b([A-Z0-9]{10})\s*[.,]?\s*Confirmed\b',
  caseSensitive: false,
);

// One amount as it may appear, including how text recognition mangles it:
// "45,740.00", "45740.00" (commas lost), "45, 740.00" (stray space),
// "45.740.00" (comma read as a dot), "45 740", "45,740.0O" (0 read as O).
// A separator only counts when a digit follows it; a space only when a
// group of exactly three digits follows ("Ksh500 2547…" stops at 500).
const _amount = r'[\dO](?:[\dO]|[,.](?=\s?[\dO])|\s(?=[\dO]{3}\b))*';

// "Ksh45,740.00", "KES 1,000", "Kshs. 500", "Ksh 2 000.50"
final _money = RegExp(
  r'\b(?:Kshs?|KES|KSH|Sh)\.?\s?('
  '$_amount'
  ')',
  caseSensitive: false,
);

// "balance is Ksh106,520.00", "New M-PESA balance is Ksh…", "Bal: KES …"
final _balance = RegExp(
  r'\b(?:bal(?:ance)?\.?\s*(?:is|:)?\s*)(?:Kshs?|KES|KSH|Sh)\.?\s?'
  '$_amount',
  caseSensitive: false,
);

// Transaction cost is also not the payment.
final _cost = RegExp(
  r'\b(?:transaction cost|charges?|fee)\s*,?\s*(?:Kshs?|KES|KSH)\.?\s?'
  '$_amount',
  caseSensitive: false,
);

// "on 3/11/26 at 1:38 PM", "at 03-10-2026 10:53 AM", "3.11.2026 13:38",
// or a date with no time ("on 03/10/2026").
final _date = RegExp(
  r'(?<![\d/.-])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?![\d/-])'
  r'(?:\s*,?\s*(?:at\s+)?(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\s*([AP]\.?\s?M\.?)?)?',
  caseSensitive: false,
);

final _outgoing = RegExp(
  r'\b(?:sent to|paid to|withdraw|transferred to|you bought|airtime|given to)\b',
  caseSensitive: false,
);

/// Finds every payment in [text]. A photo or paste may hold several
/// messages, from M-Pesa, Airtel, banks…, in any order (and the cut-off end
/// of the one before); every one with an amount is returned, in the order
/// they appear.
List<ParsedPayment> parsePayments(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return const [];

  // M-Pesa messages start with their transaction code ("UK3JPO8PVA
  // Confirmed"); whatever comes before the first one (an Airtel or bank
  // message, say) is a message too.
  final starts = [
    for (final m in _codeConfirmed.allMatches(flat))
      if (_looksLikeCode(m.group(1)!)) m,
  ];
  final segments = <(String? code, String body)>[];
  final head = starts.isEmpty ? flat : flat.substring(0, starts.first.start);
  if (head.trim().isNotEmpty) segments.add((null, head));
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1].start : flat.length;
    segments.add((
      starts[i].group(1)!.toUpperCase(),
      flat.substring(starts[i].end, end),
    ));
  }

  final out = <ParsedPayment>[];
  for (final (code, body) in segments) {
    // A segment can still hold more than one message (an uncoded one
    // pasted after an M-Pesa one): each further amount starts a new one.
    final parts = _splitMessages(body);
    for (var i = 0; i < parts.length; i++) {
      final p = _parseOne(i == 0 ? code : null, parts[i]);
      if (p != null) out.add(p);
    }
  }
  return out;
}

/// Splits [body] where another message begins: at the start of the
/// sentence holding each further amount (balances and fees don't count —
/// they belong to the message before).
List<String> _splitMessages(String body) {
  String blank(Match m) => ' ' * m[0]!.length;
  // Same length as [body], so positions line up.
  final masked = body
      .replaceAllMapped(_balance, blank)
      .replaceAllMapped(_cost, blank);
  final amounts = _money.allMatches(masked).toList();
  if (amounts.length < 2) return [body];
  final cuts = <int>[];
  for (var i = 1; i < amounts.length; i++) {
    final from = amounts[i - 1].end;
    final at = amounts[i].start;
    // The sentence start before this amount, after the previous amount.
    final stop = body.lastIndexOf(RegExp(r'[.!]\s'), at);
    final cut = stop >= from ? stop + 1 : at;
    if (cuts.isEmpty || cut > cuts.last) cuts.add(cut);
  }
  final parts = <String>[];
  var from = 0;
  for (final c in cuts) {
    parts.add(body.substring(from, c));
    from = c;
  }
  parts.add(body.substring(from));
  return [
    for (final p in parts)
      if (p.trim().isNotEmpty) p,
  ];
}

ParsedPayment? _parseOne(String? code, String body) {
  // Take balances and fees out before looking for the amount.
  final cleaned = body.replaceAll(_balance, ' ').replaceAll(_cost, ' ');
  final m = _money.firstMatch(cleaned);
  if (m == null) return null;
  final cents = _cents(m.group(1)!);
  if (cents == null || cents <= 0) return null;

  // Decided from this message alone: a paste with one M-Pesa message and
  // one Airtel message holds one of each.
  final lower = body.toLowerCase();
  final method =
      lower.contains('m-pesa') || lower.contains('mpesa') || code != null
      ? 'M-Pesa'
      : lower.contains('airtel')
      ? 'Airtel Money'
      : RegExp(r'\b(bank|equity|kcb|co-?op|ncba|absa|stanbic|family)\b')
            .hasMatch(lower)
      ? 'Bank'
      : 'Payment';

  return ParsedPayment(
    amountCents: cents,
    method: method,
    code: code ?? _receipt(body) ?? _otherReference(body),
    payer: _payer(cleaned),
    account: _account(cleaned),
    time: _time(body),
    incoming: !_outgoing.hasMatch(body),
  );
}

bool _looksLikeCode(String s) =>
    RegExp(r'[0-9]').hasMatch(s) && RegExp(r'[A-Za-z]').hasMatch(s);

/// "45,740.00" → 4574000. Two digits after the last separator are cents;
/// every other separator or space is a thousands mark. OCR often reads 0 as
/// O inside numbers.
int? _cents(String raw) {
  var s = raw.replaceAll(RegExp('[Oo]'), '0').replaceAll(RegExp(r'\s'), '');
  var frac = '00';
  final cents = RegExp(r'[.,](\d{1,2})$').firstMatch(s);
  if (cents != null) {
    frac = cents.group(1)!.padRight(2, '0');
    s = s.substring(0, cents.start);
  }
  final whole = int.tryParse(s.replaceAll(RegExp('[.,]'), ''));
  if (whole == null) return null;
  return whole * 100 + int.parse(frac);
}

String? _payer(String body) {
  // Case matters here: a full stop then a capitalised word ("… KANGOGO.
  // Account …") ends the name; an initial ("ALICE K. MWANGI") doesn't.
  final m = RegExp(
    r'\b[Ff][Rr][Oo][Mm]\s+(.+?)(?=[\s-]*(?:\+?\d[\d\s*xX]{5,}|\*{2,}|\b(?:[Oo][Nn]|[Aa][Tt])\s+\d|\.\s+(?=[A-Z][a-z])|\.$|\b(?:Account|ACCOUNT|account|Acc|ACC|New|NEW|via|VIA|Via|Ref|REF)\b|$))',
  ).firstMatch(body);
  // "PIUS-" (a masked phone number cut off after the dash) → "PIUS".
  final name = m?.group(1)?.trim().replaceAll(RegExp(r'[\s,:;-]+$'), '');
  if (name == null || name.isEmpty) return null;
  // Not a name if it's only digits/symbols.
  if (!RegExp('[A-Za-z]').hasMatch(name)) return null;
  return name.length > 60 ? name.substring(0, 60) : name;
}

String? _account(String body) {
  final m = RegExp(
    r'\b(?:Account Number|Account No\.?|Acc(?:ount)?\.?(?: no\.?)?)\s*[:.]?\s+(.+?)(?=\s*(?:\bNew\b|\bbalance\b|\.\s|\.$|$))',
    caseSensitive: false,
  ).firstMatch(body);
  final acc = m?.group(1)?.trim();
  if (acc == null || acc.isEmpty) return null;
  return acc.length > 40 ? acc.substring(0, 40) : acc;
}

/// "3/11/26 at 1:38 PM" — Kenyan messages are day/month/year. A date with
/// no time is taken as midday, so it stays on its day in any time zone.
DateTime? _time(String body) {
  for (final m in _date.allMatches(body)) {
    final t = _dateOf(m);
    if (t != null) return t;
  }
  return null;
}

DateTime? _dateOf(RegExpMatch m) {
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  var y = int.parse(m.group(3)!);
  if (y < 100) y += 2000;
  var h = int.parse(m.group(4) ?? '12');
  final min = int.parse(m.group(5) ?? '0');
  final ampm = m.group(6)?.toUpperCase().replaceAll(RegExp(r'[.\s]'), '');
  if (ampm == 'PM' && h < 12) h += 12;
  if (ampm == 'AM' && h == 12) h = 0;
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || min > 59) return null;
  final t = DateTime(y, mo, d, h, min);
  return t.month == mo ? t : null; // rejects 31/2 etc.
}

/// "The M-Pesa receipt number is:UJ3H98O13S" (bank and agent messages):
/// the M-Pesa code, preferred over the sender's own "Ref:".
String? _receipt(String body) {
  final m = RegExp(
    r'\b(?:m-?pesa\s+)?receipt\s*(?:number|no\.?)?\s*(?:is)?\s*[:.#]?\s*([A-Z0-9]{10})\b',
    caseSensitive: false,
  ).firstMatch(body);
  final code = m?.group(1);
  return code != null && _looksLikeCode(code) ? code.toUpperCase() : null;
}

/// A reference on non-M-Pesa slips: "Ref: ABC123", "Transaction ID …".
String? _otherReference(String body) {
  final m = RegExp(
    r'\b(?:ref(?:erence)?|transaction id|txn(?: id)?|receipt(?: no\.?)?)\s*[:.#]?\s*([A-Z0-9]{6,20})\b',
    caseSensitive: false,
  ).firstMatch(body);
  return m?.group(1)?.toUpperCase();
}
