import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'config/cloud_config.dart';
import 'database/database_bootstrap.dart';
import 'design/app_theme.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Sync with the online database (Supabase) when this build was given its
  // details. Tests leave this off.
  CloudConfig.active = CloudConfig.configured;

  // path_provider has no web implementation; the browser backend stores its
  // database in IndexedDB and ignores the directory entirely.
  final dataDir = kIsWeb
      ? '/client_tracker'
      : p.join(
          (await getApplicationDocumentsDirectory()).path,
          'ClientTracker',
        );

  AppDatabase db;
  try {
    db = await openAppDatabase(dataDir);
  } catch (e) {
    runApp(_StartupErrorApp(error: e));
    return;
  }

  // Automatic backups run daily from the app itself (autoBackupProvider).

  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const ClientTrackerApp(),
    ),
  );
}

/// Shown if the database cannot be opened at all. Points the user at the
/// backups instead of crashing silently.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final web = isWebDatabase;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Dt.s32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(Dt.rLg),
                  ),
                  child: Icon(
                    Icons.error_outline,
                    size: 24,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: Dt.s16),
                Text(
                  'Could not open the database',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: Dt.s8),
                Text(
                  '$error\n\n'
                  '${web ? 'Try reloading the page. Your data is stored in this '
                            'browser (IndexedDB); do not clear site data.' : 'Your data folder contains rolling backups '
                            '(client_tracker.db.bak1 … bak5) and automatic JSON '
                            'backups in the auto_backups folder. Do not delete '
                            'the data folder — restore one of those files.'}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Dt.textMuted(Theme.of(context))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
