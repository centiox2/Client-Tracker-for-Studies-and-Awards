import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'photo_text_types.dart';

export 'photo_text_types.dart';

bool get photoTextSupported => false;

/// Photos can be dragged onto the window (desktop).
bool get photoDropSupported => false;

/// Lets the user choose one or more photos; their paths (empty if cancelled).
Future<List<String>> pickPhotos() async => const [];

/// Reads the text in each photo.
Future<List<PhotoText>> readPhotoTexts(
  List<String> paths, {
  void Function(int done)? onProgress,
}) async => [
  for (final p in paths)
    PhotoText(p, error: 'Photos can’t be read on this device'),
];

/// Shows the photo at [path] (nothing where photos can't be read).
Widget photoView(String path, {BoxFit fit = BoxFit.contain}) =>
    const SizedBox.shrink();

/// Deletes any temporary copies of picked photos (none here).
Future<void> discardPickedPhotos() async {}

/// Images can be pasted from the clipboard (none here).
bool get photoPasteSupported => false;

/// Saves pasted image [bytes] where they can be read; its path.
Future<String?> savePastedPhoto(Uint8List bytes) async => null;

/// Deletes a photo saved by [savePastedPhoto].
Future<void> deletePastedPhoto(String path) async {}
