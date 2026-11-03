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

  /// The note saved with the revenue entry.
  String get note => [
    method,
    ?_title(payer),
    if (account != null) 'Acc: $account',
    ?code,
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

final _date = RegExp(
  r'\bon\s+(\d{1,2})/(\d{1,2})/(\d{2,4})\s+at\s+(\d{1,2})[:.](\d{2})\s*([AP]\.?M\.?)?',
  caseSensitive: false,
);

final _outgoing = RegExp(
  r'\b(?:sent to|paid to|withdraw|transferred to|you bought|airtime|given to)\b',
  caseSensitive: false,
);

/// Finds every payment in [text]. A photo or paste may hold several
/// messages (and the cut-off end of the one before); each complete one is
/// returned, oldest first as they appear.
List<ParsedPayment> parsePayments(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return const [];

  // Split on transaction codes ("UK3JPO8PVA Confirmed").
  final starts = [
    for (final m in _codeConfirmed.allMatches(flat))
      if (_looksLikeCode(m.group(1)!)) m,
  ];
  final segments = <(String? code, String body)>[];
  if (starts.isEmpty) {
    segments.add((null, flat));
  } else {
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1].start : flat.length;
      segments.add((
        starts[i].group(1)!.toUpperCase(),
        flat.substring(starts[i].end, end),
      ));
    }
  }

  final out = <ParsedPayment>[];
  for (final (code, body) in segments) {
    final p = _parseOne(code, body, flat);
    if (p != null) out.add(p);
  }
  return out;
}

ParsedPayment? _parseOne(String? code, String body, String whole) {
  // Take balances and fees out before looking for the amount.
  final cleaned = body.replaceAll(_balance, ' ').replaceAll(_cost, ' ');
  final m = _money.firstMatch(cleaned);
  if (m == null) return null;
  final cents = _cents(m.group(1)!);
  if (cents == null || cents <= 0) return null;

  final lower = whole.toLowerCase();
  final method =
      lower.contains('m-pesa') ||
          lower.contains('mpesa') ||
          code != null && lower.contains('confirmed')
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
    code: code ?? _otherReference(body),
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
    r'\b[Ff][Rr][Oo][Mm]\s+(.+?)(?=\s*(?:\+?\d[\d\s]{8,}|\b[Oo][Nn]\s+\d|\.\s+(?=[A-Z][a-z])|\.$|\b(?:Account|ACCOUNT|account|Acc|ACC|New|NEW)\b|$))',
  ).firstMatch(body);
  final name = m?.group(1)?.trim();
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

/// "3/11/26 at 1:38 PM" — Kenyan messages are day/month/year.
DateTime? _time(String body) {
  final m = _date.firstMatch(body);
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  var y = int.parse(m.group(3)!);
  if (y < 100) y += 2000;
  var h = int.parse(m.group(4)!);
  final min = int.parse(m.group(5)!);
  final ampm = m.group(6)?.toUpperCase().replaceAll('.', '');
  if (ampm == 'PM' && h < 12) h += 12;
  if (ampm == 'AM' && h == 12) h = 0;
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || min > 59) return null;
  final t = DateTime(y, mo, d, h, min);
  return t.month == mo ? t : null; // rejects 31/2 etc.
}

/// A reference on non-M-Pesa slips: "Ref: ABC123", "Transaction ID …".
String? _otherReference(String body) {
  final m = RegExp(
    r'\b(?:ref(?:erence)?|transaction id|txn(?: id)?|receipt(?: no\.?)?)\s*[:.#]?\s*([A-Z0-9]{6,20})\b',
    caseSensitive: false,
  ).firstMatch(body);
  return m?.group(1)?.toUpperCase();
}
