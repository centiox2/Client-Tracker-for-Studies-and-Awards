import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';

/// One line on the personal to-do list.
class TodoItem {
  const TodoItem({
    required this.id,
    required this.title,
    this.done = false,
    this.doneAt,
    this.sentId,
    this.deleted = false,
    this.changedAt,
  });

  final int id;
  final String title;
  final bool done;
  final DateTime? doneAt;

  /// The Daily reports task it was sent as, once sent (-1: waiting to go).
  final int? sentId;

  /// Only on changes waiting to be saved online: it was deleted.
  final bool deleted;

  /// When it was last changed (decides which device's change wins).
  final DateTime? changedAt;

  bool get sent => sentId != null;

  TodoItem copyWith({
    String? title,
    bool? done,
    DateTime? doneAt,
    bool clearDoneAt = false,
    int? sentId,
    bool? deleted,
    DateTime? changedAt,
  }) => TodoItem(
    id: id,
    title: title ?? this.title,
    done: done ?? this.done,
    doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
    sentId: sentId ?? this.sentId,
    deleted: deleted ?? this.deleted,
    changedAt: changedAt ?? this.changedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'done': done,
    'done_at': doneAt?.toUtc().toIso8601String(),
    'sent_id': sentId,
    if (deleted) 'deleted': true,
    'changed_at': changedAt?.toUtc().toIso8601String(),
  };

  factory TodoItem.fromJson(Map<String, Object?> j) => TodoItem(
    id: (j['id'] as num).toInt(),
    title: j['title'] as String? ?? '',
    done: j['done'] as bool? ?? false,
    doneAt: DateTime.tryParse(j['done_at'] as String? ?? '')?.toLocal(),
    sentId: (j['sent_id'] as num?)?.toInt(),
    deleted: j['deleted'] as bool? ?? false,
    changedAt: DateTime.tryParse(j['changed_at'] as String? ?? '')?.toLocal(),
  );
}

/// Whether the list is kept with the account online, and how that's going.
enum TodoSync {
  /// This device only (not signed in to an account).
  device,

  /// Saved online; the same on every device.
  saved,

  /// Changes are waiting to be saved online.
  pending,

  /// Couldn't reach the server; changes are kept and sent later.
  offline,
}

/// The personal to-do list. Signed in, it's kept with the account so every
/// device shows the same list (a copy stays on the device for offline use);
/// otherwise it stays on this device.
final todoListProvider = NotifierProvider<TodoListNotifier, List<TodoItem>>(
  TodoListNotifier.new,
);

class TodoListNotifier extends Notifier<List<TodoItem>> {
  int? _owner;
  bool _loaded = false;
  bool _online = false;
  TodoSync _sync = TodoSync.device;

  /// Changes not saved online yet, by id (deleted ones included).
  final _dirty = <int, TodoItem>{};
  Timer? _pushTimer;
  Future<void>? _syncing;

  static String _key(int? user) => 'todo_list_${user ?? 'device'}';

  @override
  List<TodoItem> build() {
    _owner = ref.watch(currentUserProvider)?.id;
    _online = _owner != null && ref.watch(accountsEnabledProvider);
    _sync = _online ? TodoSync.saved : TodoSync.device;
    _loaded = false;
    _dirty.clear();
    _pushTimer?.cancel();
    ref.onDispose(() => _pushTimer?.cancel());
    unawaited(_load(_owner));
    return const [];
  }

  /// Whether the saved list has been read.
  bool get loaded => _loaded;

  TodoSync get sync => _sync;

  void _setSync(TodoSync s) {
    if (s == _sync) return;
    _sync = s;
    ref.notifyListeners();
  }

  // ------------------------------------------------------ On the device ---

  Future<void> _load(int? owner) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _key(owner),
      );
      if (owner != _owner) return;
      if (raw != null) {
        final data = jsonDecode(raw);
        // Plain list: an older copy. Else {items, dirty}.
        final items = data is List ? data : (data as Map)['items'] as List;
        final dirty = data is Map ? (data['dirty'] as List? ?? []) : [];
        for (final j in dirty.cast<Map>()) {
          final t = TodoItem.fromJson(j.cast<String, Object?>());
          _dirty[t.id] = t;
        }
        state = _sorted([
          for (final j in items.cast<Map>())
            TodoItem.fromJson(j.cast<String, Object?>()),
        ]);
      }
    } catch (_) {}
    _loaded = true;
    ref.notifyListeners();
    if (_online) unawaited(refresh());
  }

  Future<void> _store() async {
    final owner = _owner;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(owner),
      jsonEncode({
        'items': [for (final t in state) t.toJson()],
        'dirty': [for (final t in _dirty.values) t.toJson()],
      }),
    );
  }

  static List<TodoItem> _sorted(List<TodoItem> items) =>
      items..sort((a, b) => a.id.compareTo(b.id));

  /// Applies a change on this device, then saves it (online soon after).
  void _change(List<TodoItem> items, Iterable<TodoItem> changed) {
    state = _sorted(items);
    if (_online) {
      for (final t in changed) {
        _dirty[t.id] = t;
      }
      _setSync(TodoSync.pending);
      _pushTimer?.cancel();
      _pushTimer = Timer(const Duration(milliseconds: 700), () {
        unawaited(refresh());
      });
    }
    unawaited(_store());
  }

  // ------------------------------------------------------------- Online ---

  /// Sends what changed here and takes in changes from other devices.
  Future<void> refresh() {
    if (!_online) return Future.value();
    return _syncing ??= _refresh().whenComplete(() => _syncing = null);
  }

  Future<void> _refresh() async {
    final owner = _owner;
    final sync = ref.read(cloudSyncProvider.notifier);
    if (!sync.enabled) return;
    final sending = Map.of(_dirty);
    try {
      final result = sending.isEmpty
          ? await sync.callAsUser('todo_list')
          : await sync.callAsUser('todo_save', {
              'p_items': [for (final t in sending.values) t.toJson()],
            });
      if (owner != _owner) return;
      // Sent: no longer waiting (unless changed again meanwhile).
      sending.forEach((id, t) {
        if (identical(_dirty[id], t)) _dirty.remove(id);
      });
      final server = [
        for (final j in (result as List).cast<Map>())
          TodoItem.fromJson(j.cast<String, Object?>()),
      ];
      // What's online, with changes made here since laid on top.
      final byId = {for (final t in server) t.id: t};
      for (final t in _dirty.values) {
        if (t.deleted) {
          byId.remove(t.id);
        } else {
          byId[t.id] = t;
        }
      }
      state = _sorted(byId.values.toList());
      _setSync(_dirty.isEmpty ? TodoSync.saved : TodoSync.pending);
      unawaited(_store());
      if (_dirty.isNotEmpty) {
        _pushTimer?.cancel();
        _pushTimer = Timer(const Duration(milliseconds: 700), () {
          unawaited(refresh());
        });
      }
    } catch (_) {
      if (owner == _owner) _setSync(TodoSync.offline);
    }
  }

  // ------------------------------------------------------------ Changes ---

  int _nextId() {
    var id = DateTime.now().microsecondsSinceEpoch;
    while (state.any((t) => t.id == id) || _dirty.containsKey(id)) {
      id++;
    }
    return id;
  }

  /// Adds each non-empty line; returns what was added.
  List<TodoItem> add(List<String> titles) {
    final added = <TodoItem>[];
    final now = DateTime.now();
    for (final raw in titles) {
      var title = raw
          .replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)]|\[ ?\])\s+'), '')
          .trim();
      if (title.isEmpty) continue;
      if (title.length > 300) title = title.substring(0, 300);
      added.add(
        TodoItem(id: _nextId() + added.length, title: title, changedAt: now),
      );
    }
    if (added.isNotEmpty) _change([...state, ...added], added);
    return added;
  }

  void _update(int id, TodoItem Function(TodoItem) f) {
    final now = DateTime.now();
    TodoItem? changed;
    final items = [
      for (final t in state)
        if (t.id == id) changed = f(t).copyWith(changedAt: now) else t,
    ];
    if (changed != null) _change(items, [changed]);
  }

  void toggle(int id) => _update(
    id,
    (t) => t.copyWith(
      done: !t.done,
      doneAt: t.done ? null : DateTime.now(),
      clearDoneAt: t.done,
    ),
  );

  void rename(int id, String title) {
    final clean = title.trim();
    if (clean.isEmpty) return;
    _update(
      id,
      (t) => t.copyWith(
        title: clean.length > 300 ? clean.substring(0, 300) : clean,
      ),
    );
  }

  void markSent(int id, int reportId) =>
      _update(id, (t) => t.copyWith(sentId: reportId));

  /// Removes [ids]; returns what was removed with where it was (for Undo).
  List<(int, TodoItem)> remove(Iterable<int> ids) {
    final gone = <(int, TodoItem)>[];
    for (final (i, t) in state.indexed) {
      if (ids.contains(t.id)) gone.add((i, t));
    }
    if (gone.isNotEmpty) {
      final now = DateTime.now();
      _change(
        [
          for (final t in state)
            if (!ids.contains(t.id)) t,
        ],
        [for (final (_, t) in gone) t.copyWith(deleted: true, changedAt: now)],
      );
    }
    return gone;
  }

  /// Puts back what [remove] took.
  void restore(List<(int, TodoItem)> gone) {
    final now = DateTime.now();
    final back = [
      for (final (_, t) in gone) t.copyWith(deleted: false, changedAt: now),
    ];
    _change([...state, ...back], back);
  }
}
