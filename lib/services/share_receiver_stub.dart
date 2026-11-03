/// Something shared into the app: photo paths, or a message's text.
typedef SharedItems = ({List<String> photos, String? text});

/// Calls [onShared] for what was shared when the app was opened that way,
/// and for anything shared while it runs.
void listenForShares(void Function(SharedItems items) onShared) {}

/// Deletes the app's own copies of shared photos once they've been read.
Future<void> deleteSharedCopies(List<String> paths) async {}
