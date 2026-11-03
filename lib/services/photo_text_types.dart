/// The text read from one photo (or why it couldn't be read), and the
/// photo file's own time — used when the message inside has no date.
class PhotoText {
  const PhotoText(this.path, {this.text, this.error, this.fileTime});
  final String path;
  final String? text;
  final String? error;
  final DateTime? fileTime;

  /// Just the file name, for showing which photo a payment came from.
  String get name => path.split(RegExp(r'[\\/]')).last;
}
