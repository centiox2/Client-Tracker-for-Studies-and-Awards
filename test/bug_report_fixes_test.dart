// Regression tests for the S&A Hub bug report (12 issues). Each group is
// named after the issue it covers.
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/screens/revenue/scan_payments.dart';
import 'package:client_tracker/services/excel_import.dart';
import 'package:client_tracker/services/export_service.dart';
import 'package:client_tracker/services/payment_text_parser.dart';
import 'package:client_tracker/services/revenue_export.dart';
import 'package:client_tracker/widgets/numeric_field.dart';

const _airtel =
    'Ksh.1500 received from JOHN DOE 0733123456 on 3/11/26 at 2:15 PM via '
    'Airtel Money. New balance Ksh. 3,000.';
const _mpesa =
    'UK3JPO8PVA Confirmed. Ksh500.00 received from DAVID KANGOGO 0712345678 '
    'on 3/11/26 at 1:38 PM New M-PESA balance is Ksh106,520.00. Transaction '
    'cost, Ksh0.00.';
const _bank =
    'Ksh2,000.00 received from ACME LTD via Equity Bank Ref: TT2345. Avail. '
    'Bal KES 50,000.';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  group('1 & 11: several messages in one paste', () {
    test('Airtel then M-Pesa: both found, each with its own method', () {
      final ps = parsePayments('$_airtel $_mpesa');
      expect(ps.map((p) => p.amountCents), [150000, 50000]);
      expect(ps.map((p) => p.method), ['Airtel Money', 'M-Pesa']);
    });

    test('M-Pesa then Airtel: the same two', () {
      final ps = parsePayments('$_mpesa $_airtel');
      expect(ps.map((p) => p.amountCents), [50000, 150000]);
      expect(ps.map((p) => p.method), ['M-Pesa', 'Airtel Money']);
      expect(ps.first.code, 'UK3JPO8PVA');
      expect(ps.last.code, isNull);
    });

    test('M-Pesa then a bank message: the bank one isn’t absorbed', () {
      final ps = parsePayments('$_mpesa $_bank');
      expect(ps, hasLength(2));
      expect(ps.last.method, 'Bank');
      expect(ps.last.amountCents, 200000);
      expect(ps.last.payer, 'ACME LTD');
    });

    test('the same message pasted twice: two, flagged by their code', () {
      final ps = parsePayments('$_mpesa $_mpesa');
      expect(ps, hasLength(2));
      expect(
        paymentDuplicateKey(ps[0], null),
        paymentDuplicateKey(ps[1], null),
      );
    });

    test('one uncoded message alone still works', () {
      final ps = parsePayments(_airtel);
      expect(ps.single.amountCents, 150000);
      expect(ps.single.payer, 'JOHN DOE');
    });
  });

  group('2: starter staff only once', () {
    int count() =>
        db.raw.select('SELECT COUNT(*) AS c FROM staff;').first['c']! as int;

    test('a fresh database gets the 14 starter names', () {
      expect(count(), 14);
    });

    test('deleting everyone stays deleted at the next launch', () {
      db.raw.execute('DELETE FROM staff;');
      AppDatabase.seedStaff(db.raw); // what opening the database runs
      expect(count(), 0);
    });

    test('a database already in use keeps its own staff', () {
      db.raw.execute("DELETE FROM sync_state WHERE k = 'staff_seeded';");
      db.raw.execute('DELETE FROM staff;');
      for (final n in ['Ann', 'Ben', 'Cy']) {
        StaffRepository(db).add(n);
      }
      AppDatabase.seedStaff(db.raw);
      expect(count(), 3);
    });
  });

  group('3: money going out', () {
    test('saved as a refund (negative), lowering the day', () {
      final sent = parsePayments(
        'UK3JPO8PVB Confirmed. Ksh2,000.00 sent to JOHN DOE 0712345678 on '
        '3/11/26 at 1:38 PM. New M-PESA balance is Ksh1,000.00.',
      ).single;
      expect(sent.incoming, isFalse);
      expect(revenueAmountFor(sent), -200000);
      expect(revenueAmountFor(parsePayments(_mpesa).single), 50000);

      final repo = RevenueRepository(db);
      final day = DateTime(2026, 11, 3);
      repo.add(day, 500000);
      repo.add(day, revenueAmountFor(sent), note: sent.note);
      expect(repo.daysBetween(day, day).single.totalCents, 300000);
    });
  });

  group('4: a long note never loses its code', () {
    test('the code comes first and is still found once saved', () {
      final p = ParsedPayment(
        amountCents: 100000,
        method: 'Bank',
        code: 'QWE12345',
        payer: 'THE VERY LONG NAME OF A COMPANY LIMITED AND SONS',
        account: 'A REFERENCE THAT GOES ON AND ON AND ON FOR A WHILE',
      );
      expect(p.note.length, greaterThan(RevenueRepository.maxNoteLength));
      expect(p.note, startsWith('QWE12345'));
      final repo = RevenueRepository(db);
      repo.add(DateTime(2026, 11, 3), p.amountCents, note: p.note);
      expect(repo.existingCodes(['QWE12345']), {'QWE12345'});
    });
  });

  group('5: count cells have a ceiling', () {
    test('the repository caps a pasted phone number', () {
      final w = WeekRepository(db).createWeekFor(DateTime(2026, 11, 2));
      final day = WeekRepository(db).getDays(w.id).first;
      final joy = StaffRepository(db)
          .getAll()
          .firstWhere((s) => s.name == 'Joy')
          .id;
      ClientCountRepository(db).saveCount(
        dayId: day.id,
        staffId: joy,
        newClients: 712345678,
        existingClients: 3,
      );
      expect(
        ClientCountRepository(db).countValues(day.id, joy).newClients,
        ClientCountRepository.maxClients,
      );
    });

    testWidgets('the field takes six digits at most and never crashes', (
      tester,
    ) async {
      int? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NumericField(value: 0, onChanged: (v) => saved = v),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '99999999999999999999');
      await tester.pump();
      expect(saved, isNotNull);
      expect(saved, lessThanOrEqualTo(ClientCountRepository.maxClients));
      expect(tester.takeException(), isNull);
    });
  });

  group('6: a future day stays guarded', () {
    testWidgets('no "+1" on a guarded cell; typing asks first', (tester) async {
      var asked = 0;
      int? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NumericField(
              value: 2,
              plusOne: PlusOne.always,
              onChanged: (v) => saved = v,
              confirmEdit: () async {
                asked++;
                return false;
              },
            ),
          ),
        ),
      );
      expect(find.byTooltip('Add one'), findsNothing);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(saved, isNull);
    });
  });

  group('7: Excel import never drops numbers quietly', () {
    test('"1,234" as text is read; a formula cell is reported', () {
      final weeks = WeekRepository(db);
      final w = weeks.createWeekFor(DateTime(2026, 9, 7));
      final counts = ClientCountRepository(db);
      final bytes = ExportService(counts.getWeekWithDays).exportWeek(w).bytes;
      final book = Excel.decodeBytes(bytes);
      final sheet = book.tables.values.first;
      // Joy's first row: New as text "1,234"; Ian's first row: a formula.
      CellIndex? cellFor(String name) {
        for (var r = 0; r < sheet.maxRows; r++) {
          final v = sheet.rows[r].isEmpty ? null : sheet.rows[r][0]?.value;
          if (v is TextCellValue && v.value.text == name) {
            return CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r);
          }
        }
        return null;
      }

      sheet.updateCell(cellFor('Joy')!, TextCellValue('1,234'));
      sheet.updateCell(cellFor('Ian')!, FormulaCellValue('=1+1'));
      final data = parseExcelImport(book.save()!);
      final monday = data.days.firstWhere(
        (d) => d.date == DateTime(2026, 9, 7),
      );
      expect(monday.entries['Joy']!.newClients, 1234);
      expect(monday.entries.containsKey('Ian'), isFalse);
      expect(
        data.warnings.where((w) => w.contains('Ian') && w.contains('formula')),
        isNotEmpty,
      );
    });
  });

  group('8: duplicates without a transaction code', () {
    test('same amount, day and payer → the same key', () {
      final a = parsePayments(_bank).single.copyWith(code: '');
      final b = parsePayments(_bank).single.copyWith(code: '');
      expect(a.code, isNull);
      final day = DateTime(2026, 11, 3, 9);
      expect(paymentDuplicateKey(a, day), isNotNull);
      expect(paymentDuplicateKey(a, day), paymentDuplicateKey(b, day));
      // Another day is another payment.
      expect(
        paymentDuplicateKey(a, day),
        isNot(paymentDuplicateKey(b, DateTime(2026, 11, 4))),
      );
    });
  });

  group('10: refunds aren’t payments', () {
    test('2 payments and a refund: 2 payments, net total', () {
      final repo = RevenueRepository(db);
      final day = DateTime(2026, 11, 2);
      repo.add(day, 100000);
      repo.add(day, 50000);
      repo.add(day, -30000);
      final d = repo.daysBetween(day, day).single;
      expect((d.count, d.entries, d.totalCents), (2, 3, 120000));
      final m = repo.monthsBetween(day, day).single;
      expect((m.count, m.totalCents), (2, 120000));

      final excel = Excel.createExcel();
      addRevenueSheets(
        excel,
        repo.entriesBetween(day, day),
        from: day,
        to: day,
        currency: 'KSh',
      );
      final byDay = excel['Revenue by day'];
      expect(byDay.rows[1][3]?.value.toString(), '2');
    });
  });

  group('12: same-name students keep their own history', () {
    test('two Jane Does swapped between uploads: no false changes', () {
      const header =
          'Student name,RTO name,Country,Doc submit date,App submitted date,'
          'Offer letter received date,COE issue date,Status,Assignee\n';
      const jane1 = 'Jane Doe,Reach,Australia,,,,,Awaiting offer letter,Joy\n';
      const jane2 = 'Jane Doe,NPA,Canada,,,,,To pay school fees,Ian\n';
      final repo = ApplicationRepository(db);
      repo.importCsv(header + jane1 + jane2);
      final again = repo.importCsv(header + jane2 + jane1);
      expect((again.added, again.changed, again.removed), (0, 0, 0));
    });

    test('applications stored under the old keys carry over quietly', () {
      final repo = ApplicationRepository(db);
      const header =
          'Student name,RTO name,Country,Doc submit date,App submitted date,'
          'Offer letter received date,COE issue date,Status,Assignee\n';
      repo.importCsv(
        '${header}Jane Doe,Reach,Australia,,,,,Awaiting offer letter,Joy\n'
        'Jane Doe,NPA,Canada,,,,,To pay school fees,Ian\n',
      );
      // As an older version stored them: by order in the file.
      db.raw.execute(
        "UPDATE applications SET app_key = 'jane doe' "
        "WHERE app_key = 'jane doe · reach · australia';",
      );
      db.raw.execute(
        "UPDATE applications SET app_key = 'jane doe #2' "
        "WHERE app_key = 'jane doe · npa · canada';",
      );
      final r = repo.importCsv(
        '${header}Jane Doe,NPA,Canada,,,,,To pay school fees,Ian\n'
        'Jane Doe,Reach,Australia,,,,,Awaiting offer letter,Joy\n',
      );
      expect((r.added, r.changed, r.removed), (0, 0, 0));
      expect(repo.all().map((a) => a.key), isNot(contains('jane doe')));
    });

    test('a unique name keeps the same key as before', () {
      final rows = ApplicationRepository.parseApplicationsCsv(
        'Student name,Status\nMary Wanjiku,Awaiting offer letter\n',
      );
      expect(rows.single.key, 'mary wanjiku');
    });
  });
}
