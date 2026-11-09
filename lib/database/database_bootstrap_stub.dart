import 'database.dart';

/// Fallback for unsupported targets. The conditional import in
/// `database_bootstrap.dart` replaces this on io and web platforms.
Future<AppDatabase> openPlatformDatabase(String directory) async {
  throw UnsupportedError(
    'This platform is not supported by S&A Hub (io and web only).',
  );
}

/// False: neither the browser nor a file backend is in use.
bool get isWebDatabase => false;
