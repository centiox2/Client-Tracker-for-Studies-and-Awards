import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'auto_backup_types.dart';

/// Windows / Android: one .json file per day in a folder, the last 30 kept.
/// The default folder is `auto_backups` next to the database.
AutoBackupStore createAutoBackupStore({
  required String databaseFile,
  String? folder,
}) {
  if (databaseFile == ':memory:' || databaseFile.isEmpty) {
    return const DisabledAutoBackupStore();
  }
  return _FolderStore(
    folder ?? p.join(p.dirname(databaseFile), 'auto_backups'),
  );
}

/// Lets the user pick another folder (e.g. OneDrive or a USB stick) on
/// desktop. Null when cancelled or not supported.
Future<String?> pickBackupFolder() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return null;
  }
  return FilePicker.platform.getDirectoryPath(
    dialogTitle: 'Folder for automatic backups',
  );
}

class _FolderStore extends AutoBackupStore {
  const _FolderStore(this.folder);

  final String folder;

  static const _prefix = 'client_tracker_backup_';

  @override
  String get location => folder;

  @override
  int get keep => 30;

  @override
  bool get canChooseFolder =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Future<List<AutoBackupEntry>> list() async {
    final dir = Directory(folder);
    if (!dir.existsSync()) return const [];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  p.basename(f.path).startsWith(_prefix) &&
                  f.path.endsWith('.json'),
            )
            .map(
              (f) => AutoBackupEntry(
                id: f.path,
                savedAt: f.lastModifiedSync(),
                bytes: f.lengthSync(),
              ),
            )
            .toList()
          ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return files;
  }

  @override
  Future<void> save(String name, String json) async {
    Directory(folder).createSync(recursive: true);
    File(p.join(folder, name)).writeAsStringSync(json);
    final all = await list();
    for (final old in all.skip(keep)) {
      try {
        File(old.id).deleteSync();
      } catch (_) {}
    }
  }

  @override
  Future<String?> read(String id) async {
    // Only files inside the backup folder.
    if (!p.isWithin(folder, id)) return null;
    final f = File(id);
    return f.existsSync() ? f.readAsStringSync() : null;
  }
}
