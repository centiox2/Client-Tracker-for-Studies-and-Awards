import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_info.dart';

/// Catches unexpected errors anywhere in the app and sends them online
/// (Settings › Problems), so they're seen before anyone has to report them.
/// The same error isn't sent twice in a session, and at most 20 a session.
abstract final class ErrorReporter {
  /// Set by the app once it can reach the online database.
  static Future<void> Function(Map<String, Object?> report)? send;

  static final _sent = <String>{};
  static const _maxPerSession = 20;

  /// Hooks Flutter's and the platform's error handlers (keeping the
  /// existing ones).
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      // Layout overflows in release are cosmetic; still worth knowing.
      record(details.exception, details.stack, context: details.context);
    };
    final platformPrevious = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      return platformPrevious?.call(error, stack) ?? true;
    };
  }

  static void record(Object error, StackTrace? stack, {Object? context}) {
    final message = [
      error.toString().split('\n').first,
      if (context != null) '($context)',
    ].join(' ');
    final key = '$message|${stack.toString().split('\n').take(3).join()}';
    if (_sent.contains(key) || _sent.length >= _maxPerSession) return;
    _sent.add(key);
    final s = send;
    if (s == null) return;
    unawaited(
      s({
        'message': message,
        'stack': stack == null
            ? ''
            : stack.toString().split('\n').take(25).join('\n'),
        'version': AppInfo.version,
        'platform': AppInfo.platform,
      }),
    );
  }

  @visibleForTesting
  static void reset() => _sent.clear();
}
