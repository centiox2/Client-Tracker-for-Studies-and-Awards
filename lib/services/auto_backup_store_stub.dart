import 'auto_backup_types.dart';

/// Unsupported platform: automatic backups are off.
AutoBackupStore createAutoBackupStore({
  required String databaseFile,
  String? folder,
}) => const DisabledAutoBackupStore();

/// No folder picker here.
Future<String?> pickBackupFolder() async => null;
