import 'dart:async';
import 'dart:typed_data';

import 'package:client_tracker/screens/revenue/scan_payments.dart';

/// Runs before every test file. Nothing here answers the clipboard plugin,
/// so pasting on Revenue sees an empty clipboard on every computer (on
/// Windows the real plugin call would never return in a test).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  clipboardPhotos = const EmptyClipboard();
  await testMain();
}

/// A clipboard with no photo on it.
class EmptyClipboard extends ClipboardPhotos {
  const EmptyClipboard({this.supported = false});

  @override
  final bool supported;

  @override
  Future<List<String>> files() async => const [];

  @override
  Future<Uint8List?> image() async => null;
}
