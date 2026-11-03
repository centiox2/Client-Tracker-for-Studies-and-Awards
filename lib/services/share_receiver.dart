/// Photos or text shared into the app from another app (e.g. WhatsApp's or
/// Messages' Share → Client Tracker). Android only; elsewhere nothing
/// arrives.
library;

export 'share_receiver_stub.dart' if (dart.library.io) 'share_receiver_io.dart';
