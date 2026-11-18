import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/state/mobile_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Person extends CurrentUserNotifier {
  _Person(this.user);
  final AppUser user;
  @override
  AppUser? build() => user;
}

const _admin = AppUser(
  id: 1,
  username: 'amina',
  fullName: 'Amina',
  role: UserRole.admin,
);
const _other = AppUser(
  id: 2,
  username: 'joy',
  fullName: 'Joy',
  role: UserRole.admin,
);

void main() {
  late ProviderContainer container;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        accountsEnabledProvider.overrideWithValue(true),
        currentUserProvider.overrideWith(() => _Person(_admin)),
      ],
    );
    addTearDown(container.dispose);
  });

  test('custom order persists and switching people keeps separate choices', () {
    const chosen = [AppTab.todo, AppTab.dailyReports, AppTab.applications];
    container.read(mobileNavigationProvider.notifier).save(chosen);
    expect(container.read(mobileBarTabsProvider), chosen);
    container.invalidate(mobileNavigationProvider);
    expect(container.read(mobileBarTabsProvider), chosen);
    container.read(currentUserProvider.notifier).signedIn(_other);
    expect(container.read(mobileNavigationProvider), isNull);
    container.read(mobileNavigationProvider.notifier).save([AppTab.history]);
    container.read(currentUserProvider.notifier).signedIn(_admin);
    expect(container.read(mobileBarTabsProvider), chosen);
  });

  test(
    'revoked access removes a saved destination and provides a safe fallback',
    () {
      container.read(mobileNavigationProvider.notifier).save([AppTab.revenue]);
      container
          .read(currentUserProvider.notifier)
          .update(
            const AppUser(
              id: 1,
              username: 'amina',
              fullName: 'Amina',
              role: UserRole.admin,
              pages: {'applications'},
            ),
          );
      expect(
        container.read(availableAppTabsProvider),
        isNot(contains(AppTab.revenue)),
      );
      expect(
        container.read(mobileBarTabsProvider),
        isNot(contains(AppTab.revenue)),
      );
      expect(container.read(mobileBarTabsProvider), isNotEmpty);
    },
  );

  test('empty or excessive choices are refused, duplicates are removed', () {
    final settings = container.read(mobileNavigationProvider.notifier);
    expect(() => settings.save([]), throwsArgumentError);
    expect(
      () => settings.save(AppTab.values.take(5).toList()),
      throwsArgumentError,
    );
    settings.save([AppTab.todo, AppTab.todo, AppTab.history]);
    expect(container.read(mobileBarTabsProvider), [
      AppTab.todo,
      AppTab.history,
    ]);
    settings.reset();
    expect(container.read(mobileNavigationProvider), isNull);
    container.invalidate(mobileNavigationProvider);
    expect(container.read(mobileNavigationProvider), isNull);
  });

  testWidgets(
    'phone settings save a reordered bar and More still opens other pages',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      container.read(navTabProvider.notifier).set(AppTab.settings);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ClientTrackerApp(),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tapKey(String key) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tapKey('customize-navigation');
      await tapKey('nav-remove-reports');
      await tapKey('nav-add-todo');
      await tapKey('nav-up-todo');
      await tapKey('nav-save');
      expect(container.read(mobileBarTabsProvider), [
        AppTab.home,
        AppTab.applications,
        AppTab.todo,
        AppTab.week,
      ]);
      final bar = find.byType(NavigationBar);
      expect(
        find.descendant(of: bar, matching: find.text('To-do')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('More pages'));
      await tester.pumpAndSettle();
      expect(find.text('Revenue'), findsOneWidget);
      await tester.tap(find.text('Revenue'));
      await tester.pumpAndSettle();
      expect(container.read(navTabProvider), AppTab.revenue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
