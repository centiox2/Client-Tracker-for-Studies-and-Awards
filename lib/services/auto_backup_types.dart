/// One automatic backup.
class AutoBackupEntry {
  const AutoBackupEntry({
    required this.id,
    required this.savedAt,
    required this.bytes,
  });

  /// Where it is (a file path, or a storage key in the browser).
  final String id;
  final DateTime savedAt;
  final int bytes;
}

/// Where automatic backups live: a folder of .json files on Windows and
/// Android, or a few copies inside the browser on the web.
abstract class AutoBackupStore {
  const AutoBackupStore();

  /// Shown in Settings: the folder, or "this browser".
  String get location;

  /// How many are kept; older ones are deleted.
  int get keep;

  /// False when backups can't be written here (tests, in-memory data).
  bool get enabled => true;

  /// The folder can be changed (Windows / desktop).
  bool get canChooseFolder => false;

  /// Newest first.
  Future<List<AutoBackupEntry>> list();

  Future<void> save(String name, String json);

  Future<String?> read(String id);
}

class DisabledAutoBackupStore extends AutoBackupStore {
  const DisabledAutoBackupStore();

  @override
  String get location => '';

  @override
  int get keep => 0;

  @override
  bool get enabled => false;

  @override
  Future<List<AutoBackupEntry>> list() async => const [];

  @override
  Future<void> save(String name, String json) async {}

  @override
  Future<String?> read(String id) async => null;
}
