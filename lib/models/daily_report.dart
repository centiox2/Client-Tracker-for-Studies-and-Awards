/// Daily activity reports: what each person did, with measurable outputs,
/// status, next action, blockers, priority and a due / follow-up date.
/// Kept only in the online database (never copied to every device).
library;

enum ReportStatus {
  completed('completed', 'Completed'),
  inProgress('in_progress', 'In progress'),
  pending('pending', 'Pending'),
  blocked('blocked', 'Blocked'),
  escalated('escalated', 'Escalated');

  const ReportStatus(this.code, this.label);
  final String code;
  final String label;

  bool get isOpen => this != completed;

  /// Needs management attention.
  bool get isProblem => this == blocked || this == escalated;

  static ReportStatus fromCode(String? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => pending);
}

enum ReportPriority {
  high('high', 'High'),
  medium('medium', 'Medium'),
  low('low', 'Low');

  const ReportPriority(this.code, this.label);
  final String code;
  final String label;

  static ReportPriority fromCode(String? code) =>
      values.firstWhere((p) => p.code == code, orElse: () => medium);
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
  employee('employee', 'Employee', 'Records and sees their own reports'),
  head(
    'head',
    'Department head',
    'Also sees everyone in their department, and its dashboard',
  ),
  manager(
    'manager',
    'Operations manager',
    'Sees every department, the full dashboard and exports',
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

  String outputLabel(String key) =>
      outputs.where((o) => o.key == key).firstOrNull?.label ??
      key.replaceAll('_', ' ');
}

DateTime? _date(Object? v) =>
    v == null || '$v'.isEmpty ? null : DateTime.tryParse('$v');

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class ActivityReport {
  const ActivityReport({
    this.id,
    this.userId,
    this.userName = '',
    this.departmentId,
    this.departmentName = '',
    required this.date,
    required this.description,
    this.reference = '',
    this.outputs = const {},
    this.status = ReportStatus.completed,
    this.nextAction = '',
    this.blocker = '',
    this.priority = ReportPriority.medium,
    this.dueDate,
    this.createdAt,
    this.updatedAt,
  });

  final int? id;
  final int? userId;
  final String userName;
  final int? departmentId;
  final String departmentName;
  final DateTime date;
  final String description;
  final String reference;
  final Map<String, int> outputs;
  final ReportStatus status;
  final String nextAction;
  final String blocker;
  final ReportPriority priority;
  final DateTime? dueDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
    date: _date(json['report_date'])!,
    description: json['description'] as String? ?? '',
    reference: json['reference'] as String? ?? '',
    outputs: {
      for (final e in ((json['outputs'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num).toInt(),
    },
    status: ReportStatus.fromCode(json['status'] as String?),
    nextAction: json['next_action'] as String? ?? '',
    blocker: json['blocker'] as String? ?? '',
    priority: ReportPriority.fromCode(json['priority'] as String?),
    dueDate: _date(json['due_date']),
    createdAt: _date(json['created_at'])?.toLocal(),
    updatedAt: _date(json['updated_at'])?.toLocal(),
  );

  /// What is sent to save it (the person and department come from the
  /// sign-in, online).
  Map<String, Object?> toSaveJson() => {
    'id': ?id,
    'report_date': dateKey(date),
    'description': description.trim(),
    'reference': reference.trim(),
    'outputs': outputs,
    'status': status.code,
    'next_action': nextAction.trim(),
    'blocker': blocker.trim(),
    'priority': priority.code,
    'due_date': dueDate == null ? null : dateKey(dueDate!),
  };
}

/// One person in the reports, for filters and compliance.
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
  });

  /// Today in Kenya, per the online database.
  final DateTime today;
  final int myId;
  final String myName;
  final int? myDepartmentId;
  final ReportScope scope;
  final List<Department> departments;
  final List<ReportPerson> people;

  Department? department(int? id) =>
      departments.where((d) => d.id == id).firstOrNull;

  Department? get myDepartment => department(myDepartmentId);

  /// Sees more than their own reports (heads, managers, admins, director).
  bool get seesOthers => scope != ReportScope.own;

  factory ReportsMeta.fromJson(Map<String, Object?> json) {
    final me = (json['me'] as Map).cast<String, Object?>();
    return ReportsMeta(
      today: _date(json['today'])!,
      myId: (me['id'] as num).toInt(),
      myName: me['full_name'] as String? ?? '',
      myDepartmentId: (me['department_id'] as num?)?.toInt(),
      scope: ReportScope.fromCode(me['scope'] as String?),
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
    required this.escalated,
    required this.people,
    required this.outputs,
  });

  final int id;
  final String name;
  final int activities;
  final int completed;
  final int open;
  final int blocked;
  final int escalated;
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
        escalated: (json['escalated'] as num?)?.toInt() ?? 0,
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
    this.lastDate,
  });

  final int id;
  final String fullName;
  final String departmentName;
  final int daysSubmitted;
  final int entries;
  final bool submittedToday;
  final DateTime? lastDate;

  factory ComplianceRow.fromJson(Map<String, Object?> json) => ComplianceRow(
    id: (json['id'] as num).toInt(),
    fullName: json['full_name'] as String,
    departmentName: json['department_name'] as String? ?? '',
    daysSubmitted: (json['days_submitted'] as num?)?.toInt() ?? 0,
    entries: (json['entries'] as num?)?.toInt() ?? 0,
    submittedToday: json['submitted_today'] as bool? ?? false,
    lastDate: _date(json['last_date']),
  );
}

/// The dashboard's figures for a period, all from submitted reports.
class ReportSummary {
  const ReportSummary({
    required this.from,
    required this.to,
    required this.today,
    required this.workingDays,
    required this.status,
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
  final Map<ReportStatus, int> status;
  final List<DepartmentSummary> departments;
  final List<ComplianceRow> compliance;
  final List<ActivityReport> overdue;
  final List<ActivityReport> attention;

  int get total => status.values.fold(0, (a, b) => a + b);
  int count(ReportStatus s) => status[s] ?? 0;
  int get open => total - count(ReportStatus.completed);

  factory ReportSummary.fromJson(Map<String, Object?> json) {
    List<ActivityReport> reports(Object? list) => [
      for (final r in (list as List? ?? const []))
        ActivityReport.fromJson((r as Map).cast<String, Object?>()),
    ];
    return ReportSummary(
      from: _date(json['from'])!,
      to: _date(json['to'])!,
      today: _date(json['today'])!,
      workingDays: (json['working_days'] as num?)?.toInt() ?? 0,
      status: {
        for (final e in ((json['status'] as Map?) ?? const {}).entries)
          ReportStatus.fromCode('${e.key}'): (e.value as num).toInt(),
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

/// One entry in a report's audit trail.
class ReportChange {
  const ReportChange({
    required this.action,
    required this.changedAt,
    required this.changedBy,
  });

  final String action;
  final DateTime changedAt;
  final String changedBy;

  factory ReportChange.fromJson(Map<String, Object?> json) => ReportChange(
    action: json['action'] as String,
    changedAt: _date(json['changed_at'])!.toLocal(),
    changedBy: json['changed_by'] as String? ?? '',
  );
}

/// The filter for listing reports.
class ReportFilter {
  const ReportFilter({
    this.from,
    this.to,
    this.departmentId,
    this.userId,
    this.statuses,
    this.priority,
    this.openOnly = false,
    this.overdueOnly = false,
    this.search,
  });

  final DateTime? from;
  final DateTime? to;
  final int? departmentId;
  final int? userId;
  final List<ReportStatus>? statuses;
  final ReportPriority? priority;
  final bool openOnly;
  final bool overdueOnly;
  final String? search;

  Map<String, Object?> toJson() => {
    if (from != null) 'from': dateKey(from!),
    if (to != null) 'to': dateKey(to!),
    'department_id': ?departmentId,
    'user_id': ?userId,
    if (statuses != null) 'statuses': [for (final s in statuses!) s.code],
    if (priority != null) 'priority': priority!.code,
    if (openOnly) 'open_only': true,
    if (overdueOnly) 'overdue_only': true,
    if (search != null && search!.trim().isNotEmpty) 'search': search!.trim(),
  };
}
