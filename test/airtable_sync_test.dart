import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/application_repository.dart';
import 'package:client_tracker/services/airtable_sync_service.dart';
import 'package:client_tracker/services/cloud/cloud_api.dart';
import 'package:client_tracker/state/app_state.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryDatabase());
  tearDown(() => db.close());

  final sample = File('test/fixtures/applications_sample.csv')
      .readAsStringSync();

  Map<String, Object?> statusJson({
    int calls = 12,
    String? error,
    String? errorAt,
    String okAt = '2026-11-10T11:34:23.44+00:00',
  }) => {
    'enabled': true,
    'last_ok_at': okAt,
    'last_full_at': '2026-11-10T11:33:52.76+00:00',
    'last_error': error,
    'last_error_at': errorAt,
    'calls_this_month': calls,
    'limit': 1000,
    'slow_at': 700,
    'stop_at': 850,
    'manual_stop_at': 980,
  };

  test('reads the online status and results', () {
    final s = AirtableStatus.fromJson(statusJson());
    expect(s.enabled, isTrue);
    expect(s.callsThisMonth, 12);
    expect(s.lastOkAt, DateTime.utc(2026, 11, 10, 11, 34, 23, 440).toLocal());
    expect(s.failing, isFalse);
    expect(s.slowedDown, isFalse);
    expect(AirtableStatus.fromJson(statusJson(calls: 720)).slowedDown, isTrue);
    expect(AirtableStatus.fromJson(statusJson(calls: 850)).paused, isTrue);

    // A failure after the last good run is "failing"; an old one isn't.
    expect(
      AirtableStatus.fromJson(
        statusJson(
          error: 'airtable_token_rejected',
          errorAt: '2026-11-10T12:00:00+00:00',
        ),
      ).failing,
      isTrue,
    );
    expect(
      AirtableStatus.fromJson(
        statusJson(
          error: 'airtable_token_rejected',
          errorAt: '2026-11-10T10:00:00+00:00',
        ),
      ).failing,
      isFalse,
    );

    final r = AirtableSyncResult.fromJson({
      'total': 521,
      'changed': 4,
      'removed': 1,
      'calls': 1,
      'full': false,
    });
    expect((r.total, r.changed, r.removed, r.calls), (521, 4, 1, 1));
    expect(r.nothingChanged, isFalse);
    expect(AirtableSyncResult.fromJson({'skipped': 'busy'}).skipped, 'busy');
  });

  test('plain messages for sync problems', () {
    expect(
      describeAirtableError(CloudException('airtable_budget')),
      contains('used up'),
    );
    expect(
      describeAirtableError('airtable_token_rejected: Invalid token'),
      contains('token'),
    );
    expect(describeAirtableError(Exception('offline')), contains('internet'));
  });

  test('Sync now and the status go to the online functions', () async {
    final calls = <String, Map<String, Object?>?>{};
    var synced = 0;
    final service = AirtableSyncService(
      (name, [params]) async {
        calls[name] = params;
        return statusJson();
      },
      (name, [params]) async {
        calls[name] = params;
        return {'total': 3, 'changed': 1, 'calls': 1};
      },
      onSynced: () => synced++,
    );
    expect((await service.status()).enabled, isTrue);
    final r = await service.syncNow(full: true);
    expect(r.changed, 1);
    expect(calls['airtable_sync_now'], {'p_full': true});
    expect(calls.containsKey('airtable_status'), isTrue);
    expect(synced, 1);
  });

  Future<List<bool>> pumpApp(
    WidgetTester tester,
    UserRole role, {
    required AirtableStatus? status,
  }) async {
    final fulls = <bool>[];
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(() => _As(role)),
          airtableStatusProvider.overrideWith((ref) async => status),
          airtableSyncProvider.overrideWithValue(
            AirtableSyncService((name, [params]) async => statusJson(), (
              name, [
              params,
            ]) async {
              fulls.add(params?['p_full'] == true);
              return {'total': 8, 'changed': 2, 'added': 1, 'calls': 1};
            }),
          ),
        ],
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Applications').first);
    await tester.pumpAndSettle();
    return fulls;
  }

  testWidgets('with Airtable on: Sync now, and the CSV as a fallback', (
    tester,
  ) async {
    ApplicationRepository(db).importCsv(sample);
    final fulls = await pumpApp(
      tester,
      UserRole.adminTeam,
      status: AirtableStatus.fromJson(statusJson()),
    );
    expect(find.textContaining('Synced from Airtable'), findsOneWidget);
    expect(find.byKey(const ValueKey('upload-applications')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-airtable')));
    await tester.pumpAndSettle();
    expect(fulls, [false]);
    expect(find.text('2 updated · 1 new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failing sync shows a warning to those who can fix it', (
    tester,
  ) async {
    ApplicationRepository(db).importCsv(sample);
    await pumpApp(
      tester,
      UserRole.admin,
      status: AirtableStatus.fromJson(
        statusJson(
          error: 'airtable_token_rejected',
          errorAt: '2026-11-10T12:00:00+00:00',
        ),
      ),
    );
    expect(find.text('Airtable sync isn’t working'), findsOneWidget);
  });

  testWidgets('without Airtable: the CSV upload as before; viewers see none', (
    tester,
  ) async {
    ApplicationRepository(db).importCsv(sample);
    await pumpApp(tester, UserRole.adminTeam, status: null);
    expect(find.byKey(const ValueKey('sync-airtable')), findsNothing);
    expect(find.text('Upload CSV'), findsOneWidget);
  });

  testWidgets('viewers see when it synced, but no buttons', (tester) async {
    ApplicationRepository(db).importCsv(sample);
    await pumpApp(
      tester,
      UserRole.director,
      status: AirtableStatus.fromJson(statusJson()),
    );
    expect(find.textContaining('Synced from Airtable'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-airtable')), findsNothing);
  });
}

class _As extends SessionNotifier {
  _As(this.role);
  final UserRole role;
  @override
  UserRole? build() => role;
}
