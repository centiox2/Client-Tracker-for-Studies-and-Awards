import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';

/// How the online database's Airtable sync is doing (it reads the
/// Applications Tracker itself: what changed every 30 minutes in working
/// hours, everything at night).
class AirtableStatus {
  const AirtableStatus({
    required this.enabled,
    this.lastOkAt,
    this.lastFullAt,
    this.lastError,
    this.lastErrorAt,
    this.callsThisMonth = 0,
    this.limit = 1000,
    this.slowAt = 700,
    this.stopAt = 850,
    this.manualStopAt = 980,
  });

  final bool enabled;
  final DateTime? lastOkAt;
  final DateTime? lastFullAt;

  /// The last run's problem, if it failed (cleared by the next good run).
  final String? lastError;
  final DateTime? lastErrorAt;

  /// Airtable API calls this month (Kenya time). Airtable's free plan
  /// allows [limit] a month.
  final int callsThisMonth;
  final int limit;

  /// From here the schedule reads once an hour instead of every 30 minutes;
  /// from [stopAt] it waits for next month; "Sync now" works until
  /// [manualStopAt].
  final int slowAt;
  final int stopAt;
  final int manualStopAt;

  /// The last run failed (and nothing has worked since).
  bool get failing =>
      lastError != null &&
      (lastOkAt == null ||
          (lastErrorAt != null && lastErrorAt!.isAfter(lastOkAt!)));

  bool get slowedDown => callsThisMonth >= slowAt && callsThisMonth < stopAt;
  bool get paused => callsThisMonth >= stopAt;

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static AirtableStatus fromJson(Map<String, Object?> j) => AirtableStatus(
    enabled: j['enabled'] == true,
    lastOkAt: _time(j['last_ok_at']),
    lastFullAt: _time(j['last_full_at']),
    lastError: j['last_error'] as String?,
    lastErrorAt: _time(j['last_error_at']),
    callsThisMonth: (j['calls_this_month'] as num?)?.toInt() ?? 0,
    limit: (j['limit'] as num?)?.toInt() ?? 1000,
    slowAt: (j['slow_at'] as num?)?.toInt() ?? 700,
    stopAt: (j['stop_at'] as num?)?.toInt() ?? 850,
    manualStopAt: (j['manual_stop_at'] as num?)?.toInt() ?? 980,
  );
}

/// What one sync did.
class AirtableSyncResult {
  const AirtableSyncResult({
    this.total = 0,
    this.added = 0,
    this.changed = 0,
    this.removed = 0,
    this.calls = 0,
    this.error,
    this.skipped,
  });

  final int total;
  final int added;
  final int changed;
  final int removed;
  final int calls;

  /// Set when it didn't work (airtable_token_rejected, airtable_limit…).
  final String? error;

  /// Set when it didn't run (busy: a sync was already running; disabled).
  final String? skipped;

  bool get nothingChanged => added + changed + removed == 0;

  static AirtableSyncResult fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return AirtableSyncResult(
      total: n('total'),
      added: n('added'),
      changed: n('changed'),
      removed: n('removed'),
      calls: n('calls'),
      error: j['error'] as String?,
      skipped: j['skipped'] as String?,
    );
  }
}

class AirtableSyncService {
  AirtableSyncService(this._read, this._edit, {this.onSynced});

  final Future<Object?> Function(String name, [Map<String, Object?>? params])
  _read;
  final Future<Object?> Function(String name, [Map<String, Object?>? params])
  _edit;

  /// Called after a sync that changed something (to download it now).
  final void Function()? onSynced;

  Future<AirtableStatus> status() async => AirtableStatus.fromJson(
    ((await _read('airtable_status')) as Map).cast<String, Object?>(),
  );

  /// Reads what changed in Airtable since the last read ([full]: admin
  /// only, reads everything — also catches deleted records).
  Future<AirtableSyncResult> syncNow({bool full = false}) async {
    final result = AirtableSyncResult.fromJson(
      ((await _edit('airtable_sync_now', {'p_full': full})) as Map)
          .cast<String, Object?>(),
    );
    if (result.error == null && result.skipped == null) onSynced?.call();
    return result;
  }
}

final Provider<AirtableSyncService> airtableSyncProvider = Provider((ref) {
  final cloud = ref.read(cloudSyncProvider.notifier);
  return AirtableSyncService(
    cloud.callAsReader,
    cloud.callAsEditor,
    onSynced: () {
      cloud.syncNow();
      ref.invalidate(airtableStatusProvider);
    },
  );
});

/// The sync's status, or null when it can't be read (offline, or the online
/// database hasn't got it). Read again when the data changes.
final FutureProvider<AirtableStatus?> airtableStatusProvider = FutureProvider((
  ref,
) async {
  ref.watch(dataVersionProvider);
  if (!ref.watch(cloudSyncProvider.select((s) => s.phase == SyncPhase.live))) {
    return null;
  }
  try {
    return await ref.read(airtableSyncProvider).status();
  } catch (_) {
    return null;
  }
});

/// A short, plain message for an Airtable sync problem.
String describeAirtableError(Object e) {
  final code = e is CloudException ? e.code : (e is String ? e : null);
  if (code == null) {
    return 'Couldn’t reach the online database. Check the internet '
        'connection and try again.';
  }
  final c = code.split(':').first.trim();
  return switch (c) {
    'airtable_token_rejected' =>
      'Airtable refused the access token. It may have been deleted or '
          'regenerated: make a new read-only token and save it in the '
          'Supabase Vault as airtable_token.',
    'no_airtable_token' =>
      'There’s no Airtable token in the Supabase Vault (airtable_token).',
    'airtable_not_found' =>
      'Airtable couldn’t find the Applications Tracker (moved, renamed '
          'base or deleted view?).',
    'airtable_limit' || 'airtable_budget' =>
      'This month’s Airtable API calls are used up. It starts again on '
          'the 1st; until then, upload the CSV instead.',
    'airtable_empty' =>
      'Airtable sent no applications, so nothing was changed (an empty '
          'read never clears the list).',
    'not_allowed' => 'Only the admin and the admin team can sync.',
    'not_signed_in' => 'Your sign-in has ended. Sign out and in again.',
    _ => 'The Airtable sync didn’t work ($c).',
  };
}
