import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'photo_text_types.dart';
import 'windows_ocr.dart';

export 'photo_text_types.dart';

/// Phones use Google's on-device reader; Windows uses its built-in one.
bool get photoTextSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isWindows;

/// Photos can be dragged onto the window (Windows desktop).
bool get photoDropSupported => Platform.isWindows;

/// A screenshot or copied photo can be pasted (Ctrl+V, or Paste image).
bool get photoPasteSupported => photoTextSupported;

/// Saves pasted image [bytes] to a temporary file to be read; its path.
Future<String?> savePastedPhoto(Uint8List bytes) async {
  try {
    final dir = await Directory.systemTemp.createTemp('sa_paste_');
    final file = File('${dir.path}${Platform.pathSeparator}pasted.png');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// Deletes a photo saved by [savePastedPhoto] (it's never kept).
Future<void> deletePastedPhoto(String path) async {
  try {
    await File(path).parent.delete(recursive: true);
  } catch (_) {}
}

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
  }
}

/// Shows the photo at [path] (while reviewing what was read from it).
Widget photoView(String path, {BoxFit fit = BoxFit.contain}) => Image.file(
  File(path),
  fit: fit,
  errorBuilder: (context, _, _) =>
      const Center(child: Icon(Icons.broken_image_outlined, size: 32)),
);

/// Photos are never kept. The phone's file picker hands over *copies* of
/// the chosen photos, in the app's cache; delete them once the review is
/// done. (The originals in the gallery aren't touched; Windows reads photos
/// where they are and makes no copies.)
Future<void> discardPickedPhotos() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    await FilePicker.platform.clearTemporaryFiles();
  } catch (_) {}
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
