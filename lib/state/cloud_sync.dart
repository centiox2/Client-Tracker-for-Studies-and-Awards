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
  static const _teamTokenKey = 'cloud_team_token';
  static const _directorTokenKey = 'cloud_director_token';
  static const _viewerTokenKey = 'cloud_viewer_token';

  CloudApi? _api;
  SyncEngine? _engine;
  String? _token;

  /// The admin team's token: sends their changes (not revenue).
  String? _teamToken;

  /// The view-only profiles' tokens: they read the data (the director's
  /// with revenue).
  String? _directorToken;
  String? _viewerToken;

  /// What changes are sent with: the admin's token if this device has one.
  String? get _pushToken => _token ?? _teamToken;

  /// What the data is read with: the open profile's own token, so each
  /// profile gets only what it may see.
  String? get _readToken => switch (ref.read(sessionProvider)) {
    UserRole.admin => _token,
    UserRole.adminTeam => _teamToken,
    UserRole.director => _directorToken,
    UserRole.team => _viewerToken,
    null => null,
  };

  /// Whether the open profile can read the online data on this device.
  bool get canRead => _readToken != null;

  final _tokensLoaded = Completer<void>();

  /// Done once this device's saved sign-ins are loaded (right away when
  /// online sync is off).
  Future<void> get ready =>
      _api == null ? Future.value() : _tokensLoaded.future;

  /// A change arrived while downloading: download again after.
  bool _again = false;
  Timer? _pingTimer;
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
    // Another profile opened: its own data (revenue or not).
    ref.listen(sessionProvider, (before, now) {
      if (now != null && now != before) _connect();
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
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(_tokenKey);
      _teamToken = prefs.getString(_teamTokenKey);
      _directorToken = prefs.getString(_directorTokenKey);
      _viewerToken = prefs.getString(_viewerTokenKey);
    } catch (_) {}
    if (!_tokensLoaded.isCompleted) _tokensLoaded.complete();
    if (!ref.mounted) return;
    state = state.copyWith(
      phase: SyncPhase.connecting,
      adminLinked: _pushToken != null,
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
    if (engine == null || api == null) return;
    if (_connecting) {
      _again = true;
      return;
    }
    _connecting = true;
    _again = false;
    try {
      final claimed = (await api.adminStatus()) == 'claimed';
      final read = _readToken;
      // Before a profile is open there is nothing to read with.
      final changed = read != null
          ? await engine.pull(token: _pushToken, readToken: read)
          : false;
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
      if (_again && ref.mounted) unawaited(_connect());
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
    final token = _pushToken;
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

  /// Some device changed the data: read the latest (once for a burst of
  /// changes, e.g. while someone types numbers in).
  void _onRemote(CloudChange change) {
    _pingTimer?.cancel();
    _pingTimer = Timer(const Duration(milliseconds: 800), () {
      if (ref.mounted) _connect();
    });
  }

  void _bumpFromRemote() {
    _remoteBumps++;
    ref.read(dataVersionProvider.notifier).bump();
  }

  void _refused(CloudException e) {
    if (!ref.mounted) return;
    if (e.code == 'not_signed_in') {
      // This profile's sign-in ran out (or its password was changed).
      final role = ref.read(sessionProvider);
      if (role != null) {
        _setRoleToken(role, null);
      } else if (_token != null) {
        _setToken(null);
      } else {
        _setTeamToken(null);
      }
      state = state.copyWith(
        phase: SyncPhase.error,
        adminLinked: _pushToken != null,
        message: 'Switch profile and sign in again to get the latest data.',
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

  /// A new recovery code for a forgotten password; null when this device
  /// isn't signed in online (or is offline).
  Future<String?> createRecoveryCode() async {
    final api = _api;
    final token = _token;
    if (api == null || token == null) return null;
    try {
      return await api.createRecoveryCode(token);
    } catch (_) {
      return null;
    }
  }

  /// Whether a recovery code exists; null when unknown.
  Future<bool?> hasRecoveryCode() async {
    final api = _api;
    final token = _token;
    if (api == null || token == null) return null;
    try {
      return await api.hasRecoveryCode(token);
    } catch (_) {
      return null;
    }
  }

  /// Sets a new online password with a recovery code, and signs this device
  /// in with it. wrongPassword means the code was wrong (or already used).
  Future<CloudLink> recoverAdmin(String code, String newPassword) async {
    final api = _api;
    if (api == null) return CloudLink.off;
    try {
      final token = await api.recover(code, newPassword);
      _setToken(token);
      state = state.copyWith(adminLinked: true, claimed: true);
      unawaited(_connect());
      return CloudLink.linked;
    } on CloudException catch (e) {
      return e.code == 'wrong_recovery_code'
          ? CloudLink.wrongPassword
          : CloudLink.offline;
    } catch (_) {
      return CloudLink.offline;
    }
  }

  /// Which profiles have a password online; null when it can't be asked
  /// (offline, or online sync is off).
  Future<Map<UserRole, bool>?> profileStatus() async {
    final api = _api;
    if (api == null) return null;
    try {
      final status = await api.profileStatus();
      return {
        for (final r in UserRole.others) r: status[r.serverName] ?? false,
      };
    } catch (_) {
      return null;
    }
  }

  /// When [role]'s password last changed online; null when it can't be
  /// asked.
  Future<String?> profileVersion(UserRole role) async {
    final api = _api;
    if (api == null) return null;
    try {
      return (await api.profileVersions())[role.serverName];
    } catch (_) {
      return null;
    }
  }

  /// Checks [role]'s [password] online. The admin team's device can then
  /// send their changes.
  Future<CloudLink> openProfile(UserRole role, String password) async {
    final api = _api;
    if (api == null) return CloudLink.off;
    try {
      final token = await api.profileLogin(role.serverName, password);
      if (token.isNotEmpty) {
        _setRoleToken(role, token);
        if (role == UserRole.adminTeam) {
          state = state.copyWith(adminLinked: true);
        }
        unawaited(_connect());
      }
      return CloudLink.linked;
    } on CloudException catch (e) {
      return e.code == 'wrong_password'
          ? CloudLink.wrongPassword
          : CloudLink.offline;
    } catch (_) {
      return CloudLink.offline;
    }
  }

  /// The admin sets [role]'s password ('' leaves it open). False when it
  /// couldn't be saved online (offline, or not signed in online).
  Future<bool> setProfilePassword(UserRole role, String password) async {
    final api = _api;
    final token = _token;
    if (api == null || token == null) return false;
    try {
      await api.setProfilePassword(token, role.serverName, password);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Throws away waiting local changes and downloads the cloud's data.
  Future<void> resetFromCloud() async {
    final engine = _engine;
    final read = _readToken;
    if (engine == null || read == null) return;
    try {
      await engine.resetFromCloud(read);
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

  void _setTeamToken(String? token) {
    _teamToken = token;
    SharedPreferences.getInstance().then(
      (p) => token == null
          ? p.remove(_teamTokenKey)
          : p.setString(_teamTokenKey, token),
    );
  }

  void _setRoleToken(UserRole role, String? token) {
    switch (role) {
      case UserRole.admin:
        _setToken(token);
      case UserRole.adminTeam:
        _setTeamToken(token);
      case UserRole.director || UserRole.team:
        final key = role == UserRole.director
            ? _directorTokenKey
            : _viewerTokenKey;
        if (role == UserRole.director) {
          _directorToken = token;
        } else {
          _viewerToken = token;
        }
        SharedPreferences.getInstance().then(
          (p) => token == null ? p.remove(key) : p.setString(key, token),
        );
    }
  }

  void _stop() {
    _pingTimer?.cancel();
    _flushTimer?.cancel();
    _refreshTimer?.cancel();
    _heartbeat?.cancel();
    _changes?.cancel();
    _connection?.cancel();
    _api?.dispose();
  }
}
