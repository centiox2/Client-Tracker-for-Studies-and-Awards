import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../database/database.dart';
import '../models/staff.dart';
import '../repositories/client_count_repository.dart';
import '../repositories/staff_repository.dart';
import '../repositories/time_off_repository.dart';
import '../repositories/week_repository.dart';

/// Reads weeks from Excel workbooks in the original spreadsheet layout (the
/// same one "Export this week to Excel" writes): a section per weekday
/// headed "Monday  05/10/2026", a Staff / New / Existing table, and a Total
/// row. Any number of sheets and weeks per file; a "Week of …" title lets
/// sections without a date be placed by their weekday.

/// One staff member's numbers on an imported day.
class ImportEntry {
  const ImportEntry({
    required this.newClients,
    required this.existingClients,
    this.off = false,
  });

  final int newClients;
  final int existingClients;

  /// The sheet says "Off" for this person.
  final bool off;

  int get total => newClients + existingClients;
}

class ImportDay {
  ImportDay(this.date);

  final DateTime date;

  /// Staff name as written in the sheet → numbers.
  final Map<String, ImportEntry> entries = {};

  int get total => entries.values.fold(0, (a, e) => a + (e.off ? 0 : e.total));
}

class ExcelImport {
  ExcelImport({required this.days, required this.warnings});

  /// Oldest first, one per date.
  final List<ImportDay> days;

  /// Sections that couldn't be read, and why.
  final List<String> warnings;

  /// Every staff name in the file, in first-seen order.
  List<String> get names {
    final seen = <String>{};
    for (final d in days) {
      seen.addAll(d.entries.keys);
    }
    return seen.toList();
  }

  int get total => days.fold(0, (a, d) => a + d.total);

  int get weeks =>
      days.map((d) => WeekRepository.mondayOf(d.date)).toSet().length;
}

/// Thrown when the file can't be read as a workbook at all.
class ExcelImportException implements Exception {
  ExcelImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _weekdays = {
  'monday': 1,
  'mon': 1,
  'tuesday': 2,
  'tue': 2,
  'tues': 2,
  'wednesday': 3,
  'wed': 3,
  'thursday': 4,
  'thu': 4,
  'thur': 4,
  'thurs': 4,
  'friday': 5,
  'fri': 5,
  'saturday': 6,
  'sat': 6,
  'sunday': 7,
  'sun': 7,
};

final _dmy = RegExp(r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b');
final _ymd = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');

ExcelImport parseExcelImport(List<int> bytes) {
  final Excel book;
  try {
    book = Excel.decodeBytes(bytes);
  } catch (e) {
    throw ExcelImportException(
      'This file couldn’t be read as an Excel workbook. Old .xls files need '
      'to be saved as .xlsx in Excel first.',
    );
  }

  final byDate = <DateTime, ImportDay>{};
  final warnings = <String>[];

  for (final MapEntry(key: sheetName, value: sheet) in book.tables.entries) {
    DateTime? weekMonday;
    ImportDay? current;
    var newCol = -1;
    var existingCol = -1;

    for (final row in sheet.rows) {
      final texts = [for (final c in row) _text(c)];
      final first = texts.indexWhere((t) => t.isNotEmpty);
      if (first < 0) continue;
      final head = texts[first];
      final lower = head.toLowerCase();

      // "Week of October 5, 2026" — places sections that have no date.
      final weekOf = RegExp(
        r'week of (.+)',
        caseSensitive: false,
      ).firstMatch(texts.join(' '));
      if (weekOf != null) {
        final d = _parseDate(weekOf.group(1)!.trim());
        if (d != null) weekMonday = WeekRepository.mondayOf(d);
        continue;
      }

      // A day heading: a weekday name and/or a date, with no numbers beside
      // it (a staff row has numbers).
      final weekday = _weekdayIn(head);
      final date = _dateIn(row, texts);
      final hasNumbers = [
        for (var i = first + 1; i < row.length; i++) _number(row[i]),
      ].any((n) => n != null);
      if ((weekday != null || date != null) && !hasNumbers) {
        final resolved =
            date ??
            (weekMonday == null || weekday == null || weekday > 5
                ? null
                : weekMonday.add(Duration(days: weekday - 1)));
        current = null;
        newCol = -1;
        existingCol = -1;
        if (resolved == null) {
          warnings.add(
            '“$head” on sheet “$sheetName” has no date, so it was skipped.',
          );
          continue;
        }
        if (resolved.weekday > 5) {
          warnings.add(
            '${DateFormat('EEE d MMM y').format(resolved)} is a weekend day, '
            'so it was skipped.',
          );
          continue;
        }
        current = byDate.putIfAbsent(resolved, () => ImportDay(resolved));
        continue;
      }
      if (current == null) continue;

      // Column headings: find New and Existing.
      if (lower == 'staff' || lower == 'name' || lower == 'staff name') {
        for (var i = first + 1; i < texts.length; i++) {
          final t = texts[i].toLowerCase();
          if (t.startsWith('new')) newCol = i;
          if (t.startsWith('exist')) existingCol = i;
        }
        continue;
      }
      // The day's total ends the section.
      if (lower.startsWith('total') ||
          lower.startsWith('day total') ||
          lower.contains('weekly total')) {
        current = null;
        continue;
      }

      final nCol = newCol >= 0 ? newCol : first + 1;
      final eCol = existingCol >= 0 ? existingCol : first + 2;
      final nText = nCol < texts.length ? texts[nCol].toLowerCase() : '';
      final eText = eCol < texts.length ? texts[eCol].toLowerCase() : '';
      if (nText == 'off' || eText == 'off') {
        current.entries[head] = const ImportEntry(
          newClients: 0,
          existingClients: 0,
          off: true,
        );
        continue;
      }
      final n = nCol < row.length ? _number(row[nCol]) : null;
      final e = eCol < row.length ? _number(row[eCol]) : null;
      if (n == null && e == null) {
        // Blank cells still list the person (0 clients); text is a note.
        if (nText.isEmpty && eText.isEmpty) {
          current.entries[head] = const ImportEntry(
            newClients: 0,
            existingClients: 0,
          );
        }
        continue;
      }
      current.entries[head] = ImportEntry(
        newClients: (n ?? 0).clamp(0, 100000),
        existingClients: (e ?? 0).clamp(0, 100000),
      );
    }
  }

  final days = byDate.values.where((d) => d.entries.isNotEmpty).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return ExcelImport(days: days, warnings: warnings);
}

String _text(Data? cell) {
  final v = cell?.value;
  return switch (v) {
    null => '',
    TextCellValue() => (v.value.text ?? '').trim(),
    IntCellValue() => '${v.value}',
    DoubleCellValue() => '${v.value}',
    DateCellValue() => '${v.day}/${v.month}/${v.year}',
    DateTimeCellValue() => '${v.day}/${v.month}/${v.year}',
    _ => v.toString().trim(),
  };
}

int? _number(Data? cell) {
  final v = cell?.value;
  return switch (v) {
    IntCellValue() => v.value,
    DoubleCellValue() => v.value.round(),
    TextCellValue() => int.tryParse((v.value.text ?? '').trim()),
    FormulaCellValue() => null,
    _ => null,
  };
}

int? _weekdayIn(String text) {
  final word = RegExp(r'^[A-Za-z]+').firstMatch(text.trim())?.group(0);
  return word == null ? null : _weekdays[word.toLowerCase()];
}

DateTime? _dateIn(List<Data?> row, List<String> texts) {
  for (final c in row) {
    final v = c?.value;
    if (v is DateCellValue) return DateTime(v.year, v.month, v.day);
    if (v is DateTimeCellValue) return DateTime(v.year, v.month, v.day);
  }
  for (final t in texts) {
    final d = _parseDate(t);
    if (d != null) return d;
  }
  return null;
}

DateTime? _parseDate(String text) {
  final ymd = _ymd.firstMatch(text);
  if (ymd != null) {
    return _valid(
      int.parse(ymd.group(1)!),
      int.parse(ymd.group(2)!),
      int.parse(ymd.group(3)!),
    );
  }
  final dmy = _dmy.firstMatch(text);
  if (dmy != null) {
    var year = int.parse(dmy.group(3)!);
    if (year < 100) year += 2000;
    return _valid(year, int.parse(dmy.group(2)!), int.parse(dmy.group(1)!));
  }
  for (final f in ['MMMM d, y', 'MMMM d y', 'd MMMM y', 'MMM d, y']) {
    try {
      final d = DateFormat(f).parseLoose(text);
      return DateTime(d.year, d.month, d.day);
    } catch (_) {}
  }
  return null;
}

DateTime? _valid(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  final date = DateTime(y, m, d);
  return date.month == m ? date : null;
}

// ------------------------------------------------------------- applying ----

/// What to do with a name from the file.
sealed class ImportTarget {
  const ImportTarget();
}

/// Their numbers go to this existing staff member.
class MatchStaff extends ImportTarget {
  const MatchStaff(this.staffId);
  final int staffId;
}

/// Add them as a former (inactive) staff member, keeping their history.
class AddFormerStaff extends ImportTarget {
  const AddFormerStaff();
}

/// Leave their numbers out.
class SkipName extends ImportTarget {
  const SkipName();
}

/// The best guess for [name]: the same name (ignoring case and spacing),
/// else the only staff member whose name contains it or is contained by it
/// ("Eve" → "Director/Eve"), else add as former staff.
ImportTarget suggestTarget(String name, List<Staff> staff) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final n = norm(name);
  if (n.isEmpty) return const SkipName();
  for (final s in staff) {
    if (norm(s.name) == n) return MatchStaff(s.id);
  }
  final partial = staff.where((s) {
    final m = norm(s.name);
    return m.isNotEmpty && (m.contains(n) || n.contains(m));
  }).toList();
  if (partial.length == 1) return MatchStaff(partial.first.id);
  return const AddFormerStaff();
}

class ImportOutcome {
  int days = 0;
  int cells = 0;
  int clients = 0;
  int weeksCreated = 0;
  int staffAdded = 0;

  /// Staff-days left as they were because they already had numbers.
  int kept = 0;
}

/// Writes [data] into the database. Weeks that don't exist yet are created.
/// Unless [overwrite], staff-days that already have numbers are left alone.
ImportOutcome applyExcelImport(
  AppDatabase db,
  ExcelImport data,
  Map<String, ImportTarget> targets, {
  required bool overwrite,
}) {
  final weeks = WeekRepository(db);
  final counts = ClientCountRepository(db, weekRepository: weeks);
  final timeOff = TimeOffRepository(db);
  final staffRepo = StaffRepository(db);
  final out = ImportOutcome();

  final ids = <String, int>{};
  for (final MapEntry(key: name, value: target) in targets.entries) {
    switch (target) {
      case MatchStaff(:final staffId):
        ids[name] = staffId;
      case AddFormerStaff():
        ids[name] = staffRepo.add(name, active: false);
        out.staffAdded++;
      case SkipName():
        break;
    }
  }

  for (final day in data.days) {
    var week = weeks.findByDate(day.date);
    if (week == null) {
      week = weeks.createWeekFor(day.date);
      out.weeksCreated++;
    }
    final workDay = weeks
        .getDays(week.id)
        .where(
          (d) =>
              d.date.year == day.date.year &&
              d.date.month == day.date.month &&
              d.date.day == day.date.day,
        )
        .firstOrNull;
    if (workDay == null) continue;
    var touched = false;
    for (final MapEntry(key: name, value: entry) in day.entries.entries) {
      final staffId = ids[name];
      if (staffId == null) continue;
      weeks.addStaffToWeek(week.id, [staffId]);
      final before = counts.countValues(workDay.id, staffId);
      if (!overwrite && before.newClients + before.existingClients > 0) {
        out.kept++;
        continue;
      }
      if (entry.off) {
        timeOff.setDay(dayId: workDay.id, staffId: staffId, off: true);
      } else {
        counts.saveCount(
          dayId: workDay.id,
          staffId: staffId,
          newClients: entry.newClients,
          existingClients: entry.existingClients,
          log: false,
        );
        out.clients += entry.total;
      }
      out.cells++;
      touched = true;
    }
    if (touched) out.days++;
  }
  return out;
}
