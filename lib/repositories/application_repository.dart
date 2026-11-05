import 'package:intl/intl.dart';

import '../database/database.dart';
import 'revenue_repository.dart';

/// One application from the Airtable "Applications Tracker".
class Application {
  const Application({
    required this.id,
    required this.key,
    required this.student,
    this.rto = '',
    this.country = '',
    this.docDate,
    this.appDate,
    this.offerDate,
    this.coeDate,
    this.status = '',
    this.assignee = '',
    this.todo = '',
    this.followUp = '',
    this.position = 0,
  });

  final int id;

  /// The student's name in lower case (with " #2" for a second application
  /// of the same name): how an application is recognised between uploads.
  final String key;
  final String student;
  final String rto;
  final String country;
  final DateTime? docDate;
  final DateTime? appDate;
  final DateTime? offerDate;
  final DateTime? coeDate;
  final String status;
  final String assignee;
  final String todo;
  final String followUp;

  /// Its row in the uploaded file (Airtable's order).
  final int position;

  /// Still being worked on (not finished, stopped or paused).
  bool get inProgress => ApplicationRepository.isInProgress(status);

  static Application fromRow(Map<String, Object?> r) => Application(
    id: r['id']! as int,
    key: r['app_key']! as String,
    student: r['student']! as String,
    rto: (r['rto'] as String?) ?? '',
    country: (r['country'] as String?) ?? '',
    docDate: _date(r['doc_date']),
    appDate: _date(r['app_date']),
    offerDate: _date(r['offer_date']),
    coeDate: _date(r['coe_date']),
    status: (r['status'] as String?) ?? '',
    assignee: (r['assignee'] as String?) ?? '',
    todo: (r['todo'] as String?) ?? '',
    followUp: (r['follow_up'] as String?) ?? '',
    position: (r['position'] as int?) ?? 0,
  );

  static DateTime? _date(Object? v) =>
      v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
}

/// One upload of the CSV.
class ApplicationImport {
  const ApplicationImport({
    required this.id,
    required this.at,
    required this.fileName,
    required this.total,
    required this.added,
    required this.changed,
    required this.removed,
    required this.device,
  });

  final int id;
  final DateTime at;
  final String fileName;
  final int total;
  final int added;
  final int changed;
  final int removed;
  final String device;

  static ApplicationImport fromRow(Map<String, Object?> r) => ApplicationImport(
    id: r['id']! as int,
    at: DateTime.parse(r['imported_at']! as String),
    fileName: (r['file_name'] as String?) ?? '',
    total: (r['total'] as int?) ?? 0,
    added: (r['added'] as int?) ?? 0,
    changed: (r['changed'] as int?) ?? 0,
    removed: (r['removed'] as int?) ?? 0,
    device: (r['device'] as String?) ?? '',
  );
}

/// One thing that changed for one application in an upload.
class ApplicationChange {
  const ApplicationChange({
    required this.id,
    required this.importId,
    required this.key,
    required this.student,
    required this.field,
    required this.oldValue,
    required this.newValue,
    required this.at,
  });

  final int id;
  final int importId;
  final String key;
  final String student;

  /// 'added', 'removed', or a field: status, rto, country, assignee,
  /// doc_date, app_date, offer_date, coe_date, todo, follow_up.
  final String field;
  final String oldValue;
  final String newValue;
  final DateTime at;

  static ApplicationChange fromRow(Map<String, Object?> r) => ApplicationChange(
    id: r['id']! as int,
    importId: r['import_id']! as int,
    key: r['app_key']! as String,
    student: r['student']! as String,
    field: r['field']! as String,
    oldValue: (r['old_value'] as String?) ?? '',
    newValue: (r['new_value'] as String?) ?? '',
    at: DateTime.parse(r['changed_at']! as String),
  );
}

/// What an upload did.
class ApplicationImportResult {
  const ApplicationImportResult({
    required this.total,
    required this.added,
    required this.changed,
    required this.removed,
    required this.first,
  });

  final int total;
  final int added;
  final int changed;
  final int removed;

  /// The very first upload (everything is new; no changes listed).
  final bool first;
}

/// The CSV couldn't be used.
class ApplicationCsvException implements Exception {
  ApplicationCsvException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Applications: loaded from the Airtable CSV export, compared with the
/// previous upload so the boss sees what moved.
class ApplicationRepository {
  ApplicationRepository(this._db);

  final AppDatabase _db;

  /// Statuses in the order Airtable groups them (anything else after).
  static const statusOrder = [
    'Compliance and Verification ongoing',
    'Statement building',
    'Pending School allocation',
    'Application to be submitted',
    'Awaiting offer letter',
    'To submit GTE documents',
    'Awaiting GTE outcome',
    'To pay school fees',
    'To deposit blocked account',
    'CAS received',
    'COE ISSUED/DONE',
    'on hold',
    'Drop out',
    'Withdrawn',
    'Refunded',
  ];

  /// Finished, stopped or paused: not "in progress".
  static const _notInProgress = {
    'coe issued/done',
    'on hold',
    'drop out',
    'withdrawn',
    'refunded',
  };

  static bool isInProgress(String status) =>
      status.trim().isNotEmpty &&
      !_notInProgress.contains(status.trim().toLowerCase());

  static bool isDone(String status) =>
      status.trim().toLowerCase() == 'coe issued/done';

  /// Where [status] sits in [statusOrder] (unknown ones last).
  static int statusRank(String status) {
    final s = status.trim().toLowerCase();
    final i = statusOrder.indexWhere((o) => o.toLowerCase() == s);
    return i < 0 ? statusOrder.length : i;
  }

  /// The fields compared between uploads, with how they read.
  static const fieldLabels = {
    'status': 'Status',
    'rto': 'RTO',
    'country': 'Country',
    'assignee': 'Assignee',
    'doc_date': 'Documents submitted',
    'app_date': 'Application submitted',
    'offer_date': 'Offer letter received',
    'coe_date': 'COE issued',
    'todo': 'To do',
    'follow_up': 'Follow-up',
  };

  // ---- Reading -------------------------------------------------------------

  List<Application> all() => [
    for (final r in _db.raw.select(
      'SELECT * FROM applications ORDER BY position, id;',
    ))
      Application.fromRow(r),
  ];

  bool get isEmpty =>
      _db.raw.select('SELECT 1 FROM applications LIMIT 1;').isEmpty;

  /// Uploads, newest first.
  List<ApplicationImport> imports({int limit = 50}) => [
    for (final r in _db.raw.select(
      'SELECT * FROM application_imports ORDER BY imported_at DESC, id DESC '
      'LIMIT ?;',
      [limit],
    ))
      ApplicationImport.fromRow(r),
  ];

  ApplicationImport? get latestImport => imports(limit: 1).firstOrNull;

  /// What changed in one upload.
  List<ApplicationChange> changesFor(int importId) => [
    for (final r in _db.raw.select(
      'SELECT * FROM application_changes WHERE import_id = ? ORDER BY id;',
      [importId],
    ))
      ApplicationChange.fromRow(r),
  ];

  /// The latest changes across uploads, newest first.
  List<ApplicationChange> recentChanges({int limit = 200}) => [
    for (final r in _db.raw.select(
      'SELECT * FROM application_changes ORDER BY changed_at DESC, id DESC '
      'LIMIT ?;',
      [limit],
    ))
      ApplicationChange.fromRow(r),
  ];

  /// Every change to one application, newest first.
  List<ApplicationChange> historyOf(String key) => [
    for (final r in _db.raw.select(
      'SELECT * FROM application_changes WHERE app_key = ? '
      'ORDER BY changed_at DESC, id DESC;',
      [key],
    ))
      ApplicationChange.fromRow(r),
  ];

  // ---- Uploading -------------------------------------------------------------

  /// Loads the Airtable CSV export [text]: new applications are added,
  /// changed ones updated (each change noted), and ones no longer in the
  /// file removed. The first upload notes no changes (all of it is new).
  ApplicationImportResult importCsv(String text, {String fileName = ''}) {
    final rows = parseApplicationsCsv(text);
    final now = DateTime.now().toIso8601String();
    final existing = {for (final a in all()) a.key: a};
    final first = existing.isEmpty && latestImport == null;
    var added = 0, changed = 0, removed = 0;
    final seen = <String>{};
    final changes = <List<Object?>>[];

    _db.transaction(() {
      for (final (i, row) in rows.indexed) {
        seen.add(row.key);
        final before = existing[row.key];
        if (before == null) {
          _db.raw.execute(
            'INSERT INTO applications (id, app_key, student, rto, country, '
            'doc_date, app_date, offer_date, coe_date, status, assignee, todo, '
            'follow_up, position, updated_at) '
            'VALUES (new_id(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
            [row.key, ...row.values, i, now],
          );
          added++;
          if (!first) {
            changes.add([row.key, row.student, 'added', '', row.status]);
          }
          continue;
        }
        final old = _valuesOf(before);
        final diffs = <String>[];
        for (final (j, field) in _fields.indexed) {
          if ((old[j] ?? '') != (row.fields[j] ?? '')) diffs.add(field);
        }
        if (diffs.isNotEmpty || before.position != i) {
          _db.raw.execute(
            'UPDATE applications SET student = ?, rto = ?, country = ?, '
            'doc_date = ?, app_date = ?, offer_date = ?, coe_date = ?, '
            'status = ?, assignee = ?, todo = ?, follow_up = ?, position = ?'
            '${diffs.isEmpty ? '' : ', updated_at = ?'} WHERE id = ?;',
            [
              row.student,
              ...row.fields,
              i,
              if (diffs.isNotEmpty) now,
              before.id,
            ],
          );
        }
        if (diffs.isNotEmpty) {
          changed++;
          for (final f in diffs) {
            final j = _fields.indexOf(f);
            changes.add([
              row.key,
              row.student,
              f,
              old[j] ?? '',
              row.fields[j] ?? '',
            ]);
          }
        }
      }
      for (final a in existing.values) {
        if (seen.contains(a.key)) continue;
        _db.raw.execute('DELETE FROM applications WHERE id = ?;', [a.id]);
        removed++;
        changes.add([a.key, a.student, 'removed', a.status, '']);
      }
      _db.raw.execute(
        'INSERT INTO application_imports (id, imported_at, file_name, total, '
        'added, changed, removed, device) '
        'VALUES (new_id(), ?, ?, ?, ?, ?, ?, ?);',
        [
          now,
          fileName,
          rows.length,
          added,
          changed,
          removed,
          RevenueRepository.deviceLabel,
        ],
      );
      final importId =
          _db.raw.select('SELECT last_insert_rowid() AS id;').first['id']!
              as int;
      for (final c in changes) {
        _db.raw.execute(
          'INSERT INTO application_changes (id, import_id, app_key, student, '
          'field, old_value, new_value, changed_at) '
          'VALUES (new_id(), ?, ?, ?, ?, ?, ?, ?);',
          [importId, ...c, now],
        );
      }
    });
    return ApplicationImportResult(
      total: rows.length,
      added: added,
      changed: changed,
      removed: removed,
      first: first,
    );
  }

  static const _fields = [
    'rto',
    'country',
    'doc_date',
    'app_date',
    'offer_date',
    'coe_date',
    'status',
    'assignee',
    'todo',
    'follow_up',
  ];

  static List<String?> _valuesOf(Application a) => [
    a.rto,
    a.country,
    _iso(a.docDate),
    _iso(a.appDate),
    _iso(a.offerDate),
    _iso(a.coeDate),
    a.status,
    a.assignee,
    a.todo,
    a.followUp,
  ];

  static String? _iso(DateTime? d) =>
      d == null ? null : DateFormat('yyyy-MM-dd').format(d);

  // ---- The CSV -------------------------------------------------------------

  /// Reads the Airtable export: one row per application, matched to its
  /// columns by name (so moving columns around in Airtable doesn't matter).
  static List<ApplicationCsvRow> parseApplicationsCsv(String text) {
    final table = parseCsv(text);
    if (table.isEmpty) throw ApplicationCsvException('The file is empty.');
    final header = [for (final h in table.first) h.trim().toLowerCase()];
    int col(List<String> names) {
      for (final n in names) {
        final i = header.indexOf(n);
        if (i >= 0) return i;
      }
      return -1;
    }

    final student = col(['student name', 'student', 'name']);
    final status = col(['status']);
    if (student < 0 || status < 0) {
      throw ApplicationCsvException(
        'This doesn’t look like the Applications Tracker export: it needs '
        '"Student name" and "Status" columns.',
      );
    }
    final rto = col(['rto name', 'rto', 'school']);
    final country = col(['country']);
    final doc = col(['doc submit date', 'documents submitted']);
    final app = col(['app submitted date', 'application submitted date']);
    final offer = col(['offer letter received date', 'offer letter date']);
    final coe = col(['coe issue date', 'coe issued date']);
    final assignee = col(['assignee']);
    final todo = col(['to do list', 'to do', 'todo']);
    final follow = col(['follow up update', 'follow up']);

    String at(List<String> r, int i) => i < 0 || i >= r.length ? '' : r[i];
    final out = <ApplicationCsvRow>[];
    final counts = <String, int>{};
    for (final r in table.skip(1)) {
      final name = _clean(at(r, student));
      if (name.isEmpty) continue;
      final base = name.toLowerCase();
      final n = (counts[base] ?? 0) + 1;
      counts[base] = n;
      out.add(
        ApplicationCsvRow(
          key: n == 1 ? base : '$base #$n',
          student: name,
          fields: [
            _clean(at(r, rto)),
            _clean(at(r, country)),
            parseDate(at(r, doc)),
            parseDate(at(r, app)),
            parseDate(at(r, offer)),
            parseDate(at(r, coe)),
            _clean(at(r, status)),
            _clean(at(r, assignee)),
            at(r, todo).trim(),
            at(r, follow).trim(),
          ],
        ),
      );
    }
    if (out.isEmpty) {
      throw ApplicationCsvException('No applications found in the file.');
    }
    return out;
  }

  static String _clean(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// "February 2, 2024" (Airtable's export), "2024-02-02", or "2/2/2024"
  /// (day first, as in Kenya) → "2024-02-02"; null when empty or unreadable.
  static String? parseDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    for (final f in ['MMMM d, y', 'MMM d, y', 'd MMMM y', 'd MMM y']) {
      try {
        return DateFormat('yyyy-MM-dd').format(DateFormat(f).parseStrict(s));
      } catch (_) {}
    }
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
    final dmy = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})').firstMatch(s);
    int? y, m, d;
    if (iso != null) {
      y = int.parse(iso[1]!);
      m = int.parse(iso[2]!);
      d = int.parse(iso[3]!);
    } else if (dmy != null) {
      d = int.parse(dmy[1]!);
      m = int.parse(dmy[2]!);
      y = int.parse(dmy[3]!);
    }
    if (y == null || m! < 1 || m > 12 || d! < 1 || d > 31) return null;
    final t = DateTime(y, m, d);
    return t.month == m ? DateFormat('yyyy-MM-dd').format(t) : null;
  }

  /// CSV as written by Airtable (and Excel): commas, quoted fields that may
  /// hold commas, quotes ("") and line breaks.
  static List<List<String>> parseCsv(String text) {
    var s = text;
    if (s.startsWith('﻿')) s = s.substring(1);
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < s.length && s[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
        row.add(field.toString());
        field.clear();
        if (row.any((f) => f.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.write(c);
      }
    }
    row.add(field.toString());
    if (row.any((f) => f.isNotEmpty)) rows.add(row);
    return rows;
  }
}

/// One application as read from the CSV.
class ApplicationCsvRow {
  const ApplicationCsvRow({
    required this.key,
    required this.student,
    required this.fields,
  });

  final String key;
  final String student;

  /// rto, country, doc_date, app_date, offer_date, coe_date, status,
  /// assignee, todo, follow_up.
  final List<String?> fields;

  String get status => fields[6] ?? '';

  /// For the INSERT: student, then [fields].
  List<Object?> get values => [student, ...fields];
}
