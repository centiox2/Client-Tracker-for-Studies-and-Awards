import 'package:client_tracker/state/app_state.dart';

/// Starts the app already signed in as admin, skipping the sign-in step in
/// widget tests that are about the workspace.
class SignedInSession extends AdminSessionNotifier {
  @override
  bool build() => true;
}
