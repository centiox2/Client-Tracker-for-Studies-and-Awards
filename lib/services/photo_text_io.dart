import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

bool get photoTextSupported => Platform.isAndroid || Platform.isIOS;

/// Lets the user pick a photo and returns the text in it; null if cancelled.
Future<String?> pickPhotoText() async {
  final picked = await FilePicker.platform.pickFiles(type: FileType.image);
  final path = picked?.files.singleOrNull?.path;
  if (path == null) return null;
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  } finally {
    await recognizer.close();
  }
}
