/// Reads the text in a photo (e.g. a payment message screenshot), on the
/// device itself: nothing is uploaded. Phones only (Android / iPhone); on
/// Windows and the web [photoTextSupported] is false.
library;

export 'photo_text_stub.dart' if (dart.library.io) 'photo_text_io.dart';
