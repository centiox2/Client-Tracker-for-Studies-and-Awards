import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'auto_backup_types.dart';

/// Browser: the last few daily copies kept in this browser's storage. They
/// protect against mistakes, not against clearing the browser's data — so
/// Settings still recommends saving a backup file.
AutoBackupStore createAutoBackupStore({
  required String databaseFile,
  String? folder,
}) => const _BrowserStore();

Future<String?> pickBackupFolder() async => null;

class _BrowserStore extends AutoBackupStore {
  const _BrowserStore();

  static const _prefix = 'auto_backup:';

  @override
  String get location => 'this browser';

  @override
  int get keep => 5;

  @override
  Future<List<AutoBackupEntry>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <AutoBackupEntry>[];
    for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
      final at = DateTime.tryParse(key.substring(_prefix.length));
      final value = prefs.getString(key);
      if (at == null || value == null) continue;
      out.add(AutoBackupEntry(id: key, savedAt: at, bytes: value.length));
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  @override
  Future<void> save(String name, String json) async {
    final prefs = await SharedPreferences.getInstance();
    // Compact: browser storage is small.
    final compact = jsonEncode(jsonDecode(json));
    final key = '$_prefix${DateTime.now().toIso8601String()}';
    final existing = await list();
    // Make room first, so a full storage doesn't block today's copy.
    for (final old in existing.skip(keep - 1)) {
      await prefs.remove(old.id);
    }
    try {
      await prefs.setString(key, compact);
    } catch (_) {
      // Storage full: drop all but the newest copy and try once more.
      for (final old in existing.skip(1)) {
        await prefs.remove(old.id);
      }
      await prefs.setString(key, compact);
    }
  }

  @override
  Future<String?> read(String id) async {
    if (!id.startsWith(_prefix)) return null;
    return (await SharedPreferences.getInstance()).getString(id);
  }
}
