import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/providers.dart';
import 'auto_backup_store.dart';

export 'auto_backup_store.dart' show AutoBackupEntry;

/// The automatic backups: which exist, and where they're kept.
class AutoBackupState {
  const AutoBackupState({
    this.entries = const [],
    this.loaded = false,
    this.location = '',
    this.keep = 0,
    this.enabled = false,
    this.canChooseFolder = false,
    this.customFolder = false,
  });

  /// Newest first.
  final List<AutoBackupEntry> entries;
  final bool loaded;
  final String location;
  final int keep;
  final bool enabled;
  final bool canChooseFolder;

  /// The user picked the folder (rather than the default one).
  final bool customFolder;

  DateTime? get last => entries.isEmpty ? null : entries.first.savedAt;
}

final autoBackupProvider =
    NotifierProvider<AutoBackupController, AutoBackupState>(
      AutoBackupController.new,
    );

/// Saves a backup automatically once a day while the app is used (at start
/// and after midnight), and keeps the last [AutoBackupStore.keep].
class AutoBackupController extends Notifier<AutoBackupState> {
  static const _folderKey = 'auto_backup_folder';

  AutoBackupStore _store = const DisabledAutoBackupStore();
  late Future<void> _ready;

  @override
  AutoBackupState build() {
    _ready = _load();
    return const AutoBackupState();
  }

  Future<void> _load() async {
    String? folder;
    try {
      folder = (await SharedPreferences.getInstance()).getString(_folderKey);
    } catch (_) {
      // No preferences store (e.g. some tests): use the default folder.
    }
    if (!ref.mounted) return;
    _open(folder);
    await _refresh();
  }

  void _open(String? folder) {
    _store = createAutoBackupStore(
      databaseFile: ref.read(databaseProvider).file,
      folder: folder,
    );
    _customFolder = folder != null;
  }

  bool _customFolder = false;

  Future<void> _refresh() async {
    List<AutoBackupEntry> entries;
    try {
      entries = await _store.list();
    } catch (_) {
      entries = const [];
    }
    if (!ref.mounted) return;
    state = AutoBackupState(
      entries: entries,
      loaded: true,
      location: _store.location,
      keep: _store.keep,
      enabled: _store.enabled,
      canChooseFolder: _store.canChooseFolder,
      customFolder: _customFolder,
    );
  }

  /// Saves today's backup unless one was already saved today.
  Future<void> ensureToday() async {
    await _ready;
    if (!_store.enabled) return;
    final last = state.last;
    final now = DateTime.now();
    if (last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day) {
      return;
    }
    await backupNow();
  }

  /// Saves a backup now. True when it was saved.
  Future<bool> backupNow() async {
    await _ready;
    if (!_store.enabled) return false;
    var ok = true;
    try {
      final result = ref.read(backupServiceProvider).backup();
      await _store.save(result.suggestedName, result.json);
    } catch (_) {
      ok = false; // never crash the app over a background backup
    }
    await _refresh();
    return ok;
  }

  Future<String?> read(String id) async {
    await _ready;
    return _store.read(id);
  }

  /// Desktop: asks for a folder (e.g. OneDrive or a USB stick) and saves a
  /// backup there straight away. False when cancelled.
  Future<bool> chooseFolder() async {
    final picked = await pickBackupFolder();
    if (picked == null) return false;
    (await SharedPreferences.getInstance()).setString(_folderKey, picked);
    _open(picked);
    await backupNow();
    return true;
  }

  /// Back to the default folder next to the app's data.
  Future<void> useDefaultFolder() async {
    (await SharedPreferences.getInstance()).remove(_folderKey);
    _open(null);
    await _refresh();
  }
}
