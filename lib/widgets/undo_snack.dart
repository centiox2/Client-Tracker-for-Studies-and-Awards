import 'package:flutter/material.dart';

/// "Removed X · Undo", the card shown after a delete. It goes away by itself.
void showUndoSnack(BuildContext context, String message, VoidCallback onUndo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        // Flutter keeps a card with a button up until it's tapped otherwise.
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      ),
    );
}
