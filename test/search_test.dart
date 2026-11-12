import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/services/search_text.dart';
import 'package:client_tracker/state/app_state.dart';

/// Search ignores punctuation, and quick search finds a client from any
/// page and opens their card.
void main() {
  group('TextSearch', () {
    test('ignores case, accents, commas and full stops', () {
      expect(searchKey("O'Brien, Mary."), 'obrien mary');
      expect(searchKey('José-Luis'), 'jose luis');
      expect(TextSearch('obrien').matches('O. Brien'), isTrue);
      expect(TextSearch("o'brien").matches('OBrien Mary'), isTrue);
      expect(TextSearch('Mary, Wanjiku').matches('Wanjiku Mary'), isTrue);
      expect(TextSearch('mary.').matches('Mary Wanjiku'), isTrue);
      expect(TextSearch('peter').matches('Mary Wanjiku'), isFalse);
    });

    test('an empty or punctuation-only search matches everything', () {
      expect(TextSearch('').isEmpty, isTrue);
      expect(TextSearch(' ,. ').isEmpty, isTrue);
      expect(TextSearch(',').matches('anything'), isTrue);
    });

    test('every word must be found, across fields', () {
      final s = TextSearch('ecu joy');
      expect(s.matchesAny(['Alice', 'ECU', 'Joy']), isTrue);
      expect(s.matchesAny(['Alice', 'ECU', 'Ian']), isFalse);
    });
  });

  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  const csv =
      'Student name,RTO name,Country,Doc submit date,App submitted date,'
      'Offer letter received date,COE issue date,Status,Assignee,To do list\n'
      "Siobhan O'Brien,ECU,Australia,,,,,Statement building,Joy,\n"
      'Ben Otieno,AIBT,Australia,,,,,Awaiting offer letter,Ian,\n';

  Future<void> pumpAs(WidgetTester tester, UserRole role) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(() => _As(role)),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('quick search finds a client without the apostrophe and opens '
      'their card', (tester) async {
    ApplicationRepository(db).importCsv(csv);
    await pumpAs(tester, UserRole.admin);
    await openSearch(tester);
    await tester.enterText(find.byType(TextField).last, 'obrien');
    await tester.pumpAndSettle();
    expect(find.text('CLIENTS'), findsOneWidget);
    expect(find.text("Siobhan O'Brien"), findsOneWidget);
    expect(find.text('Ben Otieno'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // The client's card is open, over the page the search started on.
    expect(find.text("Siobhan O'Brien"), findsWidgets);
    expect(find.text('ECU'), findsWidgets);
    expect(find.textContaining('Search clients, staff, weeks'), findsNothing);
  });

  testWidgets('view-only accounts can search too', (tester) async {
    ApplicationRepository(db).importCsv(csv);
    await pumpAs(tester, UserRole.director);
    await openSearch(tester);
    expect(find.textContaining('Search clients, staff, weeks'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'otieno');
    await tester.pumpAndSettle();
    expect(find.text('Ben Otieno'), findsOneWidget);
    // Nothing that changes data is offered.
    expect(find.text('New week…'), findsNothing);
  });
}

class _As extends SessionNotifier {
  _As(this.role);
  final UserRole role;
  @override
  UserRole? build() => role;
}
