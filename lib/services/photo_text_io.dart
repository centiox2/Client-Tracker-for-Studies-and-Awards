import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'windows_ocr.dart';

/// Phones use Google's on-device reader; Windows uses its built-in one.
bool get photoTextSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isWindows;

/// Lets the user choose a photo; its path, or null if cancelled.
Future<String?> pickPhoto() async {
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: 'Choose a photo of the payment message',
    type: FileType.image,
  );
  return picked?.files.singleOrNull?.path;
}

/// The text in the photo at [path], read on this device. Throws with a
/// readable message if it can't be read.
Future<String> readPhotoText(String path) async {
  if (Platform.isWindows) return readTextOnWindows(path);
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  } finally {
    await recognizer.close();
  }
}
