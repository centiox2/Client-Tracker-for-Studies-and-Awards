/// The online database (Supabase) every copy of the app syncs with.
///
/// The URL and publishable key are passed in at build time, so they are not
/// stored in the repository:
///
///   flutter build windows --dart-define-from-file=cloud.json
///
/// where cloud.json (kept out of git) holds SUPABASE_URL and SUPABASE_KEY.
/// Without them the app still works fully, just without online sync.
abstract final class CloudConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment('SUPABASE_KEY');

  /// Whether this build was given the online database's details.
  static bool get configured => url != '' && publishableKey != '';

  /// Set by `main()`. Off in tests, which never touch the network.
  static bool active = false;
}
