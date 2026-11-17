import 'dart:async';

/// Whether [e] means "couldn't reach the server" (no internet, timed out,
/// connection dropped) rather than a fault worth showing. Read by type name
/// and message so it works the same on every platform, web included.
bool isConnectionError(Object e) {
  if (e is TimeoutException) return true;
  final type = e.runtimeType.toString();
  if (const {
    'SocketException',
    'ClientException',
    'HandshakeException',
    'HttpException',
    'AuthRetryableFetchException',
  }.contains(type)) {
    return true;
  }
  final text = '$e';
  return RegExp(
    r'SocketException|Failed host lookup|Connection (refused|reset|closed)|'
    r'Network is unreachable|XMLHttpRequest error|Failed to fetch|'
    r'ClientException',
    caseSensitive: false,
  ).hasMatch(text);
}
