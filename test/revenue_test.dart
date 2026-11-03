import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/notes_settings_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
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
    expect(RevenueRepository(other).day(DateTime(2026, 11, 2)).totalCents, 5000);

    // A backup made before revenue existed leaves revenue alone.
    final old = jsonDecode(json) as Map<String, Object?>;
    (old['tables']! as Map).remove('revenue_entries');
    other.restoreFromJson(jsonEncode(old));
    expect(RevenueRepository(other).day(DateTime(2026, 11, 2)).totalCents, 5000);
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
          if (admin) adminSessionProvider.overrideWith(SignedInSession.new),
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
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
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
    expect(find.text('12,300'), findsOneWidget);
    expect(find.text('KSh'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-revenue')));
    await tester.pumpAndSettle();
    // The detail page: the transactions, and no way to add or remove.
    expect(find.text('Transactions'), findsOneWidget);
    expect(find.byKey(const ValueKey('revenue-amount')), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
