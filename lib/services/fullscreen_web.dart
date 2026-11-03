import 'package:web/web.dart' as web;

/// Asks the browser to fill the screen (TV mode). Browsers only allow it
/// after a click, which is how TV mode is opened; failures are ignored.
void enterFullscreen() {
  try {
    if (web.document.fullscreenElement == null) {
      web.document.documentElement?.requestFullscreen();
    }
  } catch (_) {}
}

void exitFullscreen() {
  try {
    if (web.document.fullscreenElement != null) web.document.exitFullscreen();
  } catch (_) {}
}
