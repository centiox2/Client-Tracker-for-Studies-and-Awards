import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'todo_model.dart';

export 'todo_model.dart';

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

/// Someone a to-do can be given to.
class TodoPerson {
  const TodoPerson(this.id, this.name, this.department);
  final int id;
  final String name;
  final String? department;
}

/// The to-do list: yours plus your department's shared list. Signed in,
/// it's kept with the account so every device shows the same (a copy stays
/// on the device for offline use); otherwise it stays on this device.
final todoListProvider = NotifierProvider<TodoListNotifier, List<TodoItem>>(
  TodoListNotifier.new,
);

class TodoListNotifier extends Notifier<List<TodoItem>> {
  int? _owner;
  bool _loaded = false;
  bool _online = false;
  TodoSync _sync = TodoSync.device;
  String? _teamName;

  /// Changes not saved online yet, by key (deleted ones included).
  final _dirty = <String, TodoItem>{};
  Timer? _pushTimer;
  Future<void>? _syncing;

  static String _key(int? user) => 'todo_list_${user ?? 'device'}';

  @override
  List<TodoItem> build() {
    _owner = ref.watch(currentUserProvider)?.id;
    _online = _owner != null && ref.watch(accountsEnabledProvider);
    _sync = _online ? TodoSync.saved : TodoSync.device;
    _loaded = false;
    _teamName = null;
    _dirty.clear();
    _pushTimer?.cancel();
    ref.onDispose(() => _pushTimer?.cancel());
    unawaited(_load(_owner));
    return const [];
  }

  /// Whether the saved list has been read.
  bool get loaded => _loaded;

  TodoSync get sync => _sync;

  /// The department's shared list, when this person has one.
  String? get teamName => _teamName;

  void _setSync(TodoSync s) {
    if (s == _sync) return;
    _sync = s;
    ref.notifyListeners();
  }

  String get _myName => ref.read(currentUserProvider)?.fullName ?? 'Me';

  // ------------------------------------------------------ On the device ---

  Future<void> _load(int? owner) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _key(owner),
      );
      if (owner != _owner) return;
      if (raw != null) {
        final data = jsonDecode(raw);
        // Plain list: an older copy. Else {items, dirty, team}.
        final items = data is List ? data : (data as Map)['items'] as List;
        final dirty = data is Map ? (data['dirty'] as List? ?? []) : [];
        if (data is Map) _teamName = data['team'] as String?;
        for (final j in dirty.cast<Map>()) {
          final t = TodoItem.fromJson(j.cast<String, Object?>());
          _dirty[t.key] = t;
        }
        state = _sorted([
          for (final j in items.cast<Map>())
            TodoItem.fromJson(j.cast<String, Object?>()),
        ]);
      }
    } catch (_) {}
    _loaded = true;
    _tidy();
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
        'team': _teamName,
      }),
    );
  }

  static List<TodoItem> _sorted(List<TodoItem> items) =>
      items..sort((a, b) => a.order.compareTo(b.order));

  /// Applies changes on this device, then saves them (online soon after).
  void _change(List<TodoItem> items, Iterable<TodoItem> changed) {
    state = _sorted(items);
    if (_online) {
      for (final t in changed) {
        _dirty[t.key] = t;
      }
      _setSync(TodoSync.pending);
      _schedulePush();
    }
    unawaited(_store());
  }

  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(refresh());
    });
  }

  /// Clears done items as the person chose (Settings on the page).
  void _tidy() {
    final days = ref.read(todoPrefsProvider).clearAfterDays;
    if (days == null) return;
    final cutoff = todoToday().subtract(Duration(days: days - 1));
    final now = todoClock();
    final changed = <TodoItem>[];
    final items = <TodoItem>[];
    for (final t in state) {
      if (t.done &&
          !t.archived &&
          !t.team &&
          t.doneAt != null &&
          dateOnly(t.doneAt!).isBefore(cutoff)) {
        final n = t.copyWith(archived: true, changedAt: now);
        changed.add(n);
        items.add(n);
      } else {
        items.add(t);
      }
    }
    if (changed.isNotEmpty) _change(items, changed);
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
      final result = await sync.callAsUser('todo_sync', {
        'p_items': [for (final t in sending.values) t.toJson()],
      }) as Map;
      if (owner != _owner) return;
      sending.forEach((k, t) {
        if (identical(_dirty[k], t)) _dirty.remove(k);
      });
      final team = (result['team'] as Map?)?.cast<String, Object?>();
      _teamName = team?['name'] as String?;
      final server = [
        for (final j in (result['items'] as List).cast<Map>())
          TodoItem.fromJson(j.cast<String, Object?>()),
        for (final j in (team?['items'] as List? ?? const []).cast<Map>())
          TodoItem.fromJson({...j.cast<String, Object?>(), 'team': true}),
      ];
      // What's online, with changes made here since laid on top.
      final byKey = {for (final t in server) t.key: t};
      for (final t in _dirty.values) {
        if (t.deleted) {
          byKey.remove(t.key);
        } else {
          byKey[t.key] = t;
        }
      }
      state = _sorted(byKey.values.toList());
      _setSync(_dirty.isEmpty ? TodoSync.saved : TodoSync.pending);
      ref.notifyListeners();
      unawaited(_store());
      _tidy();
      if (_dirty.isNotEmpty) _schedulePush();
    } catch (_) {
      if (owner == _owner) _setSync(TodoSync.offline);
    }
  }

  /// Everyone a to-do can be given to.
  Future<List<TodoPerson>> people() async {
    final rows =
        await ref.read(cloudSyncProvider.notifier).callAsUser('todo_people')
            as List;
    return [
      for (final r in rows.cast<Map>())
        TodoPerson(
          (r['id'] as num).toInt(),
          r['name'] as String? ?? '',
          r['department'] as String?,
        ),
    ];
  }

  /// Puts a copy of [t] on [person]'s list.
  Future<void> give(TodoItem t, TodoPerson person) =>
      ref.read(cloudSyncProvider.notifier).callAsUser('todo_give', {
        'p_user': person.id,
        'p_item': {
          'title': t.title,
          for (final e in t.extra.entries)
            if (e.key == 'day'
                ? !(t.planned ?? todoToday()).isBefore(todoToday())
                : const {
                    'notes',
                    'due',
                    'starred',
                    'steps',
                    'client',
                  }.contains(e.key))
              e.key: e.value,
        },
      });

  // ------------------------------------------------------------ Changes ---

  int _nextId([int extra = 0]) {
    var id = todoClock().microsecondsSinceEpoch + extra;
    while (state.any((t) => t.id == id) ||
        _dirty.values.any((t) => t.id == id)) {
      id++;
    }
    return id;
  }

  /// Adds a line each (typed words understood: see [parseTodoLine]).
  /// [shape] adds what was chosen beside the box (typed words win).
  List<TodoItem> addLines(
    List<String> lines, {
    bool team = false,
    TodoItem Function(TodoItem item, TodoDraft typed)? shape,
  }) {
    final added = <TodoItem>[];
    final now = todoClock();
    for (final raw in lines) {
      final line = raw
          .replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)]|\[ ?\])\s+'), '')
          .trim();
      if (line.isEmpty) continue;
      final d = parseTodoLine(line, allowTeam: _teamName != null);
      var title = d.title;
      if (title.length > 300) title = title.substring(0, 300);
      final item = TodoItem(
        id: _nextId(added.length),
        title: title,
        changedAt: now,
        team: team || d.team,
        day: d.later ? null : (d.day ?? todoToday()),
        later: d.later,
        due: d.due,
        dueTime: d.dueTime,
        starred: d.starred,
        repeat: d.repeat,
      );
      added.add(shape == null ? item : shape(item, d));
    }
    if (added.isNotEmpty) _change([...state, ...added], added);
    return added;
  }

  /// Adds one item made elsewhere (quick add, a client's card).
  TodoItem add(TodoItem t) {
    final item = TodoItem.fromJson({
      ...t.toJson(),
      'id': _nextId(),
      'changed_at': todoClock().toUtc().toIso8601String(),
    });
    _change([...state, item], [item]);
    return item;
  }

  TodoItem? byKey(String key) => state.where((t) => t.key == key).firstOrNull;

  /// Changes the items with these keys.
  void edit(Iterable<String> keys, TodoItem Function(TodoItem) f) {
    final now = todoClock();
    final changed = <TodoItem>[];
    final items = <TodoItem>[];
    for (final t in state) {
      if (keys.contains(t.key)) {
        final n = f(t).copyWith(changedAt: now);
        changed.add(n);
        items.add(n);
      } else {
        items.add(t);
      }
    }
    if (changed.isNotEmpty) _change(items, changed);
  }

  /// Ticks or unticks; a repeating item makes its next one when ticked.
  void toggle(String key) {
    final t = byKey(key);
    if (t == null) return;
    setDone([key], !t.done);
  }

  void setDone(Iterable<String> keys, bool done) {
    final now = todoClock();
    final spawn = <TodoItem>[];
    final changed = <TodoItem>[];
    final items = <TodoItem>[];
    for (final t in state) {
      if (!keys.contains(t.key) || t.done == done) {
        items.add(t);
        continue;
      }
      var next = t.copyWith(
        done: done,
        doneAt: done ? now : null,
        doneBy: done && t.team ? _myName : null,
        archived: false,
        changedAt: now,
      );
      if (done && t.repeat != TodoRepeat.none && t.spawned == null) {
        final base = t.planned ?? todoToday();
        final from = base.isBefore(todoToday()) ? todoToday() : base;
        final day = t.repeat.next(from);
        final shift = day.difference(dateOnly(base));
        final copy = TodoItem(
          id: _nextId(spawn.length + 1),
          title: t.title,
          changedAt: now,
          team: t.team,
          notes: t.notes,
          day: day,
          due: t.due?.add(shift),
          dueTime: t.dueTime,
          starred: t.starred,
          repeat: t.repeat,
          steps: [for (final s in t.steps) s.copyWith(done: false)],
          clientKey: t.clientKey,
          clientName: t.clientName,
        );
        spawn.add(copy);
        next = next.copyWith(spawned: copy.id);
      }
      items.add(next);
      changed.add(next);
    }
    if (changed.isEmpty) return;
    _change([...items, ...spawn], [...changed, ...spawn]);
  }

  void rename(String key, String title) {
    final clean = title.trim();
    if (clean.isEmpty) return;
    edit(
      [key],
      (t) => t.copyWith(
        title: clean.length > 300 ? clean.substring(0, 300) : clean,
      ),
    );
  }

  void star(String key) => edit([key], (t) => t.copyWith(starred: !t.starred));

  void moveToToday(Iterable<String> keys) =>
      edit(keys, (t) => t.copyWith(day: todoToday(), later: false));

  void moveToLater(Iterable<String> keys) =>
      edit(keys, (t) => t.copyWith(day: null, later: true));

  void markSent(String key, int reportId) =>
      edit([key], (t) => t.copyWith(sentId: reportId));

  /// Given items, now seen.
  void markSeen() {
    final keys = [
      for (final t in state)
        if (t.isNew) t.key,
    ];
    if (keys.isNotEmpty) edit(keys, (t) => t.copyWith(isNew: false));
  }

  /// Moves [key] to sit between [before] and [after] (keys or null).
  void place(String key, {String? before, String? after}) {
    final a = before == null ? null : byKey(before)?.order;
    final b = after == null ? null : byKey(after)?.order;
    final double pos;
    if (a != null && b != null) {
      pos = (a + b) / 2;
    } else if (a != null) {
      pos = a + 1;
    } else if (b != null) {
      pos = b - 1;
    } else {
      return;
    }
    edit([key], (t) => t.copyWith(pos: pos));
  }

  /// Done items off the list (kept in History).
  List<(int, TodoItem)> archive(Iterable<String> keys) {
    final gone = [
      for (final (i, t) in state.indexed)
        if (keys.contains(t.key)) (i, t),
    ];
    edit(keys, (t) => t.copyWith(archived: true));
    return gone;
  }

  /// Removes [keys]; returns what was removed (for Undo with [restore]).
  List<(int, TodoItem)> remove(Iterable<String> keys) {
    final gone = <(int, TodoItem)>[];
    for (final (i, t) in state.indexed) {
      if (keys.contains(t.key)) gone.add((i, t));
    }
    if (gone.isNotEmpty) {
      final now = todoClock();
      _change(
        [
          for (final t in state)
            if (!keys.contains(t.key)) t,
        ],
        [for (final (_, t) in gone) t.copyWith(deleted: true, changedAt: now)],
      );
    }
    return gone;
  }

  /// Puts back what [remove] or [archive] took, as it was.
  void restore(List<(int, TodoItem)> gone) {
    final now = todoClock();
    final back = [
      for (final (_, t) in gone) t.copyWith(deleted: false, changedAt: now),
    ];
    final keys = {for (final t in back) t.key};
    _change([
      for (final t in state)
        if (!keys.contains(t.key)) t,
      ...back,
    ], back);
  }
}

// ---------------------------------------------------------- Preferences ---

/// The person's to-do choices (on this device).
class TodoPrefs {
  const TodoPrefs({
    this.reminderMinutes = 16 * 60 + 30,
    this.clearAfterDays = 1,
  });

  /// When to offer sending the day's done items (minutes after midnight;
  /// null: never).
  final int? reminderMinutes;

  /// Done items leave the list this many days after (null: never).
  final int? clearAfterDays;

  Map<String, Object?> toJson() => {
    'reminder': reminderMinutes,
    'clear': clearAfterDays,
  };
}

final todoPrefsProvider = NotifierProvider<TodoPrefsNotifier, TodoPrefs>(
  TodoPrefsNotifier.new,
);

class TodoPrefsNotifier extends Notifier<TodoPrefs> {
  int? _owner;
  static String _key(int? user) => 'todo_prefs_${user ?? 'device'}';

  @override
  TodoPrefs build() {
    _owner = ref.watch(currentUserProvider)?.id;
    unawaited(_load(_owner));
    return const TodoPrefs();
  }

  Future<void> _load(int? owner) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _key(owner),
      );
      if (raw == null || owner != _owner) return;
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      state = TodoPrefs(
        reminderMinutes: (j['reminder'] as num?)?.toInt(),
        clearAfterDays: (j['clear'] as num?)?.toInt(),
      );
    } catch (_) {}
  }

  Future<void> set(TodoPrefs p) async {
    state = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(_owner), jsonEncode(p.toJson()));
  }
}

/// Asks the To-do page to open "Send to Daily reports" (from the end of
/// day reminder).
final todoSendRequestProvider = NotifierProvider<TodoSendRequest, bool>(
  TodoSendRequest.new,
);

class TodoSendRequest extends Notifier<bool> {
  @override
  bool build() => false;

  void request() => state = true;

  /// True once, when asked.
  bool take() {
    final asked = state;
    if (asked) state = false;
    return asked;
  }
}
