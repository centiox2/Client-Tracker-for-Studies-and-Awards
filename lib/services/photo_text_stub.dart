bool get photoTextSupported => false;

/// Lets the user choose a photo; its path, or null if cancelled.
Future<String?> pickPhoto() async => null;

/// The text in the photo at [path].
Future<String> readPhotoText(String path) async => '';
