import 'dart:async';
import 'dart:io';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Something shared into the app: photo paths, or a message's text.
typedef SharedItems = ({List<String> photos, String? text});

StreamSubscription<List<SharedMediaFile>>? _sub;

SharedItems _items(List<SharedMediaFile> files) => (
  photos: [
    for (final f in files)
      if (f.type == SharedMediaType.image) f.path,
  ],
  text: files
      .where((f) => f.type == SharedMediaType.text)
      .map((f) => f.path)
      .join('\n')
      .trim()
      .let((t) => t.isEmpty ? null : t),
);

/// Calls [onShared] for what was shared when the app was opened that way,
/// and for anything shared while it runs.
void listenForShares(void Function(SharedItems items) onShared) {
  if (!Platform.isAndroid) return;
  void handle(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final items = _items(files);
    if (items.photos.isNotEmpty || items.text != null) onShared(items);
  }

  _sub ??= ReceiveSharingIntent.instance.getMediaStream().listen(handle);
  ReceiveSharingIntent.instance.getInitialMedia().then((files) {
    handle(files);
    // So the same share isn't handled again next time the app starts.
    ReceiveSharingIntent.instance.reset();
  });
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

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
