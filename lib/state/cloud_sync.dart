import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/cloud_config.dart';
import '../services/app_info.dart';
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

  /// Personal accounts: the signed-in person's online sign-in (null before
  /// anyone signs in, or when they signed in without internet and it
  /// hasn't been made online yet).
  String? _userToken;

  /// Signed in without internet: made online once the connection is back
  /// (the password is kept in memory only, until then).
  ({String username, String password, bool remember})? _pendingLogin;

  /// Whether the person ticked "Remember me".
  bool _remember = false;
  DateTime? _lastSessionCheck;

  bool get _accounts => ref.read(accountsEnabledProvider);

  /// What changes are sent with: the admin's token if this device has one
  /// (personal accounts: the person's own, if their role may change data).
  String? get _pushToken {
    if (_accounts) {
      return (ref.read(sessionProvider)?.canEdit ?? false) ? _userToken : null;
    }
    return _token ?? _teamToken;
  }

  /// What the data is read with: the open profile's own token, so each
  /// profile gets only what it may see.
  String? get _readToken => _accounts
      ? (ref.read(currentUserProvider) == null ? null : _userToken)
      : switch (ref.read(sessionProvider)) {
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
    // Signed out (from the account menu, say): end it online too.
    ref.listen(currentUserProvider, (before, now) {
      if (before != null && now == null) _endUserSession();
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
    if (_accounts && _userToken == null) {
      final kept = ref.read(authRepositoryProvider).rememberedUser;
      if (kept != null && kept.user.id == ref.read(currentUserProvider)?.id) {
        _userToken = kept.token;
        _remember = true;
      }
    }
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
      // Now and then, check the sign-in is still good (and keep it going).
      final checked = _lastSessionCheck;
      if (_accounts &&
          _userToken != null &&
          (checked == null ||
              DateTime.now().difference(checked) > const Duration(hours: 6))) {
        unawaited(checkSession());
      }
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
      final claimed = _accounts
          ? (await api.usersStatus()) == 'ready'
          : (await api.adminStatus()) == 'claimed';
      if (_accounts && !await _finishOfflineSignIn(api)) return;
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
    if (_accounts && e.code == 'not_signed_in') {
      // Ended online: signed out elsewhere, a new role or password set by
      // an admin, or the account switched off.
      unawaited(
        signOutUser(notice: 'Your sign-in has ended. Please sign in again.'),
      );
      return;
    }
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

  // ---- Personal accounts ------------------------------------------------

  /// 'empty' (no accounts yet: the first one is set up), 'ready', or null
  /// when it can't be asked (offline).
  Future<String?> usersStatus() async {
    final api = _api;
    if (api == null) return null;
    try {
      return await api.usersStatus();
    } catch (_) {
      return null;
    }
  }

  /// Checks [username] and [password] online. Throws [CloudException]
  /// (wrong_password, locked, deactivated) or, offline, any other error.
  /// The caller finishes with [completeSignIn] (after a first-time new
  /// password, if the account needs one).
  Future<UserSignIn> checkSignIn(
    String username,
    String password, {
    required bool remember,
  }) {
    final api = _api;
    if (api == null) throw StateError('Online sync is off');
    return api.userLogin(username.trim().toLowerCase(), password, remember);
  }

  /// A brand-new online database: the first account, an admin.
  Future<UserSignIn> setupFirstAdmin(
    String username,
    String fullName,
    String password,
  ) {
    final api = _api;
    if (api == null) throw StateError('Online sync is off');
    return api.userSetup(username.trim().toLowerCase(), fullName, password);
  }

  /// The person chooses their own password in place of the temporary one
  /// the admin gave them (at their first sign-in).
  Future<UserSignIn> replaceTemporaryPassword(
    UserSignIn signIn,
    String temporary,
    String next,
  ) async {
    final api = _api;
    if (api == null) throw StateError('Online sync is off');
    await api.userChangePassword(signIn.token, temporary, next);
    return UserSignIn(signIn.token, signIn.user.copyWith(mustChange: false));
  }

  /// The person backed out before finishing (e.g. choosing their own
  /// password): end that sign-in online too.
  Future<void> discardSignIn(UserSignIn signIn) async {
    try {
      await _api?.userLogout(signIn.token);
    } catch (_) {}
  }

  /// Opens the app as [signIn]'s user.
  void completeSignIn(
    UserSignIn signIn,
    String password, {
    required bool remember,
  }) {
    _userToken = signIn.token;
    _remember = remember;
    _pendingLogin = null;
    _lastSessionCheck = DateTime.now();
    ref
        .read(authRepositoryProvider)
        .saveSignIn(
          signIn.user,
          password,
          token: signIn.token,
          remember: remember,
        );
    ref.read(signInNoticeProvider.notifier).set(null);
    ref.read(currentUserProvider.notifier).signedIn(signIn.user);
    state = state.copyWith(adminLinked: _pushToken != null);
    unawaited(_connect());
    _touchSession(signIn.token);
  }

  /// Tells the online database which device this sign-in is on and that it
  /// was just used (Settings › Your sessions). Quietly skipped offline or
  /// before the database has this.
  void _touchSession(String token) {
    final api = _api;
    if (api == null) return;
    unawaited(
      api
          .callFunction('user_session_touch', {
            'p_token': token,
            'p_device': AppInfo.device,
          })
          .then((_) {}, onError: (_) {}),
    );
  }

  /// Sends an unexpected error to the online database (Settings › Problems),
  /// with whoever is signed in. Never throws.
  Future<void> reportError(Map<String, Object?> report) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.callFunction('report_error', {
        'p_token': _userToken ?? _readToken,
        'p_report': report,
      });
    } catch (_) {}
  }

  /// No internet: opens the app as [user], who signed in on this device
  /// before with this [password]. Signs in online once the connection is
  /// back.
  void signInOffline(AppUser user, String password, {required bool remember}) {
    _userToken = null;
    _remember = remember;
    _pendingLogin = (
      username: user.username,
      password: password,
      remember: remember,
    );
    ref.read(authRepositoryProvider).forgetSignIn();
    ref.read(signInNoticeProvider.notifier).set(null);
    ref.read(currentUserProvider.notifier).signedIn(user);
    state = state.copyWith(adminLinked: false);
  }

  /// Signed in without internet: does it online now. False when that
  /// ended the sign-in (the password was changed, say).
  Future<bool> _finishOfflineSignIn(CloudApi api) async {
    final pending = _pendingLogin;
    if (pending == null ||
        _userToken != null ||
        ref.read(currentUserProvider) == null) {
      return true;
    }
    try {
      final signIn = await api.userLogin(
        pending.username,
        pending.password,
        pending.remember,
      );
      if (!ref.mounted) return false;
      if (signIn.user.mustChange) {
        await signOutUser(
          notice: 'An admin gave you a new password. Sign in with it.',
        );
        return false;
      }
      _userToken = signIn.token;
      _pendingLogin = null;
      _lastSessionCheck = DateTime.now();
      ref
          .read(authRepositoryProvider)
          .saveSignIn(
            signIn.user,
            pending.password,
            token: signIn.token,
            remember: pending.remember,
          );
      ref.read(currentUserProvider.notifier).update(signIn.user);
      state = state.copyWith(adminLinked: _pushToken != null);
      return true;
    } on CloudException catch (e) {
      // Anything else (a server hiccup, an update not applied yet): stay
      // signed in here and try again on the next connection.
      if (!const {'wrong_password', 'locked', 'deactivated'}.contains(e.code)) {
        return true;
      }
      // Wrong password now, locked or switched off: sign in again.
      ref.read(authRepositoryProvider).forgetUser(pending.username);
      await signOutUser(
        notice: 'Your password or account changed. Please sign in again.',
      );
      return false;
    }
  }

  /// Checks the person's sign-in online: their latest details (a new name
  /// shows straight away) and another 30 days (or a day). Signs them out
  /// if it has ended; offline, nothing changes.
  Future<void> checkSession() async {
    final api = _api;
    final token = _userToken;
    if (!_accounts || api == null || token == null) return;
    _lastSessionCheck = DateTime.now();
    try {
      final user = await api.userSession(token);
      if (!ref.mounted || _userToken != token) return;
      _touchSession(token);
      ref.read(authRepositoryProvider).updateUser(user);
      ref.read(currentUserProvider.notifier).update(user);
    } on CloudException catch (e) {
      if (e.code == 'not_signed_in' && ref.mounted && _userToken == token) {
        await signOutUser(
          notice: 'Your sign-in has ended. Please sign in again.',
        );
      }
    } catch (_) {
      // Offline: stay signed in.
    }
  }

  /// Signs the person out, back to the sign-in screen ([notice] says why).
  Future<void> signOutUser({String? notice}) async {
    ref.read(authRepositoryProvider).forgetSignIn();
    ref.read(signInNoticeProvider.notifier).set(notice);
    if (ref.read(currentUserProvider) != null) {
      ref.read(currentUserProvider.notifier).signedOut(); // → _endUserSession
    } else {
      await _endUserSession();
    }
  }

  /// Nobody is signed in any more: forget the sign-in here and online.
  Future<void> _endUserSession() async {
    final token = _userToken;
    _userToken = null;
    _pendingLogin = null;
    _remember = false;
    state = state.copyWith(
      adminLinked: false,
      clearMessage: true,
      phase: state.phase == SyncPhase.error ? SyncPhase.live : null,
    );
    final api = _api;
    if (token != null && api != null) {
      try {
        await api.userLogout(token);
      } catch (_) {}
    }
  }

  String _needToken() {
    final token = _userToken;
    if (token == null) throw CloudException('not_signed_in');
    return token;
  }

  CloudApi _needApi() => _api ?? (throw StateError('Online sync is off'));

  /// The person's own new password (needs their current one). Throws
  /// [CloudException] (wrong_password, password_too_short, same_password).
  Future<void> changeOwnPassword(String current, String next) async {
    await _needApi().userChangePassword(_needToken(), current, next);
    final user = ref.read(currentUserProvider);
    if (user != null) {
      ref
          .read(authRepositoryProvider)
          .saveSignIn(user, next, token: _userToken, remember: _remember);
    }
  }

  /// Calls an online function as the signed-in person (their token added
  /// as p_token). Daily reports are read and written this way.
  Future<Object?> callAsUser(String name, [Map<String, Object?>? params]) =>
      _needApi().callFunction(name, {'p_token': _needToken(), ...?params});

  /// Calls an online function with what this device reads the data with
  /// (any signed-in person or open profile).
  Future<Object?> callAsReader(String name, [Map<String, Object?>? params]) {
    final token = _readToken;
    if (token == null) throw CloudException('not_signed_in');
    return _needApi().callFunction(name, {'p_token': token, ...?params});
  }

  /// Calls an online function with what this device sends changes with
  /// (the admin and the admin team).
  Future<Object?> callAsEditor(String name, [Map<String, Object?>? params]) {
    final token = _pushToken;
    if (token == null) throw CloudException('not_signed_in');
    return _needApi().callFunction(name, {'p_token': token, ...?params});
  }

  /// Admin: every account.
  Future<List<AppUser>> listUsers() => _needApi().adminListUsers(_needToken());

  /// Admin: creates (no [id]; [password] is the temporary one) or changes
  /// an account.
  Future<AppUser> saveUser({
    int? id,
    required String username,
    required String fullName,
    required UserRole role,
    int? staffId,
    bool active = true,
    String? password,
    int? departmentId,
    ReportAccess reportAccess = ReportAccess.employee,
  }) async {
    final saved = await _needApi().adminSaveUser(_needToken(), {
      'id': ?id,
      'username': username.trim().toLowerCase(),
      'full_name': fullName.trim(),
      'role': role.serverName,
      'staff_id': staffId,
      'active': active,
      'department_id': departmentId,
      'report_access': reportAccess.code,
    }, password: password);
    ref.read(currentUserProvider.notifier).update(saved);
    return saved;
  }

  /// Admin: deletes account [userId]. Someone with daily reports is only
  /// deleted with [withReports]; otherwise this throws
  /// CloudException('has_reports') whose detail holds how many.
  Future<void> deleteUser(int userId, {bool withReports = false}) => callAsUser(
    'admin_delete_user',
    {'p_user_id': userId, 'p_with_reports': withReports},
  );

  /// Admin: limits which pages account [userId] opens ([pages] are AppTab
  /// names; null or empty means every page its role allows).
  Future<AppUser> setUserPages(int userId, Set<String>? pages) async {
    final saved = AppUser.fromJson(
      Map<String, Object?>.from(
        await callAsUser('admin_set_user_pages', {
          'p_user_id': userId,
          'p_pages': pages?.toList(),
        }) as Map,
      ),
    );
    ref.read(currentUserProvider.notifier).update(saved);
    return saved;
  }

  /// Admin: everything that lives only online (daily reports, their
  /// history and comments, departments, accounts without passwords, the
  /// audit log), for the full backup.
  Future<Map<String, Object?>> backupOnline() async =>
      Map<String, Object?>.from(await callAsUser('admin_backup') as Map);

  /// Admin: puts back departments and daily reports from a full backup
  /// (only the ones that are missing). Returns how many came back.
  Future<Map<String, Object?>> restoreOnline(Map<String, Object?> data) async =>
      Map<String, Object?>.from(
        await callAsUser('admin_restore_online', {'p_data': data}) as Map,
      );

  /// Admin: a temporary password for someone who forgot theirs.
  Future<void> resetUserPassword(int userId, String password) =>
      _needApi().adminResetPassword(_needToken(), userId, password);

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
