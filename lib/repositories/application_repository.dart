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
    this.updatedAt,
  });

  final int id;

  /// When this application last changed (in an upload or a sync).
  final DateTime? updatedAt;

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

  /// The to-do lines that start with a date ("03/11/2026- Student to pay
  /// fee"), day first as the team writes them: what was noted when.
  List<(DateTime, String)> get datedNotes {
    final out = <(DateTime, String)>[];
    for (final line in todo.split('\n')) {
      final m = RegExp(
        r'^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\s*[-:–]?\s*(.*)$',
      ).firstMatch(line);
      if (m == null) continue;
      final d = int.parse(m[1]!), mo = int.parse(m[2]!);
      var y = int.parse(m[3]!);
      if (y < 100) y += 2000;
      if (mo < 1 || mo > 12 || d < 1 || d > 31) continue;
      final t = DateTime(y, mo, d);
      if (t.month != mo) continue;
      out.add((t, m[4]!.trim()));
    }
    return out;
  }

  /// Days an offer letter has been awaited (counted from the application
  /// date), or null when it isn't awaited: there's an offer date, the
  /// application isn't submitted yet (no date), it's no longer in progress,
  /// or its status is past the offer stage (fees, GTE, COE, CAS, visa…).
  int? offerWaitDays(DateTime today) {
    if (offerDate != null || appDate == null || !inProgress) return null;
    if (ApplicationRepository.isPastOffer(status)) return null;
    final t = DateTime(today.year, today.month, today.day);
    final days = t.difference(appDate!).inDays;
    return days < 0 ? 0 : days;
  }

  /// An offer letter awaited longer than [ApplicationRepository.offerReminderDays].
  bool offerOverdue(DateTime today) =>
      (offerWaitDays(today) ?? 0) > ApplicationRepository.offerReminderDays;

  /// Every date written in the to-do list and the follow-up update, wherever
  /// it sits in the line ("03/11/2026- Paid", "Called 5/11/26", "Paid on
  /// 4-11-2026"), day first as the team writes them, with the line it's on.
  /// The follow-up's lines come second in each pair: (date, line, followUp).
  List<(DateTime, String, bool)> get noteDates => [
    for (final line in todo.split('\n'))
      for (final d in datesIn(line)) (d, line.trim(), false),
    for (final line in followUp.split('\n'))
      for (final d in datesIn(line)) (d, line.trim(), true),
  ];

  static final _anyDate = RegExp(
    // Not inside a longer run of numbers ("1/2/3/4"); a dash or full stop
    // right after the date is fine ("03/11/2026- Paid").
    r'(?<!\d|\d[/.-])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?!\d|[/.-]\d)',
  );

  /// The real calendar dates in [text], day first.
  static List<DateTime> datesIn(String text) => [
    for (final m in _anyDate.allMatches(text))
      ?_calendarDate(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
  ];

  static DateTime? _calendarDate(int d, int mo, int y) {
    if (y < 100) y += 2000;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final t = DateTime(y, mo, d);
    return t.month == mo ? t : null;
  }

  /// The newest milestone date reached (documents, applied, offer, COE).
  DateTime? get lastStep => [coeDate, offerDate, appDate, docDate]
      .whereType<DateTime>()
      .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

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
    updatedAt: r['updated_at'] is String
        ? DateTime.tryParse(r['updated_at']! as String)
        : null,
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

  /// After this many days without an offer letter, a reminder shows.
  static const offerReminderDays = 7;

  /// Statuses that come after the offer letter (so none is awaited).
  static const _pastOfferWords = [
    'offer letter received',
    'sign offer',
    'conditional offer',
    'gte',
    'gsr',
    'payment list',
    'school fees',
    'awaiting coe',
    'coe',
    'cas',
    'visa',
    'gap justification',
    'ielts',
    'blocked account',
  ];

  static bool isPastOffer(String status) {
    final s = status.trim().toLowerCase();
    return _pastOfferWords.any(s.contains);
  }

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
    'coe_date': 'COE / CAS issued',
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

  /// When the tracker first got applications (the oldest upload or sync):
  /// changes are known from then on.
  DateTime? get firstImportAt {
    final r = _db.raw.select(
      'SELECT MIN(imported_at) AS t FROM application_imports;',
    );
    final t = r.isEmpty ? null : r.first['t'] as String?;
    return t == null ? null : DateTime.tryParse(t);
  }

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

  /// The newest change to each application, by its key. Only real changes
  /// count: a field that changed, or the application being added.
  Map<String, ApplicationChange> lastChanges() => {
    for (final r in _db.raw.select(
      'SELECT * FROM ('
      '  SELECT *, ROW_NUMBER() OVER ('
      '    PARTITION BY app_key ORDER BY changed_at DESC, id DESC) AS n '
      '  FROM application_changes WHERE field <> \'removed\''
      ') WHERE n = 1;',
    ))
      r['app_key']! as String: ApplicationChange.fromRow(r),
  };

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
  /// Same-name students used to be told apart by their order in the file
  /// ("jane doe", "jane doe #2"); now by institution and country. A stored
  /// application under an old key that matches an incoming one on name,
  /// institution and country takes the new key — with its history — so the
  /// first upload after the change shows no false "removed" and "added".
  void _carryOverKeys(List<ApplicationCsvRow> rows) {
    final stored = all();
    final storedKeys = {for (final a in stored) a.key};
    final incomingKeys = {for (final r in rows) r.key};
    final taken = <String>{};
    for (final row in rows) {
      if (storedKeys.contains(row.key)) continue;
      final rto = (row.fields[0] ?? '').toLowerCase();
      final country = (row.fields[1] ?? '').toLowerCase();
      final match = stored
          .where(
            (a) =>
                !incomingKeys.contains(a.key) &&
                !taken.contains(a.key) &&
                a.student.toLowerCase() == row.student.toLowerCase() &&
                a.rto.toLowerCase() == rto &&
                a.country.toLowerCase() == country,
          )
          .firstOrNull;
      if (match == null) continue;
      taken.add(match.key);
      _db.transaction(() {
        _db.raw.execute(
          'UPDATE applications SET app_key = ? WHERE app_key = ?;',
          [row.key, match.key],
        );
        _db.raw.execute(
          'UPDATE application_changes SET app_key = ? WHERE app_key = ?;',
          [row.key, match.key],
        );
      });
    }
  }

  ApplicationImportResult importCsv(String text, {String fileName = ''}) {
    final rows = parseApplicationsCsv(text);
    final now = DateTime.now().toIso8601String();
    _carryOverKeys(rows);
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
        // A column missing from this file keeps what's there.
        final next = [
          for (final (j, v) in row.fields.indexed) row.present[j] ? v : old[j],
        ];
        final diffs = <String>[];
        for (final (j, field) in _fields.indexed) {
          if ((old[j] ?? '') != (next[j] ?? '')) diffs.add(field);
        }
        if (diffs.isNotEmpty || before.position != i) {
          _db.raw.execute(
            'UPDATE applications SET student = ?, rto = ?, country = ?, '
            'doc_date = ?, app_date = ?, offer_date = ?, coe_date = ?, '
            'status = ?, assignee = ?, todo = ?, follow_up = ?, position = ?'
            '${diffs.isEmpty ? '' : ', updated_at = ?'} WHERE id = ?;',
            [row.student, ...next, i, if (diffs.isNotEmpty) now, before.id],
          );
        }
        if (diffs.isNotEmpty) {
          changed++;
          for (final f in diffs) {
            final j = _fields.indexOf(f);
            changes.add([row.key, row.student, f, old[j] ?? '', next[j] ?? '']);
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
    // Columns are found by what they mean, not their exact wording, so a
    // rename in Airtable ("COE issue date" to "COE /CAS issue date") keeps
    // working. Linked "… Tracker" columns are never mistaken for them.
    final header = [
      for (final h in table.first)
        h.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), ''),
    ];
    int col(bool Function(String h) matches) {
      for (final (i, h) in header.indexed) {
        if (h.contains('tracker')) continue;
        if (matches(h)) return i;
      }
      return -1;
    }

    final student = col((h) => h.contains('student') || h == 'name');
    final status = col((h) => h.startsWith('status'));
    if (student < 0 || status < 0) {
      throw ApplicationCsvException(
        'This doesn’t look like the Applications Tracker export: it needs '
        '"Student name" and "Status" columns.',
      );
    }
    final rto = col(
      (h) =>
          h.startsWith('rto') ||
          h.contains('school') ||
          h.contains('institution'),
    );
    final country = col((h) => h.contains('country'));
    final doc = col((h) => h.startsWith('doc'));
    final app = col((h) => h.startsWith('app') && h.contains('submit'));
    final offer = col((h) => h.contains('offer'));
    final coe = col((h) => h.contains('coe') || h.startsWith('cas'));
    final assignee = col((h) => h.contains('assign'));
    final todo = col((h) => h.contains('todo'));
    final follow = col((h) => h.contains('follow'));
    // In the same order as ApplicationCsvRow.fields.
    final present = [
      for (final c in [
        rto,
        country,
        doc,
        app,
        offer,
        coe,
        status,
        assignee,
        todo,
        follow,
      ])
        c >= 0,
    ];

    String at(List<String> r, int i) => i < 0 || i >= r.length ? '' : r[i];
    final out = <ApplicationCsvRow>[];
    // How each application is recognised from one upload to the next. A
    // name on its own (as always) when it's the only one; two students with
    // the same name are told apart by institution and country, so sorting
    // the Airtable view differently can't swap their histories. Only when
    // those match too does the order in the file decide.
    final rows = [
      for (final r in table.skip(1))
        if (_clean(at(r, student)).isNotEmpty) r,
    ];
    String whereOf(List<String> r) => [
      _clean(at(r, rto)),
      _clean(at(r, country)),
    ].where((t) => t.isNotEmpty).join(' · ').toLowerCase();
    // For each name: the different institution/country pairs it has.
    final wheres = <String, Set<String>>{};
    for (final r in rows) {
      final base = _clean(at(r, student)).toLowerCase();
      wheres.putIfAbsent(base, () => {}).add(whereOf(r));
    }
    final used = <String, int>{};
    for (final r in rows) {
      final name = _clean(at(r, student));
      final base = name.toLowerCase();
      // Same-name students who can be told apart get their institution and
      // country in the key; those who can't keep the keys they always had
      // ("jane doe", "jane doe #2"), so their history carries on.
      final where = whereOf(r);
      final key = wheres[base]!.length > 1 && where.isNotEmpty
          ? '$base · $where'
          : base;
      final n = (used[key] ?? 0) + 1;
      used[key] = n;
      out.add(
        ApplicationCsvRow(
          key: n == 1 ? key : '$key #$n',
          student: name,
          present: present,
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
    this.present = const [
      true,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
    ],
  });

  /// Which of [fields] the file has a column for. A missing column says
  /// nothing about the data, so it never clears what's already there.
  final List<bool> present;

  final String key;
  final String student;

  /// rto, country, doc_date, app_date, offer_date, coe_date, status,
  /// assignee, todo, follow_up.
  final List<String?> fields;

  String get status => fields[6] ?? '';

  /// For the INSERT: student, then [fields].
  List<Object?> get values => [student, ...fields];
}

/// The latest sign that someone worked on an application, and what it was.
class ApplicationActivity {
  const ApplicationActivity(this.day, this.what);

  /// The day it happened (no time).
  final DateTime day;

  /// What happened, in words: "Status changed to Visa lodged",
  /// "Follow-up: Called the school", "Offer letter received".
  final String what;

  /// Applications with no change for this many days or more are flagged.
  static const staleDays = 14;

  static DateTime _d(DateTime t) => DateTime(t.year, t.month, t.day);

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// The newest of: a step date (documents, application, offer, COE); a
  /// date written in the to-do list or follow-up; and [change], the last
  /// change a sync saw; and when it came into the tracker (nothing before
  /// that is known). Dates after [today]
  /// (appointments, deadlines) aren't work done, so they're left out.
  static ApplicationActivity? of(
    Application a,
    DateTime today, {
    ApplicationChange? change,
  }) {
    final t = _d(today);
    final found = <ApplicationActivity>[];
    void add(DateTime? at, String what) {
      if (at == null) return;
      final d = _d(at);
      if (!d.isAfter(t)) found.add(ApplicationActivity(d, what));
    }

    // A recorded change says the most, so it's listed first and wins ties.
    if (change != null) add(change.at, describe(change));
    for (final (d, line, follow) in a.noteDates) {
      add(d, '${follow ? 'Follow-up' : 'To do'}: ${_oneLine(line)}');
    }
    add(a.coeDate, 'COE / CAS issued');
    add(a.offerDate, 'Offer letter received');
    add(a.appDate, 'Application submitted');
    add(a.docDate, 'Documents submitted');
    // Last, so anything more telling on the same day wins: nothing is known
    // from before an application came into the tracker, so it's never
    // counted as waiting longer than that.
    add(a.updatedAt, 'No change since it came into the tracker');
    if (found.isEmpty) return null;
    return found.reduce((x, y) => y.day.isAfter(x.day) ? y : x);
  }

  /// A change in words.
  static String describe(ApplicationChange c) {
    final label = ApplicationRepository.fieldLabels[c.field] ?? c.field;
    final value = _oneLine(c.newValue);
    return switch (c.field) {
      'added' => 'Added in Airtable',
      'status' => 'Status changed to $value',
      'assignee' => value.isEmpty ? 'Assignee removed' : 'Assigned to $value',
      'todo' || 'follow_up' =>
        value.isEmpty ? '$label cleared' : '$label updated: $value',
      'doc_date' ||
      'app_date' ||
      'offer_date' ||
      'coe_date' => value.isEmpty ? '$label date cleared' : '$label date set',
      _ => value.isEmpty ? '$label cleared' : '$label changed to $value',
    };
  }
}
