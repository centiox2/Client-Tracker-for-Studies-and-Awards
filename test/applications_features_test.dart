import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/state/app_state.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  final today = DateTime.now();
  String ago(int days) =>
      DateFormat('MMMM d, y').format(today.subtract(Duration(days: days)));

  // Waiting 12 days (reminder), 3 days (not yet), has an offer, past the
  // offer stage, not submitted yet.
  String csv() =>
      'Student name,RTO name,Country,Doc submit date,App submitted date,'
      'Offer letter received date,COE issue date,Status,Assignee,To do list\n'
      'Alice Late,ECU,Australia,,"${ago(12)}",,,Awaiting offer letter,Joy,\n'
      'Ben Recent,AIBT,Australia,,"${ago(3)}",,,Awaiting offer letter,Ian,\n'
      'Cara Offered,KCBT,Australia,,"${ago(30)}","${ago(5)}",,'
      'To pay school fees,Joy,\n'
      'Dan Fees,SCU,Australia,,"${ago(40)}",,,To pay school fees,,\n'
      'Eve Draft,UOW,Australia,,,,,Statement building,Winnie,\n';

  test('the offer reminder rule', () {
    final repo = ApplicationRepository(db)..importCsv(csv());
    final by = {for (final a in repo.all()) a.student: a};
    expect(by['Alice Late']!.offerWaitDays(today), 12);
    expect(by['Alice Late']!.offerOverdue(today), isTrue);
    expect(by['Ben Recent']!.offerWaitDays(today), 3);
    expect(by['Ben Recent']!.offerOverdue(today), isFalse);
    expect(by['Cara Offered']!.offerWaitDays(today), isNull); // has an offer
    expect(by['Dan Fees']!.offerWaitDays(today), isNull); // past that stage
    expect(by['Eve Draft']!.offerWaitDays(today), isNull); // not submitted
    // Exactly 7 days is not yet "more than 7".
    expect(ApplicationRepository.offerReminderDays, 7);
  });

  Future<void> pumpApplications(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(() => _As(UserRole.admin)),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();
  }

  testWidgets('reminders in Quick view and on the application', (tester) async {
    ApplicationRepository(db).importCsv(csv());
    await pumpApplications(tester);

    final panel = find.byKey(const ValueKey('offer-reminders'));
    expect(panel, findsOneWidget);
    expect(find.text('1 waiting'), findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.text('Alice Late')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('Ben Recent')),
      findsNothing,
    );
    expect(
      find.descendant(of: panel, matching: find.text('12 days')),
      findsOneWidget,
    );

    // Opening it shows the reminder on the application itself.
    await tester.tap(find.byKey(const ValueKey('offer-wait-alice late')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-reminder')), findsOneWidget);
    expect(find.text('Waiting 12 days for an offer letter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('All applications: sort and filter', (tester) async {
    ApplicationRepository(db).importCsv(csv());
    await pumpApplications(tester);
    await tester.tap(find.text('All applications'));
    await tester.pumpAndSettle();

    double top(String name) => tester.getTopLeft(find.text(name).last).dy;

    // Sort by name: one flat list, A to Z.
    await tester.tap(find.byKey(const ValueKey('applications-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Student name (A–Z)').last);
    await tester.pumpAndSettle();
    expect(top('Alice Late'), lessThan(top('Ben Recent')));
    expect(top('Ben Recent'), lessThan(top('Cara Offered')));
    expect(top('Dan Fees'), lessThan(top('Eve Draft')));

    // Applied, oldest first: Dan (40 days) before Alice (12).
    await tester.tap(find.byKey(const ValueKey('applications-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Applied: oldest first').last);
    await tester.pumpAndSettle();
    expect(top('Dan Fees'), lessThan(top('Alice Late')));
    expect(top('Alice Late'), lessThan(top('Ben Recent')));

    // Only the overdue offer letters.
    await tester.tap(find.byKey(const ValueKey('applications-offer-overdue')));
    await tester.pumpAndSettle();
    expect(find.text('Alice Late'), findsOneWidget);
    expect(find.text('Ben Recent'), findsNothing);
    expect(find.text('Offer: 12 days'), findsOneWidget);
    expect(find.text('1 of 5'), findsOneWidget);

    // Clear, then filter by institution.
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Ben Recent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _As extends SessionNotifier {
  _As(this.role);
  final UserRole role;
  @override
  UserRole? build() => role;
}
