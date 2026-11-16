/// The personal to-do list's items and the small rules around them
/// (dates, repeats, what a typed line means). No Flutter here, so it is
/// easy to test.
library;

/// "Now" for the to-do list (tests set it).
DateTime Function() todoClock = DateTime.now;

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime todoToday() => dateOnly(todoClock());

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// How an item comes back once it's done.
enum TodoRepeat {
  none('Never'),
  daily('Every day'),
  weekdays('Weekdays'),
  weekly('Every week'),
  monthly('Every month');

  const TodoRepeat(this.label);
  final String label;

  static TodoRepeat named(String? name) =>
      values.where((r) => r.name == name).firstOrNull ?? none;

  /// The next day after [from].
  DateTime next(DateTime from) {
    final d = dateOnly(from);
    switch (this) {
      case none:
      case daily:
        return DateTime(d.year, d.month, d.day + 1);
      case weekdays:
        var n = DateTime(d.year, d.month, d.day + 1);
        while (n.weekday > DateTime.friday) {
          n = DateTime(n.year, n.month, n.day + 1);
        }
        return n;
      case weekly:
        return DateTime(d.year, d.month, d.day + 7);
      case monthly:
        final last = DateTime(d.year, d.month + 2, 0).day;
        return DateTime(d.year, d.month + 1, d.day > last ? last : d.day);
    }
  }
}

/// A small step inside an item.
class TodoStep {
  const TodoStep(this.title, {this.done = false});
  final String title;
  final bool done;

  TodoStep copyWith({String? title, bool? done}) =>
      TodoStep(title ?? this.title, done: done ?? this.done);

  Map<String, Object?> toJson() => {'t': title, if (done) 'd': true};

  static TodoStep fromJson(Map<String, Object?> j) =>
      TodoStep(j['t'] as String? ?? '', done: j['d'] as bool? ?? false);
}

const _unset = Object();

/// One line on a to-do list (yours, or your department's shared list).
class TodoItem {
  const TodoItem({
    required this.id,
    required this.title,
    this.done = false,
    this.doneAt,
    this.sentId,
    this.deleted = false,
    this.changedAt,
    this.team = false,
    this.notes = '',
    this.day,
    this.later = false,
    this.due,
    this.dueTime = false,
    this.starred = false,
    this.pos,
    this.repeat = TodoRepeat.none,
    this.steps = const [],
    this.outputs = const {},
    this.clientKey,
    this.clientName,
    this.fromName,
    this.isNew = false,
    this.archived = false,
    this.doneBy,
    this.changedBy,
    this.spawned,
    this.autoTicked = false,
    this.reportReview,
    this.reportStatus,
  });

  final int id;
  final String title;
  final bool done;
  final DateTime? doneAt;

  /// The Daily reports task it was sent as (-1: waiting to be sent).
  final int? sentId;

  /// Only on changes waiting to be saved online: it was deleted.
  final bool deleted;

  /// When it was last changed (decides which device's change wins).
  final DateTime? changedAt;

  /// On the department's shared list.
  final bool team;

  final String notes;

  /// The day it's planned for (none: today, unless [later]).
  final DateTime? day;

  /// Some day, no date yet.
  final bool later;

  /// The deadline (with a time when [dueTime]).
  final DateTime? due;
  final bool dueTime;

  final bool starred;

  /// Its place in the list (smaller first).
  final double? pos;
  final TodoRepeat repeat;
  final List<TodoStep> steps;

  /// Counts sent with it to Daily reports.
  final Map<String, int> outputs;

  /// The client it's about (an application's key and the student's name).
  final String? clientKey;
  final String? clientName;

  /// Who gave it to you.
  final String? fromName;

  /// Given to you and not looked at yet.
  final bool isNew;

  /// Done and cleared from the list (still in History).
  final bool archived;

  /// Shared list: who ticked it, who changed it last.
  final String? doneBy;
  final String? changedBy;

  /// A repeating item: the next one, once made.
  final int? spawned;

  /// Ticked because its Daily reports task was finished.
  final bool autoTicked;

  /// Its Daily reports task's review and status (from the server).
  final String? reportReview;
  final String? reportStatus;

  String get key => team ? 't$id' : 'p$id';
  bool get sent => sentId != null;
  double get order => pos ?? id.toDouble();
  bool get hasDetails =>
      notes.isNotEmpty || steps.isNotEmpty || outputs.isNotEmpty;

  /// The day it belongs to on the list (null: Later).
  DateTime? get planned => later ? null : (day ?? todoToday());

  bool get overdue {
    final d = due;
    if (d == null || done || archived) return false;
    final now = todoClock();
    return dueTime ? d.isBefore(now) : dateOnly(d).isBefore(dateOnly(now));
  }

  TodoItem copyWith({
    String? title,
    bool? done,
    Object? doneAt = _unset,
    Object? sentId = _unset,
    bool? deleted,
    DateTime? changedAt,
    bool? team,
    String? notes,
    Object? day = _unset,
    bool? later,
    Object? due = _unset,
    bool? dueTime,
    bool? starred,
    Object? pos = _unset,
    TodoRepeat? repeat,
    List<TodoStep>? steps,
    Map<String, int>? outputs,
    Object? clientKey = _unset,
    Object? clientName = _unset,
    bool? isNew,
    bool? archived,
    Object? doneBy = _unset,
    Object? spawned = _unset,
    bool? autoTicked,
  }) => TodoItem(
    id: id,
    title: title ?? this.title,
    done: done ?? this.done,
    doneAt: doneAt == _unset ? this.doneAt : doneAt as DateTime?,
    sentId: sentId == _unset ? this.sentId : sentId as int?,
    deleted: deleted ?? this.deleted,
    changedAt: changedAt ?? this.changedAt,
    team: team ?? this.team,
    notes: notes ?? this.notes,
    day: day == _unset ? this.day : day as DateTime?,
    later: later ?? this.later,
    due: due == _unset ? this.due : due as DateTime?,
    dueTime: dueTime ?? this.dueTime,
    starred: starred ?? this.starred,
    pos: pos == _unset ? this.pos : pos as double?,
    repeat: repeat ?? this.repeat,
    steps: steps ?? this.steps,
    outputs: outputs ?? this.outputs,
    clientKey: clientKey == _unset ? this.clientKey : clientKey as String?,
    clientName: clientName == _unset ? this.clientName : clientName as String?,
    fromName: fromName,
    isNew: isNew ?? this.isNew,
    archived: archived ?? this.archived,
    doneBy: doneBy == _unset ? this.doneBy : doneBy as String?,
    changedBy: changedBy,
    spawned: spawned == _unset ? this.spawned : spawned as int?,
    autoTicked: autoTicked ?? this.autoTicked,
    reportReview: reportReview,
    reportStatus: reportStatus,
  );

  Map<String, Object?> get extra => {
    if (notes.isNotEmpty) 'notes': notes,
    if (day != null) 'day': _ymd(day!),
    if (later) 'later': true,
    if (due != null) 'due': dueTime ? '${_ymd(due!)}T${_hm(due!)}' : _ymd(due!),
    if (starred) 'starred': true,
    if (pos != null) 'pos': pos,
    if (repeat != TodoRepeat.none) 'repeat': repeat.name,
    if (steps.isNotEmpty) 'steps': [for (final s in steps) s.toJson()],
    if (outputs.isNotEmpty) 'outputs': outputs,
    if (clientKey != null)
      'client': {'key': clientKey, 'name': clientName ?? clientKey},
    if (fromName != null) 'from': {'name': fromName},
    if (isNew) 'new': true,
    if (archived) 'archived': true,
    if (doneBy != null) 'done_by': doneBy,
    if (spawned != null) 'spawned': spawned,
    if (autoTicked) 'auto_ticked': true,
  };

  /// As sent to the server (and kept on the device).
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'done': done,
    'done_at': doneAt?.toUtc().toIso8601String(),
    'sent_id': sentId,
    if (deleted) 'deleted': true,
    if (team) 'team': true,
    'changed_at': changedAt?.toUtc().toIso8601String(),
    'extra': extra,
    if (reportReview != null) 'report_review': reportReview,
    if (reportStatus != null) 'report_status': reportStatus,
    if (changedBy != null) 'changed_by_name': changedBy,
  };

  factory TodoItem.fromJson(Map<String, Object?> j) {
    final x = (j['extra'] as Map?)?.cast<String, Object?>() ?? const {};
    final dueRaw = x['due'] as String?;
    final client = (x['client'] as Map?)?.cast<String, Object?>();
    final from = (x['from'] as Map?)?.cast<String, Object?>();
    return TodoItem(
      id: (j['id'] as num).toInt(),
      title: j['title'] as String? ?? '',
      done: j['done'] as bool? ?? false,
      doneAt: DateTime.tryParse(j['done_at'] as String? ?? '')?.toLocal(),
      sentId: (j['sent_id'] as num?)?.toInt(),
      deleted: j['deleted'] as bool? ?? false,
      team: j['team'] as bool? ?? false,
      changedAt: DateTime.tryParse(j['changed_at'] as String? ?? '')?.toLocal(),
      notes: x['notes'] as String? ?? '',
      day: DateTime.tryParse(x['day'] as String? ?? ''),
      later: x['later'] as bool? ?? false,
      due: DateTime.tryParse(dueRaw ?? ''),
      dueTime: dueRaw != null && dueRaw.contains('T'),
      starred: x['starred'] as bool? ?? false,
      pos: (x['pos'] as num?)?.toDouble(),
      repeat: TodoRepeat.named(x['repeat'] as String?),
      steps: [
        for (final s in (x['steps'] as List? ?? const []).cast<Map>())
          TodoStep.fromJson(s.cast<String, Object?>()),
      ],
      outputs: {
        for (final e
            in ((x['outputs'] as Map?)?.cast<String, Object?>() ?? const {})
                .entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      },
      clientKey: client?['key'] as String?,
      clientName: client?['name'] as String?,
      fromName: from?['name'] as String?,
      isNew: x['new'] as bool? ?? false,
      archived: x['archived'] as bool? ?? false,
      doneBy: x['done_by'] as String?,
      changedBy: j['changed_by_name'] as String?,
      spawned: (x['spawned'] as num?)?.toInt(),
      autoTicked: x['auto_ticked'] as bool? ?? false,
      reportReview: j['report_review'] as String?,
      reportStatus: j['report_status'] as String?,
    );
  }
}

/// What a typed line means: "Call the embassy tomorrow 3pm !" is the title
/// "Call the embassy", planned for tomorrow, due at 15:00, starred.
class TodoDraft {
  const TodoDraft({
    required this.title,
    this.day,
    this.later = false,
    this.due,
    this.dueTime = false,
    this.starred = false,
    this.repeat = TodoRepeat.none,
    this.team = false,
  });

  final String title;
  final DateTime? day;
  final bool later;
  final DateTime? due;
  final bool dueTime;
  final bool starred;
  final TodoRepeat repeat;
  final bool team;

  bool get understood =>
      day != null ||
      later ||
      due != null ||
      starred ||
      repeat != TodoRepeat.none ||
      team;
}

const _starWords = {'!', '!!', '!!!', 'urgent', 'important', 'asap'};
const _laterWords = {'later', 'someday', 'sometime'};
const _deadlineWords = {'by', 'due', 'before'};
const _linkWords = {'on', 'at', 'for'};
const _weekdayNames = {
  'mon': DateTime.monday,
  'monday': DateTime.monday,
  'tue': DateTime.tuesday,
  'tues': DateTime.tuesday,
  'tuesday': DateTime.tuesday,
  'wed': DateTime.wednesday,
  'wednesday': DateTime.wednesday,
  'thu': DateTime.thursday,
  'thur': DateTime.thursday,
  'thurs': DateTime.thursday,
  'thursday': DateTime.thursday,
  'fri': DateTime.friday,
  'friday': DateTime.friday,
  'sat': DateTime.saturday,
  'saturday': DateTime.saturday,
  'sun': DateTime.sunday,
  'sunday': DateTime.sunday,
};

String _word(String w) => w.toLowerCase().replaceAll(RegExp(r'[,.;:]+$'), '');

DateTime? _namedDay(String w, DateTime today) {
  DateTime add(int n) => DateTime(today.year, today.month, today.day + n);
  if (w == 'today' || w == 'tonight') return add(0);
  if (w == 'tomorrow' || w == 'tmr' || w == 'tmrw') return add(1);
  final wd = _weekdayNames[w];
  if (wd == null) return null;
  final ahead = (wd - today.weekday) % 7;
  return add(ahead == 0 ? 7 : ahead);
}

/// "3pm", "3:30pm", "15:00" → (hour, minute).
(int, int)? _time(String w) {
  final m = RegExp(r'^(\d{1,2})(?:[:.](\d{2}))?(am|pm)$').firstMatch(w);
  if (m != null) {
    var h = int.parse(m[1]!);
    final min = int.parse(m[2] ?? '0');
    if (h < 1 || h > 12 || min > 59) return null;
    if (m[3] == 'pm' && h != 12) h += 12;
    if (m[3] == 'am' && h == 12) h = 0;
    return (h, min);
  }
  final m24 = RegExp(r'^(\d{1,2})[:.](\d{2})$').firstMatch(w);
  if (m24 != null) {
    final h = int.parse(m24[1]!);
    final min = int.parse(m24[2]!);
    if (h > 23 || min > 59) return null;
    return (h, min);
  }
  return null;
}

TodoDraft parseTodoLine(String text, {DateTime? now, bool allowTeam = false}) {
  final today = dateOnly(now ?? todoClock());
  final plain = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  final words = plain.isEmpty ? <String>[] : plain.split(' ');
  DateTime? day;
  DateTime? dueDay;
  (int, int)? time;
  var later = false;
  var starred = false;
  var team = false;
  var repeat = TodoRepeat.none;

  if (allowTeam && words.length > 1 && _word(words.first) == '#team') {
    team = true;
    words.removeAt(0);
  }
  while (words.length > 1) {
    final w = _word(words.last);
    final before = words.length > 2 ? _word(words[words.length - 2]) : '';
    if (!starred && _starWords.contains(w)) {
      starred = true;
    } else if (!later && _laterWords.contains(w)) {
      later = true;
    } else if (allowTeam && !team && w == '#team') {
      team = true;
    } else if (repeat == TodoRepeat.none &&
        (w == 'daily' || w == 'weekdays' || w == 'weekly' || w == 'monthly')) {
      repeat = TodoRepeat.named(w);
    } else if (repeat == TodoRepeat.none &&
        before == 'every' &&
        (w == 'day' ||
            w == 'weekday' ||
            w == 'week' ||
            w == 'month' ||
            _weekdayNames.containsKey(w))) {
      repeat = switch (w) {
        'day' => TodoRepeat.daily,
        'weekday' => TodoRepeat.weekdays,
        'month' => TodoRepeat.monthly,
        _ => TodoRepeat.weekly,
      };
      if (_weekdayNames.containsKey(w)) day ??= _namedDay(w, today);
      words.removeLast();
    } else if (time == null && _time(w) != null) {
      time = _time(w);
      if (words.length > 2 &&
          (_deadlineWords.contains(before) || _linkWords.contains(before))) {
        words.removeLast();
      }
    } else if (_namedDay(w, today) != null && day == null && dueDay == null) {
      final d = _namedDay(w, today)!;
      if (_deadlineWords.contains(before)) {
        dueDay = d;
        words.removeLast();
      } else {
        day = d;
        if (words.length > 2 && _linkWords.contains(before)) {
          words.removeLast();
        }
      }
    } else {
      break;
    }
    words.removeLast();
  }
  final title = words.join(' ').replaceAll(RegExp(r'[\s,;:–-]+$'), '');
  if (title.trim().isEmpty) return TodoDraft(title: plain);
  DateTime? due;
  var dueTime = false;
  if (time != null) {
    final on = dueDay ?? day ?? today;
    due = DateTime(on.year, on.month, on.day, time.$1, time.$2);
    dueTime = true;
  } else if (dueDay != null) {
    due = dueDay;
  }
  return TodoDraft(
    title: title,
    day: later ? null : (day == today ? null : day),
    later: later && day == null,
    due: due,
    dueTime: dueTime,
    starred: starred,
    repeat: repeat,
    team: team,
  );
}
