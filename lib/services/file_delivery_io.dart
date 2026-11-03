import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Saves [bytes] via a native save dialog. Returns the path, or null if the
/// user cancelled. (io platforms: Windows, Android, iOS.)
Future<String?> saveFileBytes({
  required String dialogTitle,
  required String defaultName,
  required List<String> extensions,
  required Uint8List bytes,
}) async {
  final target = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (target == null) return null;
  File(target)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return target;
}

/// Opens a user-picked file and returns its bytes, or null if cancelled.
Future<Uint8List?> openFileBytes({
  required String dialogTitle,
  required List<String> extensions,
}) async {
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: extensions,
    withData: true,
  );
  // Some platforms return an empty list instead of null on cancel.
  if (picked == null || picked.files.isEmpty) return null;
  final data = picked.files.single.bytes;
  if (data != null) return data;
  final path = picked.files.single.path;
  if (path != null) return File(path).readAsBytesSync();
  return null;
}

/// True when files are real OS files (enables the io-only auto-backups UI
/// copy in Settings).
bool get isDesktopFiles => true;
