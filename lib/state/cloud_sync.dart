import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/cloud_config.dart';
import '../services/cloud/cloud_api.dart';
import '../services/cloud/supabase_cloud_api.dart';
import '../services/cloud/sync_engine.dart';
import 'app_state.dart';

enum SyncPhase {
  /// Online sync isn't set up in this build (or in tests).
  off,
  connecting,

  /// Connected; live updates are flowing.
  live,

  /// No connection — the app keeps working and catches up later.
  offline,

  /// Something was refused; see [CloudSyncState.message].
  error,
}

/// How the admin's sign-in went online.
enum CloudLink { linked, wrongPassword, offline, off }

class CloudSyncState {
  const CloudSyncState({
    this.phase = SyncPhase.off,
    this.lastSynced,
    this.pending = 0,
    this.adminLinked = false,
    this.claimed,
    this.message,
  });

  final SyncPhase phase;
  final DateTime? lastSynced;

  /// Local changes not yet sent.
  final int pending;

  /// This device can send changes (it holds an admin token).
  final bool adminLinked;

  /// Whether an online admin password exists (null: not known yet).
  final bool? claimed;
  final String? message;

  CloudSyncState copyWith({
    SyncPhase? phase,
    DateTime? lastSynced,
    int? pending,
    bool? adminLinked,
    bool? claimed,
    String? message,
    bool clearMessage = false,
  }) => CloudSyncState(
    phase: phase ?? this.phase,
    lastSynced: lastSynced ?? this.lastSynced,
    pending: pending ?? this.pending,
    adminLinked: adminLinked ?? this.adminLinked,
    claimed: claimed ?? this.claimed,
    message: clearMessage ? null : (message ?? this.message),
  );
}

/// Makes the cloud connection; null when sync is off (tests, or a build
/// without it). Overridable in tests with a fake.
final cloudApiFactoryProvider = Provider<CloudApi? Function()>(
  (ref) =>
      () => CloudConfig.active ? SupabaseCloudApi() : null,
);

final cloudSyncProvider = NotifierProvider<CloudSyncController, CloudSyncState>(
  CloudSyncController.new,
);

class CloudSyncController extends Notifier<CloudSyncState> {
  static const _tokenKey = 'cloud_admin_token';

  CloudApi? _api;
  SyncEngine? _engine;
  String? _token;
  Timer? _flushTimer;
  Timer? _refreshTimer;
  Timer? _heartbeat;
  StreamSubscription<CloudChange>? _changes;
  StreamSubscription<bool>? _connection;
  bool _connecting = false;

  /// Version bumps caused by changes from the cloud (not to be sent back).
  int _remoteBumps = 0;

  @override
  CloudSyncState build() {
    ref.onDispose(_stop);
    // Any local change: send it shortly (debounced while typing).
    ref.listen(dataVersionProvider, (_, _) {
      if (_remoteBumps > 0) {
        _remoteBumps--;
        return;
      }
      _scheduleFlush();
    });
    return const CloudSyncState();
  }

  bool get enabled => _api != null;

  /// Starts syncing (once per app run).
  Future<void> start() async {
    if (_api != null) return;
    final api = ref.read(cloudApiFactoryProvider)();
    if (api == null) return;
    _api = api;
    _engine = SyncEngine(ref.read(databaseProvider), api);
    try {
      _token = (await SharedPreferences.getInstance()).getString(_tokenKey);
    } catch (_) {}
    if (!ref.mounted) return;
    state = state.copyWith(
      phase: SyncPhase.connecting,
      adminLinked: _token != null,
      pending: _engine!.pending,
    );
    _changes = api.changes().listen(_onRemote);
    _connection = api.connection().listen((up) {
      if (!ref.mounted) return;
      if (up && state.phase != SyncPhase.live) {
        _connect(); // back online: catch up
      } else if (!up && state.phase == SyncPhase.live) {
        state = state.copyWith(phase: SyncPhase.offline);
      }
    });
    _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
      if (state.phase == SyncPhase.offline || state.phase == SyncPhase.error) {
        _connect();
      } else if ((_engine?.pending ?? 0) > 0) {
        _flush();
      }
    });
    await _connect();
  }

  /// Downloads the latest data (sending waiting changes first).
  Future<void> syncNow() => _connect();

  Future<void> _connect() async {
    final engine = _engine;
    final api = _api;
    if (engine == null || api == null || _connecting) return;
    _connecting = true;
    try {
      final claimed = (await api.adminStatus()) == 'claimed';
      final changed = await engine.pull(token: _token);
      if (!ref.mounted) return;
      if (changed) _bumpFromRemote();
      state = state.copyWith(
        phase: SyncPhase.live,
        claimed: claimed,
        lastSynced: DateTime.now(),
        pending: engine.pending,
        clearMessage: true,
      );
    } on CloudException catch (e) {
      _refused(e);
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: SyncPhase.offline,
          pending: engine.pending,
        );
      }
    } finally {
      _connecting = false;
    }
  }

  void _scheduleFlush() {
    if (_engine == null) return;
    state = state.copyWith(pending: _engine!.pending);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 700), _flush);
  }

  Future<void> _flush() async {
    final engine = _engine;
    final token = _token;
    if (engine == null || token == null || engine.pending == 0) return;
    if (!engine.connected) {
      // Not joined yet: join first (which also sends).
      await _connect();
      return;
    }
    try {
      await engine.flush(token);
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: SyncPhase.live,
        lastSynced: DateTime.now(),
        pending: engine.pending,
        clearMessage: true,
      );
    } on CloudException catch (e) {
      _refused(e);
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: SyncPhase.offline,
          pending: engine.pending,
        );
      }
    }
  }

  void _onRemote(CloudChange change) {
    final engine = _engine;
    if (engine == null || !engine.connected) return;
    if (!engine.apply(change)) {
      _connect(); // out of order (e.g. a day before its week): re-download
      return;
    }
    // Many changes arrive together (a restore, an import): refresh once.
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!ref.mounted) return;
      _bumpFromRemote();
      state = state.copyWith(lastSynced: DateTime.now());
    });
  }

  void _bumpFromRemote() {
    _remoteBumps++;
    ref.read(dataVersionProvider.notifier).bump();
  }

  void _refused(CloudException e) {
    if (!ref.mounted) return;
    if (e.code == 'not_signed_in') {
      _setToken(null);
      state = state.copyWith(
        phase: SyncPhase.error,
        adminLinked: false,
        message: 'Sign in again to send your changes online.',
      );
      return;
    }
    state = state.copyWith(
      phase: SyncPhase.error,
      message: 'The online database refused a change ($e).',
    );
  }

  /// Signs this device in online with the admin [password]: the first time
  /// anywhere it becomes the online password. Then sends waiting changes.
  Future<CloudLink> linkAdmin(String password) async {
    final api = _api;
    if (api == null) return CloudLink.off;
    try {
      final status = await api.adminStatus();
      final token = status == 'claimed'
          ? await api.login(password)
          : await api.claim(password);
      _setToken(token);
      state = state.copyWith(adminLinked: true, claimed: true);
      unawaited(_connect());
      return CloudLink.linked;
    } on CloudException catch (e) {
      if (e.code == 'wrong_password' || e.code == 'already_claimed') {
        state = state.copyWith(claimed: true);
        return CloudLink.wrongPassword;
      }
      return CloudLink.offline;
    } catch (_) {
      return CloudLink.offline;
    }
  }

  /// Keeps the online password in step when the admin changes it.
  Future<bool> changePassword(String newPassword) async {
    final api = _api;
    final token = _token;
    if (api == null || token == null) return false;
    try {
      await api.setPassword(token, newPassword);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Throws away waiting local changes and downloads the cloud's data.
  Future<void> resetFromCloud() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.resetFromCloud();
      if (!ref.mounted) return;
      _bumpFromRemote();
      state = state.copyWith(
        phase: SyncPhase.live,
        lastSynced: DateTime.now(),
        pending: 0,
        clearMessage: true,
      );
    } catch (_) {
      if (ref.mounted) state = state.copyWith(phase: SyncPhase.offline);
    }
  }

  void _setToken(String? token) {
    _token = token;
    SharedPreferences.getInstance().then(
      (p) =>
          token == null ? p.remove(_tokenKey) : p.setString(_tokenKey, token),
    );
  }

  void _stop() {
    _flushTimer?.cancel();
    _refreshTimer?.cancel();
    _heartbeat?.cancel();
    _changes?.cancel();
    _connection?.cancel();
    _api?.dispose();
  }
}
