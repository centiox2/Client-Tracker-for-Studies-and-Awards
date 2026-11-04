import 'package:client_tracker/state/app_state.dart';

/// Starts the app already signed in as admin, skipping the sign-in step in
/// widget tests that are about the workspace.
class SignedInSession extends AdminSessionNotifier {
  @override
  UserRole? build() => UserRole.admin;
}

/// The Director profile: sees everything, revenue included; changes
/// nothing (what used to be the open, signed-out view).
class DirectorSession extends AdminSessionNotifier {
  @override
  UserRole? build() => UserRole.director;
}
