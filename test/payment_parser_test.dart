import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/services/payment_text_parser.dart';

void main() {
  // As text recognition returns the example photo: line breaks, and the
  // cut-off end of the previous message at the top.
  const photo = '''
balance is
Ksh60,780.00
UK3JPO8PVA
Confirmed. on 3/11/26 at
1:38 PM Ksh45,740.00
received from DAVID
KIMURKONG
KANGOGO
254722699840.
Account Number
Leonorah Cherop New
Utility balance is
Ksh106,520.00
Sender can't accept replies. Contact
them directly. Learn more
''';

  test('the example M-Pesa photo: amount received, not the balances', () {
    final found = parsePayments(photo);
    expect(found, hasLength(1));
    final p = found.single;
    expect(p.amountCents, 4574000);
    expect(p.code, 'UK3JPO8PVA');
    expect(p.payer, 'DAVID KIMURKONG KANGOGO');
    expect(p.account, 'Leonorah Cherop');
    expect(p.time, DateTime(2026, 11, 3, 13, 38));
    expect(p.method, 'M-Pesa');
    expect(p.incoming, isTrue);
    expect(
      p.note,
      'M-Pesa · David Kimurkong Kangogo · Acc: Leonorah Cherop · UK3JPO8PVA',
    );
    // The phone number is not kept.
    expect(p.note, isNot(contains('2547')));
  });

  test('several messages in one photo, and OCR mistakes in numbers', () {
    const two = '''
UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM Ksh45,740.00 received from
DAVID KANGOGO 254722699840. Account Number Leonorah New Utility balance is Ksh106,520.00
UK3JQ12ABC Confirmed. on 3/11/26 at 2:05 PM Ksh1O,5OO.00 received from
JANE WANJIKU 254711000111. Account Number Brian New Utility balance is Ksh117,020.00
''';
    final found = parsePayments(two);
    expect(found.map((p) => p.amountCents), [4574000, 1050000]);
    expect(found.map((p) => p.code), ['UK3JPO8PVA', 'UK3JQ12ABC']);
    expect(found.last.time, DateTime(2026, 11, 3, 14, 5));
  });

  test('personal M-Pesa "You have received" format', () {
    final p = parsePayments(
      'SJK4ABC12D Confirmed.You have received Ksh2,000.00 from JOHN DOE '
      '0712345678 on 5/11/26 at 9:15 AM New M-PESA balance is Ksh12,345.00. '
      'Earn interest daily on Ziidi MMF',
    ).single;
    expect(p.amountCents, 200000);
    expect(p.payer, 'JOHN DOE');
    expect(p.time, DateTime(2026, 11, 5, 9, 15));
  });

  test('money going out is marked, so it is not counted', () {
    final p = parsePayments(
      'SJK4XYZ99Q Confirmed. Ksh500.00 sent to MARY A 0722000000 on 5/11/26 '
      'at 10:00 AM. New M-PESA balance is Ksh900.00. Transaction cost, Ksh7.00.',
    ).single;
    expect(p.amountCents, 50000);
    expect(p.incoming, isFalse);
  });

  test('other payment slips: bank and Airtel', () {
    final bank = parsePayments(
      'Equity Bank: KES 15,000.00 received from PETER OTIENO. Ref: FT26307ABC9 '
      'Avail. Bal: KES 230,000.00',
    ).single;
    expect(bank.amountCents, 1500000);
    expect(bank.method, 'Bank');
    expect(bank.code, 'FT26307ABC9');
    expect(bank.payer, 'PETER OTIENO');

    final airtel = parsePayments(
      'Airtel Money: You have received Ksh 3,200 from ALICE K. '
      'Transaction ID: MP261103XYZ. Your balance is Ksh 8,000.',
    ).single;
    expect(airtel.amountCents, 320000);
    expect(airtel.method, 'Airtel Money');
    expect(airtel.code, 'MP261103XYZ');
  });

  test('nothing to find', () {
    expect(parsePayments(''), isEmpty);
    expect(parsePayments('Hello, see you tomorrow'), isEmpty);
    expect(parsePayments('Your balance is Ksh60,780.00'), isEmpty);
  });

  test('amounts survive what text recognition does to them', () {
    int read(String amount) => parsePayments(
      'UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM $amount received from '
      'DAVID KANGOGO 254722699840. New Utility balance is Ksh106,520.00',
    ).single.amountCents;
    expect(read('Ksh45,740.00'), 4574000);
    expect(read('Ksh45740.00'), 4574000); // commas lost
    expect(read('Ksh45, 740.00'), 4574000); // stray space
    expect(read('Ksh45.740.00'), 4574000); // comma read as a dot
    expect(read('Ksh 45 740.00'), 4574000);
    expect(read('Ksh45,740.0O'), 4574000); // 0 read as O
    expect(read('Ksh1,245,740.00'), 124574000);
    expect(read('Ksh1,500'), 150000);
    expect(read('Ksh500'), 50000);
  });

  test('a name with an initial is kept whole', () {
    final p = parsePayments(
      'SJK4ABC12D Confirmed.You have received Ksh2,000.00 from ALICE K. '
      'MWANGI 0712345678 on 5/11/26 at 9:15 AM New M-PESA balance is Ksh1.00',
    ).single;
    expect(p.payer, 'ALICE K. MWANGI');
    expect(p.amountCents, 200000);
  });

  test('older messages keep their own date', () {
    final p = parsePayments(
      'QF71ABC2XY Confirmed. on 14/2/23 at 9:05 AM Ksh3,500.00 received from '
      'MARY W 254700111222. New Utility balance is Ksh10.00',
    ).single;
    expect(p.time, DateTime(2023, 2, 14, 9, 5));
  });
}
