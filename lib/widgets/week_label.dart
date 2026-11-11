import 'package:intl/intl.dart';

/// Formats a date range like "September 28 – October 2, 2026".
String weekRangeLabel(DateTime start, DateTime end) {
  final m = DateFormat('MMMM');
  if (start.year == end.year && start.month == end.month) {
    return '${m.format(start)} ${start.day} – ${end.day}, ${end.year}';
  }
  if (start.year == end.year) {
    return '${m.format(start)} ${start.day} – ${m.format(end)} ${end.day}, ${end.year}';
  }
  return '${DateFormat('MMMM d, y').format(start)} – '
      '${DateFormat('MMMM d, y').format(end)}';
}

/// Formats a date as DD/MM/YYYY (the app's canonical display format).
String displayDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// A short range, Clarity style: "9 – 13 Nov 2026", "28 Sep – 2 Oct 2026",
/// "29 Dec 2026 – 2 Jan 2027".
String shortRangeLabel(DateTime start, DateTime end) {
  final m = DateFormat('MMM');
  if (start.year == end.year && start.month == end.month) {
    return '${start.day} – ${end.day} ${m.format(end)} ${end.year}';
  }
  if (start.year == end.year) {
    return '${start.day} ${m.format(start)} – ${end.day} ${m.format(end)} '
        '${end.year}';
  }
  return '${DateFormat('d MMM y').format(start)} – '
      '${DateFormat('d MMM y').format(end)}';
}
