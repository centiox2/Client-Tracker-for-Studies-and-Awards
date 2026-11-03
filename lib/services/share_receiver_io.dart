import 'dart:io';

import 'package:flutter/services.dart';

/// Something shared into the app: photo paths, or a message's text.
typedef SharedItems = ({List<String> photos, String? text});

const _channel = MethodChannel('client_tracker/share');

SharedItems? _items(Object? raw) {
  if (raw is! Map) return null;
  final photos = [
    for (final p in (raw['photos'] as List? ?? const [])) '$p',
  ];
  final text = (raw['text'] as String?)?.trim();
  if (photos.isEmpty && (text == null || text.isEmpty)) return null;
  return (photos: photos, text: text == null || text.isEmpty ? null : text);
}

/// Calls [onShared] for what was shared when the app was opened that way,
/// and for anything shared while it runs. (Android: MainActivity.kt.)
void listenForShares(void Function(SharedItems items) onShared) {
  if (!Platform.isAndroid) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'share') {
      final items = _items(call.arguments);
      if (items != null) onShared(items);
    }
  });
  _channel.invokeMethod<Object?>('initialShare').then((raw) {
    final items = _items(raw);
    if (items != null) onShared(items);
  }, onError: (_) {});
}

/// Photos are never kept: the share hands the app *copies* (in its cache);
/// delete them once they've been read. The originals aren't touched.
Future<void> deleteSharedCopies(List<String> paths) async {
  if (!Platform.isAndroid) return;
  for (final p in paths) {
    try {
      await File(p).delete();
    } catch (_) {}
  }
}
