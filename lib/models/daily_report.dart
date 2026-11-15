/// Daily reports, as tasks.
///
/// Every entry is a task that belongs to one person. It sits on their to-do
/// list (to do / doing / blocked) until it's done. When it's done it is
/// submitted, and the server dates it with the day it was submitted. A
/// reviewer (whoever assigned it, a department head or a manager) then
/// approves it or returns it with a comment.
///
/// Kept only in the online database (never copied to every device).
library;

import 'package:flutter/material.dart';

/// Where the work is.
enum ReportStatus {
  toDo('to_do', 'To do', Icons.radio_button_unchecked),
  inProgress('in_progress', 'Doing', Icons.timelapse),
  blocked('blocked', 'Blocked', Icons.block),
  done('done', 'Done', Icons.check_circle);

  const ReportStatus(this.code, this.label, this.icon);
  final String code;
  final String label;
  final IconData icon;

  bool get isOpen => this != done;

  /// The statuses a person picks while working (Done goes through Submit).
  static const working = [toDo, inProgress, blocked];

  static ReportStatus fromCode(String? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => toDo);
}

/// How urgent a task is: the colour on its card.
enum TaskUrgency {
  low('low', 'Low'),
  normal('normal', 'Normal'),
  high('high', 'High'),
  urgent('urgent', 'Urgent');

  const TaskUrgency(this.code, this.label);
  final String code;
  final String label;

  /// Grey, blue, orange, red — the same in light and dark.
  Color color(Brightness b) => switch (this) {
    low =>
      b == Brightness.dark ? const Color(0xFF9AA3AF) : const Color(0xFF6B7280),
    normal =>
      b == Brightness.dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
    high =>
      b == Brightness.dark ? const Color(0xFFFB923C) : const Color(0xFFEA580C),
    urgent =>
      b == Brightness.dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
  };

  static TaskUrgency fromCode(String? code) =>
      values.firstWhere((u) => u.code == code, orElse: () => normal);
}

/// Where a task is in review.
enum ReviewState {
  none('none', 'Not submitted'),
  submitted('submitted', 'Waiting for review'),
  approved('approved', 'Approved'),
  returned('returned', 'Returned');

  const ReviewState(this.code, this.label);
  final String code;
  final String label;

  static ReviewState fromCode(String? code) =>
      values.firstWhere((r) => r.code == code, orElse: () => none);
}

/// What a person may see: their own reports, their department's, or all.
enum ReportScope {
  own,
  department,
  all;

  static ReportScope fromCode(String? code) => switch (code) {
    'all' => all,
    'department' => department,
    _ => own,
  };
}

/// Report access an admin gives each account.
enum ReportAccess {
  employee('employee', 'Employee', 'Records and sees their own tasks'),
  head(
    'head',
    'Department head',
    'Also sees, assigns and reviews tasks in their department',
  ),
  manager(
    'manager',
    'Operations manager',
    'Sees, assigns and reviews every department’s tasks, with exports',
  );

  const ReportAccess(this.code, this.label, this.summary);
  final String code;
  final String label;
  final String summary;

  static ReportAccess fromCode(String? code) =>
      values.firstWhere((a) => a.code == code, orElse: () => employee);
}

/// One measurable output a department records ("Applications submitted").
class OutputField {
  const OutputField(this.key, this.label);

  final String key;
  final String label;

  factory OutputField.fromJson(Map<String, Object?> json) =>
      OutputField(json['key'] as String, json['label'] as String);

  Map<String, Object?> toJson() => {'key': key, 'label': label};

  /// A key from a label: "COEs issued" → "coes_issued".
  static String keyFor(String label) {
    final key = label
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final short = key.length > 40 ? key.substring(0, 40) : key;
    return short.isEmpty ? 'output' : short;
  }
}

class Department {
  const Department({
    required this.id,
    required this.name,
    this.outputs = const [],
    this.active = true,
    this.position = 0,
  });

  final int id;
  final String name;
  final List<OutputField> outputs;
  final bool active;
  final int position;

  factory Department.fromJson(Map<String, Object?> json) => Department(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    outputs: [
      for (final o in (json['outputs'] as List? ?? const []))
        OutputField.fromJson((o as Map).cast<String, Object?>()),
    ],
    active: json['active'] as bool? ?? true,
    position: (json['position'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'outputs': [for (final o in outputs) o.toJson()],
    'active': active,
    'position': position,
  };

  String outputLabel(String key) =>
      outputs.where((o) => o.key == key).firstOrNull?.label ??
      key.replaceAll('_', ' ');
}

DateTime? _date(Object? v) =>
    v == null || '$v'.isEmpty ? null : DateTime.tryParse('$v');

/// A calendar day from the server ("2026-11-15"), as a local date.
DateTime? _day(Object? v) {
  final d = _date(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

const _unset = Object();

class ActivityReport {
  const ActivityReport({
    this.id,
    this.userId,
    this.userName = '',
    this.departmentId,
    this.departmentName = '',
    this.date,
    required this.description,
    this.details = '',
    this.reference = '',
    this.outputs = const {},
    this.status = ReportStatus.toDo,
    this.blocker = '',
    this.urgency = TaskUrgency.normal,
    this.dueDate,
    this.createdAt,
    this.updatedAt,
    this.submittedAt,
    this.assignedBy,
    this.assignedByName = '',
    this.review = ReviewState.none,
    this.reviewedBy,
    this.reviewedByName = '',
    this.reviewedAt,
    this.commentCount = 0,
    this.lastReviewNote = '',
  });

  final int? id;
  final int? userId;
  final String userName;
  final int? departmentId;
  final String departmentName;

  /// The day it was submitted for (set by the server on submit, Kenya
  /// time). Null until then.
  final DateTime? date;

  /// The task's title: what needs doing, or what was done.
  final String description;

  /// What the person did, in their words (written when they submit).
  final String details;
  final String reference;
  final Map<String, int> outputs;
  final ReportStatus status;
  final String blocker;
  final TaskUrgency urgency;
  final DateTime? dueDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// When it was submitted (this device's time zone).
  final DateTime? submittedAt;

  /// Who gave this task to the person; null when they added it themselves.
  final int? assignedBy;
  final String assignedByName;
  final ReviewState review;
  final int? reviewedBy;
  final String reviewedByName;
  final DateTime? reviewedAt;
  final int commentCount;

  /// The reviewer's latest note (approved or returned).
  final String lastReviewNote;

  bool get isAssigned => assignedBy != null || assignedByName.isNotEmpty;

  /// "#123", the number people quote.
  String get ref => id == null ? '' : '#$id';

  /// On the person's list: not done yet, or done but returned to them.
  bool get isOpen => status.isOpen || review == ReviewState.returned;

  bool get isSubmitted => review == ReviewState.submitted;

  /// Open and due on [today].
  bool isDueToday(DateTime today) =>
      status.isOpen && dueDate != null && dueDate == today;

  /// Open and past its due date (on [today]).
  bool isOverdue(DateTime today) =>
      status.isOpen && dueDate != null && dueDate!.isBefore(today);

  int get totalOutput => outputs.values.fold(0, (a, b) => a + b);

  factory ActivityReport.fromJson(Map<String, Object?> json) => ActivityReport(
    id: (json['id'] as num?)?.toInt(),
    userId: (json['user_id'] as num?)?.toInt(),
    userName: json['user_name'] as String? ?? '',
    departmentId: (json['department_id'] as num?)?.toInt(),
    departmentName: json['department_name'] as String? ?? '',
    date: _day(json['report_date']),
    description: json['description'] as String? ?? '',
    details: json['details'] as String? ?? '',
    reference: json['reference'] as String? ?? '',
    outputs: {
      for (final e in ((json['outputs'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num).toInt(),
    },
    status: ReportStatus.fromCode(json['status'] as String?),
    blocker: json['blocker'] as String? ?? '',
    urgency: TaskUrgency.fromCode(json['urgency'] as String?),
    dueDate: _day(json['due_date']),
    createdAt: _date(json['created_at'])?.toLocal(),
    updatedAt: _date(json['updated_at'])?.toLocal(),
    submittedAt: _date(json['submitted_at'])?.toLocal(),
    assignedBy: (json['assigned_by'] as num?)?.toInt(),
    assignedByName: json['assigned_by_name'] as String? ?? '',
    review: ReviewState.fromCode(json['review'] as String?),
    reviewedBy: (json['reviewed_by'] as num?)?.toInt(),
    reviewedByName: json['reviewed_by_name'] as String? ?? '',
    reviewedAt: _date(json['reviewed_at'])?.toLocal(),
    commentCount: (json['comment_count'] as num?)?.toInt() ?? 0,
    lastReviewNote: json['last_review_note'] as String? ?? '',
  );

  /// The same shape the server sends, to keep a copy on this device.
  Map<String, Object?> toJson() => {
    'id': id,
    'user_id': userId,
    'user_name': userName,
    'department_id': departmentId,
    'department_name': departmentName,
    'report_date': date == null ? null : dateKey(date!),
    'description': description,
    'details': details,
    'reference': reference,
    'outputs': outputs,
    'status': status.code,
    'blocker': blocker,
    'urgency': urgency.code,
    'due_date': dueDate == null ? null : dateKey(dueDate!),
    'created_at': createdAt?.toUtc().toIso8601String(),
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    'submitted_at': submittedAt?.toUtc().toIso8601String(),
    'assigned_by': assignedBy,
    'assigned_by_name': assignedByName,
    'review': review.code,
    'reviewed_by': reviewedBy,
    'reviewed_by_name': reviewedByName,
    'reviewed_at': reviewedAt?.toUtc().toIso8601String(),
    'comment_count': commentCount,
    'last_review_note': lastReviewNote,
  };

  ActivityReport copyWith({
    int? userId,
    String? description,
    String? details,
    String? reference,
    Map<String, int>? outputs,
    ReportStatus? status,
    String? blocker,
    TaskUrgency? urgency,
    Object? dueDate = _unset,
  }) => ActivityReport(
    id: id,
    userId: userId ?? this.userId,
    userName: userName,
    departmentId: departmentId,
    departmentName: departmentName,
    date: date,
    description: description ?? this.description,
    details: details ?? this.details,
    reference: reference ?? this.reference,
    outputs: outputs ?? this.outputs,
    status: status ?? this.status,
    blocker: blocker ?? this.blocker,
    urgency: urgency ?? this.urgency,
    dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
    createdAt: createdAt,
    updatedAt: updatedAt,
    submittedAt: submittedAt,
    assignedBy: assignedBy,
    assignedByName: assignedByName,
    review: review,
    reviewedBy: reviewedBy,
    reviewedByName: reviewedByName,
    reviewedAt: reviewedAt,
    commentCount: commentCount,
    lastReviewNote: lastReviewNote,
  );

  /// The same task with another status (one-tap status changes).
  ActivityReport withStatus(ReportStatus next) => copyWith(status: next);

  /// What is sent to save it. A task with [userId] set to someone else is
  /// assigned to them; [submit] marks it done and sends it for review,
  /// dated today by the server.
  Map<String, Object?> toSaveJson({bool submit = false, String note = ''}) => {
    'id': ?id,
    'user_id': ?userId,
    'description': description.trim(),
    'details': details.trim(),
    'reference': reference.trim(),
    'outputs': outputs,
    'status': status.code,
    'blocker': blocker.trim(),
    'urgency': urgency.code,
    'due_date': dueDate == null ? null : dateKey(dueDate!),
    if (submit) 'submit': true,
    if (submit && note.trim().isNotEmpty) 'note': note.trim(),
  };
}

/// One line in a task's timeline: a comment, or a submit / approve /
/// return (with the note that came with it).
enum CommentKind {
  comment('comment'),
  submitted('submitted'),
  approved('approved'),
  returned('returned');

  const CommentKind(this.code);
  final String code;

  static CommentKind fromCode(String? code) =>
      values.firstWhere((k) => k.code == code, orElse: () => comment);
}

class ReportComment {
  const ReportComment({
    required this.id,
    required this.body,
    required this.createdAt,
    this.kind = CommentKind.comment,
    this.userId,
    this.userName = '',
  });

  final int id;
  final String body;
  final DateTime createdAt;
  final CommentKind kind;
  final int? userId;
  final String userName;

  factory ReportComment.fromJson(Map<String, Object?> json) => ReportComment(
    id: (json['id'] as num).toInt(),
    body: json['body'] as String? ?? '',
    createdAt: _date(json['created_at'])!.toLocal(),
    kind: CommentKind.fromCode(json['kind'] as String?),
    userId: (json['user_id'] as num?)?.toInt(),
    userName: json['user_name'] as String? ?? '',
  );
}

/// One person in the reports, for filters, compliance and assigning.
class ReportPerson {
  const ReportPerson({
    required this.id,
    required this.fullName,
    this.departmentId,
    this.active = true,
  });

  final int id;
  final String fullName;
  final int? departmentId;
  final bool active;

  factory ReportPerson.fromJson(Map<String, Object?> json) => ReportPerson(
    id: (json['id'] as num).toInt(),
    fullName: json['full_name'] as String,
    departmentId: (json['department_id'] as num?)?.toInt(),
    active: json['active'] as bool? ?? true,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'full_name': fullName,
    'department_id': departmentId,
    'active': active,
  };
}

/// What the Daily reports page needs to start.
class ReportsMeta {
  const ReportsMeta({
    required this.today,
    required this.myId,
    required this.myName,
    required this.myDepartmentId,
    required this.scope,
    required this.departments,
    required this.people,
    this.canAssign = false,
  });

  /// Today in Kenya, per the online database.
  final DateTime today;
  final int myId;
  final String myName;
  final int? myDepartmentId;
  final ReportScope scope;
  final List<Department> departments;
  final List<ReportPerson> people;

  /// Directors, managers, admins and department heads assign tasks.
  final bool canAssign;

  Department? department(int? id) =>
      departments.where((d) => d.id == id).firstOrNull;

  Department? get myDepartment => department(myDepartmentId);

  /// Sees more than their own tasks (heads, managers, admins, director).
  bool get seesOthers => scope != ReportScope.own;

  /// Reviews other people's submitted work.
  bool get reviews => scope != ReportScope.own || canAssign;

  ReportPerson? person(int? id) => people.where((p) => p.id == id).firstOrNull;

  factory ReportsMeta.fromJson(Map<String, Object?> json) {
    final me = (json['me'] as Map).cast<String, Object?>();
    final scope = ReportScope.fromCode(me['scope'] as String?);
    return ReportsMeta(
      today: _day(json['today'])!,
      myId: (me['id'] as num).toInt(),
      myName: me['full_name'] as String? ?? '',
      myDepartmentId: (me['department_id'] as num?)?.toInt(),
      scope: scope,
      canAssign: me['can_assign'] as bool? ?? scope != ReportScope.own,
      departments: [
        for (final d in (json['departments'] as List? ?? const []))
          Department.fromJson((d as Map).cast<String, Object?>()),
      ],
      people: [
        for (final p in (json['people'] as List? ?? const []))
          ReportPerson.fromJson((p as Map).cast<String, Object?>()),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'today': dateKey(today),
    'me': {
      'id': myId,
      'full_name': myName,
      'department_id': myDepartmentId,
      'scope': scope.name,
      'can_assign': canAssign,
    },
    'departments': [for (final d in departments) d.toJson()],
    'people': [for (final p in people) p.toJson()],
  };
}

/// The small counts the app shows as badges (polled about once a minute).
class ReportBadge {
  const ReportBadge({
    this.unread = 0,
    this.toReview = 0,
    this.submittedToday = false,
    this.needsReport = false,
  });

  /// Notifications not read yet.
  final int unread;

  /// Submitted work waiting for this person to review.
  final int toReview;
  final bool submittedToday;

  /// Has a department, so is expected to submit daily.
  final bool needsReport;

  /// The number on the Daily reports menu item.
  int get count => unread + toReview;

  factory ReportBadge.fromJson(Map<String, Object?> json) => ReportBadge(
    unread: (json['unread'] as num?)?.toInt() ?? 0,
    toReview: (json['to_review'] as num?)?.toInt() ?? 0,
    submittedToday: json['submitted_today'] as bool? ?? false,
    needsReport: json['needs_report'] as bool? ?? false,
  );

  Map<String, Object?> toJson() => {
    'unread': unread,
    'to_review': toReview,
    'submitted_today': submittedToday,
    'needs_report': needsReport,
  };
}

/// What a notification is about.
enum NotificationKind {
  assigned('assigned', Icons.assignment_ind_outlined),
  reassigned('reassigned', Icons.swap_horiz),
  submitted('submitted', Icons.outbox_outlined),
  approved('approved', Icons.verified_outlined),
  returned('returned', Icons.undo),
  comment('comment', Icons.chat_bubble_outline),
  blocked('blocked', Icons.block),
  dueToday('due_today', Icons.today_outlined),
  overdue('overdue', Icons.warning_amber_outlined),
  reminder('reminder', Icons.edit_note_outlined);

  const NotificationKind(this.code, this.icon);
  final String code;
  final IconData icon;

  static NotificationKind fromCode(String? code) =>
      values.firstWhere((k) => k.code == code, orElse: () => comment);
}

class ReportNotification {
  const ReportNotification({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.reportId,
    this.body = '',
    this.read = false,
    this.actorName = '',
    this.task = '',
    this.urgency,
  });

  final int id;
  final NotificationKind kind;
  final DateTime createdAt;
  final int? reportId;
  final String body;
  final bool read;
  final String actorName;

  /// The task's title now (empty when it was deleted).
  final String task;
  final TaskUrgency? urgency;

  /// One line: who did what.
  String get title {
    final who = actorName.isEmpty ? 'Someone' : actorName;
    final ref = reportId == null ? '' : ' #$reportId';
    return switch (kind) {
      NotificationKind.assigned =>
        body.startsWith('Updated: ')
            ? '$who updated a task for you$ref'
            : '$who assigned you a task$ref',
      NotificationKind.reassigned => '$who gave your task$ref to someone else',
      NotificationKind.submitted => '$who submitted a task you assigned$ref',
      NotificationKind.approved => '$who approved your task$ref',
      NotificationKind.returned => '$who returned your task$ref',
      NotificationKind.comment => '$who commented on task$ref',
      NotificationKind.blocked => '$who is blocked on task$ref',
      NotificationKind.dueToday => 'Task$ref is due today',
      NotificationKind.overdue => 'Task$ref is overdue',
      NotificationKind.reminder => 'Daily report reminder',
    };
  }

  /// The detail under the title: the note or comment, else the task.
  String get detail {
    if (kind == NotificationKind.returned ||
        kind == NotificationKind.comment ||
        kind == NotificationKind.blocked ||
        kind == NotificationKind.approved ||
        kind == NotificationKind.reminder) {
      return body.isNotEmpty ? body : task;
    }
    return task.isNotEmpty ? task : body.replaceFirst('Updated: ', '');
  }

  factory ReportNotification.fromJson(Map<String, Object?> json) =>
      ReportNotification(
        id: (json['id'] as num).toInt(),
        kind: NotificationKind.fromCode(json['kind'] as String?),
        createdAt: _date(json['created_at'])!.toLocal(),
        reportId: (json['report_id'] as num?)?.toInt(),
        body: json['body'] as String? ?? '',
        read: json['read'] as bool? ?? false,
        actorName: json['actor_name'] as String? ?? '',
        task: json['task'] as String? ?? '',
        urgency: json['urgency'] == null
            ? null
            : TaskUrgency.fromCode(json['urgency'] as String?),
      );
}

/// One department's figures for a period.
class DepartmentSummary {
  const DepartmentSummary({
    required this.id,
    required this.name,
    required this.activities,
    required this.completed,
    required this.open,
    required this.blocked,
    required this.awaiting,
    required this.people,
    required this.outputs,
  });

  final int id;
  final String name;

  /// Submitted in the period.
  final int activities;

  /// Approved, of those.
  final int completed;

  /// Not done yet (any date).
  final int open;
  final int blocked;

  /// Waiting for review.
  final int awaiting;
  final int people;
  final Map<String, int> outputs;

  factory DepartmentSummary.fromJson(Map<String, Object?> json) =>
      DepartmentSummary(
        id: (json['id'] as num).toInt(),
        name: json['name'] as String,
        activities: (json['activities'] as num?)?.toInt() ?? 0,
        completed: (json['completed'] as num?)?.toInt() ?? 0,
        open: (json['open'] as num?)?.toInt() ?? 0,
        blocked: (json['blocked'] as num?)?.toInt() ?? 0,
        awaiting: (json['awaiting'] as num?)?.toInt() ?? 0,
        people: (json['people'] as num?)?.toInt() ?? 0,
        outputs: {
          for (final e in ((json['outputs'] as Map?) ?? const {}).entries)
            '${e.key}': (e.value as num).toInt(),
        },
      );
}

/// Whether one person has been submitting reports.
class ComplianceRow {
  const ComplianceRow({
    required this.id,
    required this.fullName,
    required this.departmentName,
    required this.daysSubmitted,
    required this.entries,
    required this.submittedToday,
    this.open = 0,
    this.lastDate,
  });

  final int id;
  final String fullName;
  final String departmentName;
  final int daysSubmitted;
  final int entries;
  final bool submittedToday;

  /// Tasks on their list now.
  final int open;
  final DateTime? lastDate;

  factory ComplianceRow.fromJson(Map<String, Object?> json) => ComplianceRow(
    id: (json['id'] as num).toInt(),
    fullName: json['full_name'] as String,
    departmentName: json['department_name'] as String? ?? '',
    daysSubmitted: (json['days_submitted'] as num?)?.toInt() ?? 0,
    entries: (json['entries'] as num?)?.toInt() ?? 0,
    submittedToday: json['submitted_today'] as bool? ?? false,
    open: (json['open'] as num?)?.toInt() ?? 0,
    lastDate: _day(json['last_date']),
  );
}

/// The team figures for a period.
class ReportSummary {
  const ReportSummary({
    required this.from,
    required this.to,
    required this.today,
    required this.workingDays,
    required this.status,
    required this.review,
    required this.departments,
    required this.compliance,
    required this.overdue,
    required this.attention,
  });

  final DateTime from;
  final DateTime to;
  final DateTime today;

  /// Monday–Friday in the period, up to today.
  final int workingDays;

  /// Open tasks now by status, plus Done for the ones submitted in the
  /// period.
  final Map<ReportStatus, int> status;

  /// Tasks submitted in the period, by where they are in review.
  final Map<ReviewState, int> review;
  final List<DepartmentSummary> departments;
  final List<ComplianceRow> compliance;
  final List<ActivityReport> overdue;

  /// Blocked, returned, or urgent and not done.
  final List<ActivityReport> attention;

  int count(ReportStatus s) => status[s] ?? 0;
  int reviewed(ReviewState r) => review[r] ?? 0;

  /// Submitted in the period.
  int get submitted => review.values.fold(0, (a, b) => a + b);

  /// Not done yet.
  int get open =>
      count(ReportStatus.toDo) +
      count(ReportStatus.inProgress) +
      count(ReportStatus.blocked);

  factory ReportSummary.fromJson(Map<String, Object?> json) {
    List<ActivityReport> reports(Object? list) => [
      for (final r in (list as List? ?? const []))
        ActivityReport.fromJson((r as Map).cast<String, Object?>()),
    ];
    return ReportSummary(
      from: _day(json['from'])!,
      to: _day(json['to'])!,
      today: _day(json['today'])!,
      workingDays: (json['working_days'] as num?)?.toInt() ?? 0,
      status: {
        for (final e in ((json['status'] as Map?) ?? const {}).entries)
          ReportStatus.fromCode('${e.key}'): (e.value as num).toInt(),
      },
      review: {
        for (final e in ((json['review'] as Map?) ?? const {}).entries)
          ReviewState.fromCode('${e.key}'): (e.value as num).toInt(),
      },
      departments: [
        for (final d in (json['departments'] as List? ?? const []))
          DepartmentSummary.fromJson((d as Map).cast<String, Object?>()),
      ],
      compliance: [
        for (final c in (json['compliance'] as List? ?? const []))
          ComplianceRow.fromJson((c as Map).cast<String, Object?>()),
      ],
      overdue: reports(json['overdue']),
      attention: reports(json['attention']),
    );
  }
}

/// One entry in a task's audit trail.
class ReportChange {
  const ReportChange({
    required this.action,
    required this.changedAt,
    required this.changedBy,
  });

  final String action;
  final DateTime changedAt;
  final String changedBy;

  String get label => switch (action) {
    'created' => 'Added',
    'edited' => 'Changed',
    'submitted' => 'Submitted',
    'approved' => 'Approved',
    'returned' => 'Returned',
    _ => 'Deleted',
  };

  factory ReportChange.fromJson(Map<String, Object?> json) => ReportChange(
    action: json['action'] as String,
    changedAt: _date(json['changed_at'])!.toLocal(),
    changedBy: json['changed_by'] as String? ?? '',
  );
}

/// The filter for listing tasks.
class ReportFilter {
  const ReportFilter({
    this.from,
    this.to,
    this.departmentId,
    this.userId,
    this.statuses,
    this.reviews,
    this.urgency,
    this.openOnly = false,
    this.overdueOnly = false,
    this.assignedByMe = false,
    this.toReview = false,
    this.reviewedByMe = false,
    this.search,
    this.limit,
  });

  /// Submitted on or after (tasks not submitted have no date).
  final DateTime? from;
  final DateTime? to;
  final int? departmentId;
  final int? userId;
  final List<ReportStatus>? statuses;
  final List<ReviewState>? reviews;
  final TaskUrgency? urgency;
  final bool openOnly;
  final bool overdueOnly;
  final bool assignedByMe;

  /// Submitted and waiting for this person to review.
  final bool toReview;
  final bool reviewedByMe;

  /// Words in the title, details, people or department, or "#123".
  final String? search;
  final int? limit;

  Map<String, Object?> toJson() => {
    if (from != null) 'from': dateKey(from!),
    if (to != null) 'to': dateKey(to!),
    'department_id': ?departmentId,
    'user_id': ?userId,
    if (statuses != null) 'statuses': [for (final s in statuses!) s.code],
    if (reviews != null) 'reviews': [for (final r in reviews!) r.code],
    if (urgency != null) 'urgency': urgency!.code,
    if (openOnly) 'open_only': true,
    if (overdueOnly) 'overdue_only': true,
    if (assignedByMe) 'assigned_by_me': true,
    if (toReview) 'to_review': true,
    if (reviewedByMe) 'reviewed_by_me': true,
    if (search != null && search!.trim().isNotEmpty) 'search': search!.trim(),
    'limit': ?limit,
  };
}
