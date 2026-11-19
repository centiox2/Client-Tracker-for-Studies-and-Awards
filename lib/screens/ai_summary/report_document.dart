import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart' show formatMoney;
import '../../widgets/clarity.dart';

/// A single readable report sheet. Sections use typography and dividers,
/// rather than separate cards for every paragraph or number.
class ReportDocument extends StatelessWidget {
  const ReportDocument({
    super.key,
    required this.row,
    required this.detailed,
    required this.cutoffLabel,
  });
  final Map row;
  final bool detailed;
  final String cutoffLabel;
  @override
  Widget build(BuildContext context) {
    final content = _map(row['content']);
    final snapshot = _map(row['input_snapshot']);
    final theme = Theme.of(context);
    final c = context.clarity;
    final reportDate = DateTime.tryParse('${row['summary_date']}');
    final sections = (content['sections'] as List? ?? [])
        .whereType<Map>()
        .where(
          (section) => !const {
            'history',
            'reports',
            'settings',
          }.contains(_sectionPage(section)),
        )
        .toList();
    final applications = _map(snapshot['applications']);
    final updates = _map(applications['updates_today']);
    final metrics = [
      ('Clients today', _count(_map(snapshot['weekly_tracker'])['today'])),
      ('Revenue today', _money(_map(snapshot['revenue']), 'today_cents')),
      if (updates.containsKey('applications_touched'))
        ('Applications updated today', _count(updates['applications_touched']))
      else
        ('Applications', _count(applications['total'])),
      ('Active staff', _count(_map(snapshot['staff'])['active'])),
    ];
    Widget heading(String title, {String? caption}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
            ),
          ],
        ],
      ),
    );
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Divider(height: 1, color: c.borderSubtle),
    );
    return ClarityCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 20 : 32,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'DAILY BUSINESS REPORT',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.accent,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'AI generated',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                reportDate == null
                    ? '${row['summary_date']}'
                    : DateFormat('EEEE, d MMMM y').format(reportDate),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Data as of $cutoffLabel',
                style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
              ),
              divider(),
              heading('Key figures'),
              LayoutBuilder(
                builder: (context, box) {
                  final cols = box.maxWidth >= 720 ? 4 : 2;
                  final width = (box.maxWidth - 20 * (cols - 1)) / cols;
                  return Wrap(
                    spacing: 20,
                    runSpacing: 20,
                    children: [
                      for (final (label, value) in metrics)
                        SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  value,
                                  style: Dt.tab(theme.textTheme.headlineSmall!)
                                      .copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
              divider(),
              if (!detailed) ...[
                heading('Executive summary'),
                _Prose('${content['brief'] ?? ''}', emphasis: true),
                divider(),
                heading('Highlights'),
                _Bullets(
                  content['highlights'],
                  empty: 'No additional highlights were recorded.',
                ),
                divider(),
                heading('Needs attention'),
                _Bullets(
                  content['risks'],
                  empty: 'No specific issues were identified from the available records.',
                  attention: true,
                ),
                divider(),
                heading(
                  'Suggested next steps',
                  caption: 'AI suggestions for review; no actions are performed automatically.',
                ),
                _Bullets(
                  content['actions'],
                  empty: 'No additional actions were suggested.',
                ),
              ] else ...[
                heading(
                  'Detailed report',
                  caption: 'Recorded figures, findings and suggested follow-up for each business area.',
                ),
                for (final (index, section) in sections.indexed) ...[
                  if (index > 0) divider(),
                  Text(
                    '${index + 1}. ${_sectionPage(section) == 'staff' ? 'Staff' : section['title']}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_sectionPage(section) == 'staff' &&
                      _map(snapshot['staff']).containsKey('activity')) ...[
                    heading('Staff activity that day'),
                    _StaffActivity(_map(snapshot['staff'])['activity']),
                    const SizedBox(height: 16),
                  ],
                  if (_sectionPage(section) == 'applications' &&
                      updates.isNotEmpty) ...[
                    heading('Updates logged that day'),
                    _FactRows([
                      (
                        'Applications with logged changes',
                        _count(updates['applications_touched']),
                      ),
                      for (final (key, label) in const [
                        ('added', 'Added'),
                        ('removed', 'Removed'),
                        ('statuses_changed', 'Status changed'),
                        ('documents_updated', 'Document date updated'),
                        ('submission_dates_updated', 'Submission date updated'),
                        ('offers_logged', 'Offer date first recorded'),
                        ('coes_logged', 'COE date first recorded'),
                        (
                          'offer_or_coe_dates_corrected',
                          'Offer or COE date revised',
                        ),
                        ('follow_ups_updated', 'Follow-up notes updated'),
                      ])
                        if (updates[key] is num && (updates[key] as num) > 0)
                          (label, _count(updates[key])),
                    ]),
                    const SizedBox(height: 16),
                    heading('Pipeline totals'),
                  ],
                  if (_facts(_sectionPage(section), snapshot).isNotEmpty) ...[
                    _FactRows(_facts(_sectionPage(section), snapshot)),
                    const SizedBox(height: 16),
                  ],
                  _Prose('${section['body'] ?? ''}'),
                  if ((section['findings'] as List? ?? []).isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Findings', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    _Bullets(section['findings']),
                  ],
                  if ((section['next_steps'] as List? ?? []).isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Suggested follow-up',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    _Bullets(section['next_steps']),
                  ],
                  if (_map(_map(snapshot[_sectionPage(section)])['by_status'])
                      .isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Status breakdown'),
                        children: [
                          _FactRows([
                            for (final e in _map(
                              _map(
                                snapshot[_sectionPage(section)],
                              )['by_status'],
                            ).entries)
                              (_status('${e.key}'), _count(e.value)),
                          ]),
                        ],
                      ),
                    ),
                ],
              ],
              divider(),
              Text(
                'Based on recorded business data. Missing entries do not mean no work occurred. Review AI interpretations against the recorded figures.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.textMuted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Prose extends StatelessWidget {
  const _Prose(this.text, {this.emphasis = false});
  final String text;
  final bool emphasis;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, paragraph) in text.split(RegExp(r'\n\s*\n')).indexed)
        Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
          child: Text(
            _plain(paragraph),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontSize: emphasis ? 16 : 14, height: 1.65),
          ),
        ),
    ],
  );
}

class _Bullets extends StatelessWidget {
  const _Bullets(
    this.items, {
    this.empty = 'No additional findings.',
    this.attention = false,
  });
  final Object? items;
  final String empty;
  final bool attention;
  @override
  Widget build(BuildContext context) {
    final values = items as List? ?? [];
    if (values.isEmpty) {
      return Text(
        empty,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: context.clarity.textMuted, height: 1.6),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, item) in values.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(
                    attention ? Icons.priority_high_rounded : Icons.circle,
                    size: attention ? 14 : 5,
                    color: attention
                        ? context.clarity.warningFg
                        : context.clarity.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _plain('$item'),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(height: 1.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StaffActivity extends StatelessWidget {
  const _StaffActivity(this.activity);

  final Object? activity;

  @override
  Widget build(BuildContext context) {
    final people = (activity as List? ?? []).whereType<Map>().toList();
    if (people.isEmpty) {
      return const Text('No individual staff activity was recorded that day.');
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final person in people)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${person['name']}', style: theme.textTheme.titleSmall),
                _FactRows([
                  for (final (key, label) in const [
                    ('new_clients', 'New clients'),
                    ('existing_clients', 'Existing clients'),
                    ('work_items_updated', 'Work items updated'),
                    ('reports_submitted', 'Reports submitted'),
                  ])
                    if (person[key] is num && (person[key] as num) > 0)
                      (label, _count(person[key])),
                  for (final output
                      in (person['outputs'] as List? ?? []).whereType<Map>())
                    ('${output['label']}', _count(output['count'])),
                ]),
              ],
            ),
          ),
      ],
    );
  }
}

class _FactRows extends StatelessWidget {
  const _FactRows(this.facts);
  final List<(String, String)> facts;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final pair in facts)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.clarity.borderSubtle),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  pair.$1,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: context.clarity.textMuted),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Text(
                  pair.$2,
                  textAlign: TextAlign.right,
                  style: Dt.tab(Theme.of(context).textTheme.bodyMedium!)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

Map _map(Object? value) => value is Map ? value : const {};
String _count(Object? value) =>
    value is num ? NumberFormat.decimalPattern().format(value) : '—';
String _money(Map revenue, String key) => revenue[key] is num
    ? formatMoney(
        (revenue[key] as num).round(),
        revenue['currency'] == null || revenue['currency'] == 'unspecified'
            ? 'KSh'
            : '${revenue['currency']}',
      )
    : '—';
String _plain(String value) => value
    .replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => m[1]!)
    .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
String _status(String value) => switch (value) {
  'to_do' => 'To do',
  'in_progress' => 'In progress',
  _ => value.replaceAll('_', ' '),
};
String _sectionPage(Map section) {
  if (section['page'] != null) return '${section['page']}';
  return switch ('${section['title']}'.toLowerCase()) {
    'weekly tracker' => 'weekly_tracker',
    'client tracking' => 'weekly_tracker',
    'daily reports' => 'daily_reports',
    'team to-do' => 'team_todo',
    _ => '${section['title']}'.toLowerCase(),
  };
}

List<(String, String)> _facts(String page, Map snapshot) {
  final data = _map(snapshot[page]);
  final fields = switch (page) {
    'weekly_tracker' => {
      'today': 'Clients today',
      'today_new': 'New clients today',
      'today_existing': 'Existing clients today',
      'month_new': 'New clients this month',
      'month_existing': 'Existing clients this month',
      'month_total': 'Clients this month',
    },
    'applications' => {
      'total': 'Total applications',
      'with_offer': 'With an offer',
      'with_coe': 'With a COE',
    },
    'daily_reports' => {
      'submitted_today': 'Submitted today',
      'open': 'Open work',
      'blocked': 'Blocked',
      'overdue': 'Overdue',
    },
    'team_todo' => {'open': 'Open team items', 'done': 'Completed team items'},
    'staff' => {'active': 'Active staff', 'total': 'Total staff'},
    _ => <String, String>{},
  };
  if (page == 'revenue') {
    return [
      ('Revenue today', _money(data, 'today_cents')),
      ('Month-to-date net revenue', _money(data, 'month_net_cents')),
    ];
  }
  return [
    for (final entry in fields.entries)
      if (data.containsKey(entry.key)) (entry.value, _count(data[entry.key])),
  ];
}
