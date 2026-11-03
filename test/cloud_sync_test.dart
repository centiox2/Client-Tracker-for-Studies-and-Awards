import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/auth_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/cloud/cloud_api.dart';
import 'package:client_tracker/services/cloud/sync_engine.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/state/cloud_sync.dart';

/// An in-memory stand-in for the Supabase functions (same rules: anyone
/// reads, a token is needed to write, the first password claims).
class FakeCloud implements CloudApi {
  final tables = <String, Map<String, Map<String, Object?>>>{
    for (final t in AppDatabase.syncedTables.keys) t: {},
  };
  String? password;
  final tokens = <String>{};
  bool offline = false;
  final _changes = StreamController<CloudChange>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  /// Every change applied, as live updates other devices would receive.
  final emitted = <CloudChange>[];

  void _online() {
    if (offline) throw Exception('offline');
  }

  @override
  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    _online();
    return {
      for (final MapEntry(:key, :value) in tables.entries)
        key: [for (final r in value.values) Map.of(r)],
    };
  }

  @override
  Future<void> push(String token, Map<String, Object?> payload) async {
    _online();
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    final deletes = (payload['deletes'] as Map? ?? {}).cast<String, List>();
    final upserts = (payload['upserts'] as Map? ?? {}).cast<String, List>();
    for (final MapEntry(key: t, value: keys) in deletes.entries) {
      final pk = AppDatabase.syncedTables[t]!;
      for (final k in keys) {
        tables[t]!.remove('$k');
        final c = CloudChange(table: t, deleted: true, row: {pk: k});
        emitted.add(c);
        _changes.add(c);
      }
    }
    for (final t in AppDatabase.syncedTables.keys) {
      final pk = AppDatabase.syncedTables[t]!;
      for (final row in upserts[t] ?? const []) {
        final r = Map<String, Object?>.from(row as Map);
        tables[t]!['${r[pk]}'] = r;
        final c = CloudChange(table: t, deleted: false, row: r);
        emitted.add(c);
        _changes.add(c);
      }
    }
  }

  @override
  Future<String> adminStatus() async {
    _online();
    return password == null ? 'unclaimed' : 'claimed';
  }

  @override
  Future<String> claim(String p) async {
    _online();
    if (password != null) throw CloudException('already_claimed');
    password = p;
    return _token();
  }

  @override
  Future<String> login(String p) async {
    _online();
    if (p != password) throw CloudException('wrong_password');
    return _token();
  }

  String _token() {
    final t = 'token-${tokens.length}';
    tokens.add(t);
    return t;
  }

  @override
  Future<void> setPassword(String token, String p) async {
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    password = p;
  }

  @override
  Stream<CloudChange> changes() => _changes.stream;

  @override
  Stream<bool> connection() => _connection.stream;

  @override
  void dispose() {}
}

void main() {
  late AppDatabase admin;
  late AppDatabase boss;
  late FakeCloud cloud;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AuthRepository.iterations = 10;
    admin = openInMemoryDatabase();
    boss = openInMemoryDatabase();
    cloud = FakeCloud();
  });
  tearDown(() {
    admin.close();
    boss.close();
  });

  int staffId(AppDatabase db, String name) =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [name]).first['id']!
          as int;

  test('local edits are queued for upload automatically', () {
    final engine = SyncEngine(admin, cloud);
    admin.raw.execute('DELETE FROM sync_outbox;');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    expect(engine.pending, greaterThan(0));
    final before = engine.pending;
    ClientCountRepository(admin).saveCount(
      dayId: WeekRepository(admin).getDays(week.id).first.id,
      staffId: staffId(admin, 'Joy'),
      newClients: 2,
      existingClients: 1,
    );
    expect(engine.pending, greaterThan(before));
  });

  test(
    'the first admin device seeds the cloud; the boss downloads it',
    () async {
      final token = await cloud.claim('pass1234');
      final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
      final monday = WeekRepository(admin).getDays(week.id).first;
      ClientCountRepository(admin).saveCount(
        dayId: monday.id,
        staffId: staffId(admin, 'Joy'),
        newClients: 4,
        existingClients: 3,
      );
      final a = SyncEngine(admin, cloud);
      await a.pull(token: token);
      expect(a.connected, isTrue);
      expect(a.pending, 0);
      expect(cloud.tables['staff'], hasLength(14));
      expect(cloud.tables['weeks'], hasLength(1));

      // The boss's fresh device: its starter data is replaced by the cloud's.
      StaffRepository(boss).rename(staffId(boss, 'Joy'), 'Not Joy');
      final b = SyncEngine(boss, cloud);
      expect(await b.pull(), isTrue);
      expect(b.pending, 0, reason: 'nothing from the boss device goes up');
      final joy = staffId(boss, 'Joy');
      final day = WeekRepository(boss).getDays(week.id).first;
      expect(
        ClientCountRepository(boss).countValues(day.id, joy).newClients,
        4,
      );
    },
  );

  test('live: admin edits reach the boss, deletes too, without echo', () async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    final a = SyncEngine(admin, cloud);
    await a.pull(token: token);
    final b = SyncEngine(boss, cloud);
    await b.pull();
    final sub = cloud.changes().listen(b.apply);

    final day = WeekRepository(admin).getDays(week.id)[2];
    ClientCountRepository(admin).saveCount(
      dayId: day.id,
      staffId: staffId(admin, 'Ian'),
      newClients: 6,
      existingClients: 0,
    );
    await a.flush(token);
    await Future<void>.delayed(Duration.zero);
    expect(
      ClientCountRepository(boss)
          .countValues(day.id, staffId(boss, 'Ian'))
          .newClients,
      6,
    );
    expect(b.pending, 0, reason: 'applying cloud changes queues nothing');

    WeekRepository(admin).deleteWeek(week.id);
    await a.flush(token);
    await Future<void>.delayed(Duration.zero);
    expect(WeekRepository(boss).getAllWeeks(), isEmpty);
    await sub.cancel();
  });

  test('unsent local edits are never overwritten by cloud data', () async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    final a = SyncEngine(admin, cloud);
    await a.pull(token: token);
    final day = WeekRepository(admin).getDays(week.id).first;
    final joy = staffId(admin, 'Joy');
    final counts = ClientCountRepository(admin);
    counts.saveCount(
      dayId: day.id,
      staffId: joy,
      newClients: 12,
      existingClients: 0,
    );
    // A late cloud echo of an older value for the same row.
    final row = admin.raw.select(
      'SELECT * FROM client_counts WHERE day_id = ? AND staff_id = ?;',
      [day.id, joy],
    ).first;
    a.apply(
      CloudChange(
        table: 'client_counts',
        deleted: false,
        row: {...row, 'new_clients': 1},
      ),
    );
    expect(counts.countValues(day.id, joy).newClients, 12);
    // Offline: the change waits, then goes up.
    cloud.offline = true;
    await expectLater(a.flush(token), throwsException);
    expect(a.pending, greaterThan(0));
    cloud.offline = false;
    await a.flush(token);
    expect(a.pending, 0);
    final up = cloud.tables['client_counts']!.values.firstWhere(
      (r) => r['day_id'] == day.id && r['staff_id'] == joy,
    );
    expect(up['new_clients'], 12);
  });

  test('a restored backup is sent online as a whole', () async {
    final token = await cloud.claim('pass1234');
    final a = SyncEngine(admin, cloud);
    WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    await a.pull(token: token);
    final other = openInMemoryDatabase();
    addTearDown(other.close);
    WeekRepository(other).createWeekFor(DateTime(2026, 9, 7));
    WeekRepository(other).createWeekFor(DateTime(2026, 9, 14));
    admin.restoreFromJson(other.exportToJson());
    await a.flush(token);
    expect(cloud.tables['weeks'], hasLength(2));
    expect(
      cloud.tables['weeks']!.values.map((w) => w['start_date']),
      containsAll(['2026-09-07', '2026-09-14']),
    );
  });

  // -------------------------------------------------------- sign-in flow ---

  Future<ProviderContainer> pumpApp(WidgetTester tester, AppDatabase db) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cloudApiFactoryProvider.overrideWithValue(() => cloud),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('first admin sign-in claims the online password', (tester) async {
    final container = await pumpApp(tester, admin);
    expect(container.read(cloudSyncProvider).phase, SyncPhase.live);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    expect(find.text('Create the admin password'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'secret-1');
    await tester.enterText(fields.at(1), 'secret-1');
    await tester.tap(find.text('Create password and sign in'));
    await tester.pumpAndSettle();
    expect(cloud.password, 'secret-1');
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);
    // The staff list went up.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(cloud.tables['staff'], isNotEmpty);
    container.dispose(); // stops sync's timers, as closing the app would
  });

  testWidgets('a new device signs in with the online password', (tester) async {
    cloud.password = 'secret-1';
    final container = await pumpApp(tester, boss);
    expect(container.read(cloudSyncProvider).claimed, isTrue);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    // No "create a password" on this device: it signs in instead.
    expect(find.text('Create the admin password'), findsNothing);
    expect(find.text('Admin sign in'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password. Try again.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'secret-1');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), isTrue);
    // Remembered locally, so it also works offline next time.
    expect(AuthRepository(boss).verifyAdmin('secret-1'), isTrue);
    container.dispose();
  });
}
