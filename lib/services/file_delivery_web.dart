import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Saves [bytes] by triggering a browser download of [defaultName].
/// Returns the suggested filename (browsers don't report the chosen path),
/// or null if the download was blocked or failed.
Future<String?> saveFileBytes({
  required String dialogTitle,
  required String defaultName,
  required List<String> extensions,
  required Uint8List bytes,
}) async {
  final parts = <web.BlobPart>[bytes.toJS];
  final blob = web.Blob(
    parts.toJS,
    web.BlobPropertyBag(type: _mimeType(defaultName)),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = defaultName;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return defaultName;
}

/// Opens a file via the browser's file input and returns its bytes.
Future<Uint8List?> openFileBytes({
  required String dialogTitle,
  required List<String> extensions,
}) {
  final completer = Completer<Uint8List?>();
  final input = web.document.createElement('input') as web.HTMLInputElement;
  input.type = 'file';
  input.accept = extensions.map((e) => '.$e').join(',');

  input.onchange = ((web.Event event) {
    final file = input.files?.item(0);
    if (file == null) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final reader = web.FileReader();
    reader.onload = ((web.Event _) {
      final result = reader.result;
      if (!completer.isCompleted) {
        if (result == null) {
          completer.complete(null);
        } else {
          completer.complete((result as JSArrayBuffer).toDart.asUint8List());
        }
      }
    }).toJS;
    reader.onerror = ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;
    reader.readAsArrayBuffer(file);
  }).toJS;
  // Firing when the user closes the file dialog without choosing a file;
  // without this the Restore flow would stay busy forever.
  input.oncancel = ((web.Event _) {
    if (!completer.isCompleted) completer.complete(null);
  }).toJS;

  web.document.body!.appendChild(input);
  input.click();
  input.remove();
  return completer.future;
}

/// False: on the web there are no OS file paths.
bool get isDesktopFiles => false;

String _mimeType(String name) {
  if (name.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (name.endsWith('.json')) return 'application/json';
  if (name.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}
