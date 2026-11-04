import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/notes_settings_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/services/photo_text.dart';
import 'package:client_tracker/screens/revenue/scan_payments.dart';
import 'package:client_tracker/screens/revenue/revenue_screen.dart';

import 'dart:io';

import 'package:client_tracker/state/app_state.dart';

import 'test_helpers.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  test('amounts are read the way people type them', () {
    expect(RevenueRepository.parseAmount('1500'), 150000);
    expect(RevenueRepository.parseAmount('1,500'), 150000);
    expect(RevenueRepository.parseAmount('1,500.5'), 150050);
    expect(RevenueRepository.parseAmount('KSh 2 000.25'), 200025);
    expect(RevenueRepository.parseAmount('0'), isNull);
    expect(RevenueRepository.parseAmount(''), isNull);
    expect(RevenueRepository.parseAmount('1.2.3'), isNull);
    expect(RevenueRepository.parseAmount('10.999'), isNull);
    expect(formatMoney(4530000, 'KSh'), 'KSh 45,300');
    expect(formatMoney(150050, 'KSh'), 'KSh 1,500.50');
    expect(formatMoney(0, 'USD'), 'USD 0');
  });

  test('a day total adds up its transactions; other days stay apart', () {
    final repo = RevenueRepository(db);
    final monday = DateTime(2026, 11, 2);
    final tuesday = DateTime(2026, 11, 3);
    repo.add(monday, 150000, note: 'M-Pesa');
    final id = repo.add(monday, 25000);
    repo.add(tuesday, 99900);

    expect(repo.day(monday).totalCents, 175000);
    expect(repo.day(monday).count, 2);
    expect(repo.day(tuesday).totalCents, 99900);

    repo.update(id, amountCents: 30000, note: '  Cash   deposit ');
    expect(repo.day(monday).totalCents, 180000);
    expect(repo.entriesFor(monday).last.note, 'Cash deposit');

    final entry = repo.entriesFor(monday).first;
    repo.delete(entry.id);
    expect(repo.day(monday).totalCents, 30000);
    repo.restore(entry);
    expect(repo.day(monday).totalCents, 180000);

    final week = repo.daysBetween(monday, DateTime(2026, 11, 8));
    expect(week, hasLength(7));
    expect(week.map((d) => d.totalCents), [180000, 99900, 0, 0, 0, 0, 0]);
    expect(() => repo.add(monday, 0), throwsArgumentError);
  });

  test('revenue syncs, and travels with backups', () {
    expect(AppDatabase.syncedTables['revenue_entries'], 'id');
    RevenueRepository(db).add(DateTime(2026, 11, 2), 5000);
    final queued = db.raw.select(
      "SELECT COUNT(*) AS c FROM sync_outbox WHERE tbl = 'revenue_entries';",
    );
    expect(queued.first['c'], 1);

    final json = db.exportToJson();
    final other = openInMemoryDatabase();
    addTearDown(other.close);
    other.restoreFromJson(json);
    expect(
      RevenueRepository(other).day(DateTime(2026, 11, 2)).totalCents,
      5000,
    );

    // A backup made before revenue existed leaves revenue alone.
    final old = jsonDecode(json) as Map<String, Object?>;
    (old['tables']! as Map).remove('revenue_entries');
    other.restoreFromJson(jsonEncode(old));
    expect(
      RevenueRepository(other).day(DateTime(2026, 11, 2)).totalCents,
      5000,
    );
  });

  test('two devices adding before they sync never pick the same id', () {
    // The phone and the PC each add entries while apart. Ids used to be
    // 1, 2, 3… per device, so online one entry replaced the other.
    final phone = openInMemoryDatabase();
    addTearDown(phone.close);
    final day = DateTime(2026, 11, 3);
    final pcIds = [
      for (var i = 0; i < 50; i++) RevenueRepository(db).add(day, 1000 + i),
    ];
    final phoneIds = [
      for (var i = 0; i < 50; i++) RevenueRepository(phone).add(day, 2000 + i),
    ];
    expect({...pcIds, ...phoneIds}, hasLength(100));
    // Still in creation order, and exact as JSON numbers (below 2^53).
    expect(pcIds, orderedEquals([...pcIds]..sort()));
    expect(phoneIds.last, lessThan(9007199254740992));

    // The same holds for client numbers, weeks and staff.
    final staffA = StaffRepository(db).add('New A');
    final staffB = StaffRepository(phone).add('New B');
    expect(staffA, isNot(staffB));
  });

  test('a code read with 0 for O still counts as already added', () {
    final repo = RevenueRepository(db);
    repo.add(DateTime(2026, 11, 3), 4574000, note: 'M-Pesa · UK3JPO8PVA');
    expect(repo.existingCodes(['UK3JP08PVA', 'ZZ9ZZ99ZZZ']), {'UK3JP08PVA'});
  });

  test('currency defaults to KSh and can be changed', () {
    final settings = AppSettingsRepository(db);
    expect(settings.currency, 'KSh');
    settings.currency = 'USD';
    expect(settings.currency, 'USD');
    settings.currency = '';
    expect(settings.currency, 'KSh');
  });

  Future<void> pumpApp(WidgetTester tester, {required bool admin}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          adminSessionProvider.overrideWith(
            admin ? SignedInSession.new : DirectorSession.new,
          ),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('admin types transactions and the day total adds up', (
    tester,
  ) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    expect(find.text('Revenue today'), findsOneWidget);
    expect(find.text('KSh 0'), findsWidgets);

    final amount = find.byKey(const ValueKey('revenue-amount'));
    await tester.enterText(amount, '1,500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(amount, '250.50');
    await tester.enterText(find.byKey(const ValueKey('revenue-note')), 'Cash');
    // Enter in the note field adds it too.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(RevenueRepository(db).day(today()).totalCents, 175050);
    expect(find.text('KSh 1,750.50'), findsWidgets);
    expect(find.text('2 transactions'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);

    // Nonsense is refused with a message, nothing saved.
    await tester.enterText(amount, '...');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter an amount'), findsOneWidget);
    expect(RevenueRepository(db).day(today()).count, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Quick view shows today’s revenue to the boss, read-only', (
    tester,
  ) async {
    RevenueRepository(db)
      ..add(today(), 1000000)
      ..add(today(), 230000);
    await pumpApp(tester, admin: false);

    expect(find.text('Revenue today'), findsOneWidget);
    // The currency is a small label before the number, like a unit.
    // Today, this week and this month all show it.
    expect(find.text('12,300'), findsNWidgets(3));
    expect(find.text('KSh'), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('quick-revenue')));
    await tester.pumpAndSettle();
    // The detail page: the transactions, and no way to add or remove.
    expect(find.text('Transactions'), findsOneWidget);
    expect(find.byKey(const ValueKey('revenue-amount')), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pasted M-Pesa message is read, checked and added once', (
    tester,
  ) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    // Scan photo shows where photos can be read (phones, Windows); Paste
    // message is always there.
    expect(
      find.byKey(const ValueKey('scan-photo')),
      photoTextSupported ? findsOneWidget : findsNothing,
    );
    expect(find.byKey(const ValueKey('paste-payment')), findsOneWidget);

    const sms =
        'UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM Ksh45,740.00 received '
        'from DAVID KIMURKONG KANGOGO 254722699840. Account Number Leonorah '
        'Cherop New Utility balance is Ksh106,520.00';
    Future<void> paste() async {
      await tester.tap(find.byKey(const ValueKey('paste-payment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('paste-message')), sms);
      await tester.tap(find.widgetWithText(FilledButton, 'Read'));
      await tester.pumpAndSettle();
    }

    await paste();
    expect(find.text('Payment found'), findsOneWidget);
    expect(find.text('KSh 45,740'), findsOneWidget);
    expect(find.textContaining('KSh 106,520'), findsNothing);
    Finder dialogAdd() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Add'),
    );
    await tester.tap(dialogAdd());
    await tester.pumpAndSettle();

    final day = DateTime(2026, 11, 3);
    final saved = RevenueRepository(db).entriesFor(day);
    expect(saved.single.amountCents, 4574000);
    expect(saved.single.note, contains('UK3JPO8PVA'));
    expect(saved.single.note, isNot(contains('254722699840')));

    // The same message again: flagged and not ticked.
    await paste();
    expect(find.text('Already added'), findsOneWidget);
    final add = tester.widget<FilledButton>(dialogAdd());
    expect(add.onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(RevenueRepository(db).entriesFor(day), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a batch: same payment twice is caught, each timed by its '
      'message', (tester) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final y = now.subtract(const Duration(days: 1));
    String d(DateTime t) => '${t.day}/${t.month}/${t.year % 100}';
    // Two overlapping screenshots show today's payment twice; yesterday's
    // is in there too.
    final text =
        'UK3JPO8PVA Confirmed. on ${d(now)} at 1:38 AM Ksh45,740.00 received '
        'from DAVID KANGOGO 254722699840. New Utility balance is Ksh9.00\n'
        'UK3JP08PVA Confirmed. on ${d(now)} at 1:38 AM Ksh45,740.00 received '
        'from DAVID KANGOGO 254722699840. New Utility balance is Ksh9.00\n'
        'TJ2AB34CDE Confirmed. on ${d(y)} at 4:05 PM Ksh1,200.00 received '
        'from JANE W 254711000111. New Utility balance is Ksh1.00';
    await tester.tap(find.byKey(const ValueKey('paste-payment')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('paste-message')), text);
    await tester.tap(find.widgetWithText(FilledButton, 'Read'));
    await tester.pumpAndSettle();

    expect(find.text('3 payments found'), findsOneWidget);
    expect(find.text('Same payment as above'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Add 2 · KSh 46,940'),
      ),
    );
    await tester.pumpAndSettle();

    final repo = RevenueRepository(db);
    final today = repo.entriesFor(DateTime(now.year, now.month, now.day));
    final yesterday = repo.entriesFor(DateTime(y.year, y.month, y.day));
    expect(today.single.amountCents, 4574000);
    expect(today.single.createdAt.hour, 1);
    expect(today.single.createdAt.minute, 38);
    expect(yesterday.single.amountCents, 120000);
    expect(yesterday.single.createdAt.hour, 16);
    expect(find.textContaining('across 2 days'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older message lands on its own date, with the year shown', (
    tester,
  ) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paste-payment')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('paste-message')),
      'QF71ABC2XY Confirmed. on 14/2/23 at 9:05 AM Ksh3,500.00 received from '
      'MARY W 254700111222. New Utility balance is Ksh10.00',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Read'));
    await tester.pumpAndSettle();
    expect(find.textContaining('14 Feb 2023, 9:05 AM'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Add'),
      ),
    );
    await tester.pumpAndSettle();
    final e = RevenueRepository(db).entriesFor(DateTime(2023, 2, 14)).single;
    expect(e.createdAt, DateTime(2023, 2, 14, 9, 5));
  });

  testWidgets('typed transactions take the date and time boxes', (
    tester,
  ) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('revenue-date')), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);

    // Pick 9:30 AM in the time picker (typing it in).
    await tester.tap(find.byKey(const ValueKey('revenue-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '9');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('AM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('9:30 AM'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('revenue-amount')),
      '2,000',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final e = RevenueRepository(db).entriesFor(today()).single;
    expect(e.createdAt.hour, 9);
    expect(e.createdAt.minute, 30);
    // Back to "now" for the next one.
    expect(find.text('Now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Insights: this month, charts and how people pay', (
    tester,
  ) async {
    final repo = RevenueRepository(db);
    repo.add(today(), 1000000, note: 'M-Pesa · Jane · AB12CD34EF');
    repo.add(today(), 300000, note: 'Cash');
    await pumpApp(tester, admin: false);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insights'));
    await tester.pumpAndSettle();

    expect(find.text('KSh 13,000'), findsWidgets); // month so far, best day
    expect(find.text('Average payment'), findsOneWidget);
    expect(find.text('KSh 6,500'), findsOneWidget);
    expect(find.text('By day'), findsOneWidget);
    expect(find.textContaining('12 months to'), findsOneWidget);
    // The same numbers as a table.
    await tester.tap(find.byTooltip('Show as table').first);
    await tester.pumpAndSettle();
    expect(find.text('Payments'), findsOneWidget);
    // A year: monthly bars instead of daily.
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('By month'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('M-Pesa'), 300);
    expect(find.text('Cash'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide screens show the photo beside what was read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          adminSessionProvider.overrideWith(SignedInSession.new),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    final screen = tester.state<ConsumerState<RevenueScreen>>(
      find.byType(RevenueScreen),
    );
    final path = File('test/fixtures/mpesa_sample.png').absolute.path;
    // ignore: invalid_use_of_visible_for_testing_member
    reviewPhotoTexts(screen.context, screen.ref, today(), [
      PhotoText(
        path,
        text:
            'UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM Ksh45,740.00 '
            'received from JOHN PAYER 254700000000. New Utility balance is '
            'Ksh1.00',
      ),
      PhotoText('${path}2', error: 'Unreadable'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('mpesa_sample.png · photo 1 of 2'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Next photo'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('mpesa_sample.png2 · photo 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));
  });

  test('refunds, purposes, history and search', () {
    final repo = RevenueRepository(db);
    final day = DateTime(2026, 11, 2);
    final a = repo.add(
      day,
      4574000,
      note: 'M-Pesa · David Kangogo · Acc: Leonorah · UK3JPO8PVA',
      purpose: 'Visa fee',
    );
    repo.add(day, 150000, note: 'Cash', purpose: 'Consultation');
    final refund = repo.add(day, -50000, note: 'Refund to David');
    // Totals are net of refunds.
    expect(repo.day(day).totalCents, 4574000 + 150000 - 50000);
    expect(repo.entry(refund)!.isRefund, isTrue);
    expect(repo.entry(a)!.purpose, 'Visa fee');

    repo.update(
      a,
      amountCents: 4500000,
      note: 'M-Pesa · David Kangogo · Acc: Leonorah · UK3JPO8PVA',
      at: DateTime(2026, 11, 3, 9),
    );
    final gone = repo.entry(refund)!;
    repo.delete(refund);
    repo.restore(gone);
    final history = repo.changes();
    expect(history.map((c) => c.action).take(4), [
      'restored',
      'deleted',
      'edited',
      'added',
    ]);
    final edit = history[2];
    expect(edit.oldAmountCents, 4574000);
    expect(edit.amountCents, 4500000);
    expect(edit.oldDate, day);
    expect(edit.date, DateTime(2026, 11, 3));

    // Search: names, codes (O or 0), amounts and purposes, on any date.
    expect(repo.search('david kangogo').single.id, a); // every word
    expect(repo.search('david').length, 2); // the payment and the refund
    expect(repo.search('UK3JP08PVA').single.id, a);
    expect(repo.search('45,000').single.id, a);
    expect(repo.search('consultation').single.note, 'Cash');
    expect(repo.search('nobody'), isEmpty);
  });

  testWidgets('a batch from photos can be undone in one tap', (tester) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    final now = DateTime.now();
    String d(DateTime t) => '${t.day}/${t.month}/${t.year % 100}';
    await tester.tap(find.byKey(const ValueKey('paste-payment')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('paste-message')),
      'UK3JPO8PVA Confirmed. on ${d(now)} at 1:38 AM Ksh1,000.00 received '
      'from A B 254700000000. New Utility balance is Ksh1.00\n'
      'TJ2AB34CDE Confirmed. on ${d(now)} at 2:05 AM Ksh2,000.00 received '
      'from C D 254711000111. New Utility balance is Ksh1.00',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Read'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Add 2 · KSh 3,000'),
      ),
    );
    await tester.pumpAndSettle();
    expect(RevenueRepository(db).day(today()).count, 2);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(RevenueRepository(db).day(today()).count, 0);
  });

  testWidgets('the Undo card goes away by itself', (tester) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final d = '${now.day}/${now.month}/${now.year % 100}';
    await tester.tap(find.byKey(const ValueKey('paste-payment')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('paste-message')),
      'UK3JPO8PVA Confirmed. on $d at 1:38 AM Ksh1,000.00 received '
      'from A B 254700000000.\n'
      'TJ2AB34CDE Confirmed. on $d at 2:05 AM Ksh2,000.00 received '
      'from C D 254711000111.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Read'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Add 2 · KSh 3,000'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    expect(RevenueRepository(db).day(today()).count, 2);
  });

  testWidgets('a payment’s details can be corrected as fields', (tester) async {
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paste-payment')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('paste-message')),
      'Ref:AC4597897426: Dear EVELYNE, You have received KES 3000 on your '
      'M-Pesa from PIUS-6145****354 at 03-10-2026 10:53 AM.The M-Pesa '
      'receipt number is:UJ3H98O13S. We Are You!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Read'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 Oct, 10:53 AM'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-payment-0')));
    await tester.pumpAndSettle();
    expect(find.text('Payment details'), findsOneWidget);
    expect(find.text('Sat 3 Oct 2026'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('detail-amount')), '3500');
    await tester.enterText(
      find.byKey(const ValueKey('detail-payer')),
      'Pius Otieno',
    );
    await tester.tap(find.byKey(const ValueKey('detail-save')));
    await tester.pumpAndSettle();
    expect(find.text('KSh 3,500'), findsOneWidget);
    expect(find.text('From Pius Otieno'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Add'),
      ),
    );
    await tester.pumpAndSettle();
    final saved = RevenueRepository(db).entriesFor(DateTime(2026, 10, 3));
    expect(saved.single.amountCents, 350000);
    expect(saved.single.note, 'M-Pesa · Pius Otieno · UJ3H98O13S');
    expect(saved.single.createdAt, DateTime(2026, 10, 3, 10, 53));
    expect(tester.takeException(), isNull);
  });

  testWidgets('All: older transactions are listed by month and can be edited', (
    tester,
  ) async {
    final repo = RevenueRepository(db);
    final now = DateTime.now();
    final lastMonth = DateTime(now.year, now.month - 1, 12);
    repo.add(lastMonth, 420000, note: 'M-Pesa · Old Payer · QWE123RTY9');
    repo.add(today(), 10000, note: 'Cash');
    await pumpApp(tester, admin: true);
    await tester.tap(find.text('Revenue').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Cash'), findsOneWidget);
    expect(find.textContaining('Old Payer'), findsNothing);

    await tester.tap(find.byTooltip('Earlier month'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Old Payer'), findsOneWidget);
    expect(find.text('KSh 4,200'), findsWidgets);

    // Tap it: the edit dialog opens on it.
    await tester.tap(find.textContaining('Old Payer'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Search finds it from any month.
    await tester.tap(find.text('This month'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('all-revenue-search')),
      'qwe123',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Old Payer'), findsOneWidget);
    expect(find.text('Cash'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
