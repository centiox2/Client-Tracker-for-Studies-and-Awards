import 'database.dart';
import 'database_bootstrap_stub.dart'
    if (dart.library.io) 'app_database_io.dart'
    if (dart.library.js_interop) 'app_database_web.dart';

export 'database.dart';
export 'database_bootstrap_stub.dart'
    if (dart.library.io) 'app_database_io.dart'
    if (dart.library.js_interop) 'app_database_web.dart';

/// Convenience for callers that just need the database:
/// `final db = await openAppDatabase(directory);`
Future<AppDatabase> openAppDatabase(String directory) async =>
    openPlatformDatabase(directory);
