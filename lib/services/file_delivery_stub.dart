import 'dart:typed_data';

/// Fallback for unsupported targets; replaced by the conditional import.
Future<String?> saveFileBytes({
  required String dialogTitle,
  required String defaultName,
  required List<String> extensions,
  required Uint8List bytes,
}) async {
  throw UnsupportedError('Saving files is not supported on this platform.');
}

Future<Uint8List?> openFileBytes({
  required String dialogTitle,
  required List<String> extensions,
}) async {
  throw UnsupportedError('Opening files is not supported on this platform.');
}

bool get isDesktopFiles => false;
