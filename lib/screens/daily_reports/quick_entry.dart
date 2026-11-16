import '../../state/app_state.dart';

/// What a line typed in the quick line means, e.g.
/// "Lodged visas 3 done" or "Call embassy tomorrow urgent".
///
/// Words at the end are understood:
/// - "done" (or finished, completed): it's finished work, submitted now;
/// - a number: the department's count it matches by name (or its only one);
/// - today, tomorrow, a weekday ("by Friday"): the due date;
/// - urgent, high, low: the urgency.
/// The rest is the title.
class QuickEntry {
  const QuickEntry({
    required this.title,
    this.done = false,
    this.urgency,
    this.due,
    this.outputs = const {},
  });

  final String title;
  final bool done;
  final TaskUrgency? urgency;
  final DateTime? due;
  final Map<String, int> outputs;

  /// Anything beyond a plain title was understood (shown under the line).
  bool get understood =>
      done || urgency != null || due != null || outputs.isNotEmpty;
}

const _doneWords = {'done', 'finished', 'completed', 'complete'};
const _urgencyWords = {
  'urgent': TaskUrgency.urgent,
  'asap': TaskUrgency.urgent,
  'high': TaskUrgency.high,
  'low': TaskUrgency.low,
};
const _weekdays = {
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
const _dueLinks = {'by', 'on', 'due', 'for', 'before'};

String _plain(String w) =>
    w.toLowerCase().replaceAll(RegExp(r'^[^\w]+|[^\w]+$'), '');

/// A rough root, so "lodged" matches "Visas lodged" and "COEs" matches
/// "COE issued".
String _stem(String w) {
  var s = w.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  for (final end in ['ing', 'es', 's', 'ed', 'e']) {
    if (s.length > end.length + 2 && s.endsWith(end)) {
      s = s.substring(0, s.length - end.length);
      break;
    }
  }
  if (s.length > 3 && s[s.length - 1] == s[s.length - 2]) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// The day a word names, from [today]: today, tomorrow, or the next such
/// weekday (a week on if it's today's).
DateTime? _dayFor(String w, DateTime today) {
  DateTime add(int n) => DateTime(today.year, today.month, today.day + n);
  if (w == 'today' || w == 'tonight') return add(0);
  if (w == 'tomorrow' || w == 'tmr' || w == 'tmrw') return add(1);
  final wd = _weekdays[w];
  if (wd == null) return null;
  final ahead = (wd - today.weekday) % 7;
  return add(ahead == 0 ? 7 : ahead);
}

/// The output a count belongs to: the only one, or the one whose name
/// shares the most words with [title] (none if it isn't clear).
OutputField? _outputFor(String title, List<OutputField> outputs) {
  if (outputs.isEmpty) return null;
  if (outputs.length == 1) return outputs.single;
  final words = {
    for (final w in title.split(RegExp(r'\s+')))
      if (_stem(w).length >= 3) _stem(w),
  };
  OutputField? best;
  var bestScore = 0;
  var tie = false;
  for (final o in outputs) {
    final score = o.label
        .split(RegExp(r'\s+'))
        .map(_stem)
        .where((w) => w.length >= 3 && words.contains(w))
        .length;
    if (score > bestScore) {
      best = o;
      bestScore = score;
      tie = false;
    } else if (score == bestScore && score > 0) {
      tie = true;
    }
  }
  return tie ? null : best;
}

QuickEntry parseQuickEntry(
  String text, {
  required DateTime today,
  Department? department,
}) {
  final plain = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  final words = plain.isEmpty ? <String>[] : plain.split(' ');
  var done = false;
  TaskUrgency? urgency;
  DateTime? due;
  int? count;

  // "Done: …" at the start.
  if (words.length > 1 && _doneWords.contains(_plain(words.first))) {
    done = true;
    words.removeAt(0);
  }
  while (words.length > 1) {
    final w = _plain(words.last);
    if (!done && _doneWords.contains(w)) {
      done = true;
    } else if (urgency == null && _urgencyWords.containsKey(w)) {
      urgency = _urgencyWords[w];
    } else if (due == null && _dayFor(w, today) != null) {
      due = _dayFor(w, today);
      words.removeLast();
      if (words.length > 1 && _dueLinks.contains(_plain(words.last))) {
        words.removeLast();
      }
      continue;
    } else if (count == null && RegExp(r'^\d{1,5}$').hasMatch(w)) {
      count = int.parse(w);
    } else {
      break;
    }
    words.removeLast();
  }
  var title = words.join(' ').replaceAll(RegExp(r'[\s,;:–-]+$'), '');
  final outputs = <String, int>{};
  if (count != null) {
    final o = _outputFor(title, department?.outputs ?? const []);
    if (o != null && count > 0) {
      outputs[o.key] = count;
    } else {
      // Not a count we can place: it stays part of the title.
      title = '$title $count';
    }
  }
  if (title.trim().isEmpty) return QuickEntry(title: plain);
  return QuickEntry(
    title: title,
    done: done,
    urgency: urgency,
    due: done ? null : due,
    outputs: outputs,
  );
}
