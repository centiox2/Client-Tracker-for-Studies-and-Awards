import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'photo_text_types.dart';
import 'windows_ocr.dart';

export 'photo_text_types.dart';

/// Phones use Google's on-device reader; Windows uses its built-in one.
bool get photoTextSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isWindows;

/// Photos can be dragged onto the window (Windows desktop).
bool get photoDropSupported => Platform.isWindows;

/// Lets the user choose one or more photos; their paths (empty if cancelled).
Future<List<String>> pickPhotos() async {
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: 'Choose photos of payment messages',
    type: FileType.image,
    allowMultiple: true,
  );
  return [
    for (final f in picked?.files ?? const <PlatformFile>[])
      if (f.path != null) f.path!,
  ];
}

DateTime? _fileTime(String path) {
  try {
    return File(path).lastModifiedSync();
  } catch (_) {
    return null;
  }
}

/// Reads the text in each photo, on this device. One photo that can't be
/// read doesn't stop the others; [onProgress] gets the number done so far.
///
/// Photos are never stored or uploaded: only the text is read, in memory,
/// and only the payment details the admin chooses to add are saved.
Future<List<PhotoText>> readPhotoTexts(
  List<String> paths, {
  void Function(int done)? onProgress,
}) async {
  if (Platform.isWindows) {
    final results = await readTextsOnWindows(paths, onProgress: onProgress);
    return [
      for (final r in results)
        PhotoText(
          r.path,
          text: r.text,
          error: r.error,
          fileTime: _fileTime(r.path),
        ),
    ];
  }
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final out = <PhotoText>[];
  try {
    return await _readOnPhone(recognizer, paths, out, onProgress);
  } finally {
    await recognizer.close();
    // The phone's file picker hands over *copies* of the chosen photos, kept
    // in the app's cache. Photos are never kept: delete the copies as soon
    // as they've been read. (The originals in the gallery aren't touched.)
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {}
  }
}

Future<List<PhotoText>> _readOnPhone(
  TextRecognizer recognizer,
  List<String> paths,
  List<PhotoText> out,
  void Function(int done)? onProgress,
) async {
  for (final path in paths) {
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      out.add(PhotoText(path, text: result.text, fileTime: _fileTime(path)));
    } catch (e) {
      out.add(PhotoText(path, error: '$e', fileTime: _fileTime(path)));
    }
    onProgress?.call(out.length);
  }
  return out;
}
