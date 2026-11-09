import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/daily_report.dart';

/// One exported operations report: the period, the filters it was made
/// with, the dashboard's figures and every entry. Every figure comes from
/// submitted reports; nothing is estimated.
class OperationsReport {
  const OperationsReport({
    required this.title,
    required this.periodLabel,
    required this.filtersLabel,
    required this.generatedBy,
    required this.generatedAt,
    required this.summary,
    required this.entries,
    required this.departments,
  });

  /// "Daily Operations Report", "Weekly Performance Report"…
  final String title;
  final String periodLabel;

  /// The filters used ("All departments · Everyone").
  final String filtersLabel;
  final String generatedBy;
  final DateTime generatedAt;
  final ReportSummary summary;
  final List<ActivityReport> entries;
  final List<Department> departments;

  Department? department(int? id) =>
      departments.where((d) => d.id == id).firstOrNull;

  /// "Applications submitted 4 · COEs issued 2"
  String outputsText(int? departmentId, Map<String, int> outputs) {
    final d = department(departmentId);
    return [
      for (final e in outputs.entries)
        '${d?.outputLabel(e.key) ?? e.key.replaceAll('_', ' ')} ${e.value}',
    ].join(' · ');
  }

  String get fileStem {
    final slug = title.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    return '${slug}_${DateFormat('yyyy-MM-dd').format(summary.from)}'
        '${summary.to == summary.from ? '' : '_to_${DateFormat('yyyy-MM-dd').format(summary.to)}'}';
  }
}

final _day = DateFormat('dd/MM/yyyy');
final _stamp = DateFormat('dd/MM/yyyy HH:mm');

String _d(DateTime? d) => d == null ? '' : _day.format(d);

/// The report as an Excel workbook: Summary, Departments, Entries,
/// Open & overdue, Compliance.
Uint8List operationsReportToExcel(OperationsReport report) {
  final excel = Excel.createExcel();
  final header = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.blue,
    fontColorHex: ExcelColor.white,
  );
  final bold = CellStyle(bold: true);

  void row(Sheet s, int r, List<Object?> cells, {CellStyle? style}) {
    for (var c = 0; c < cells.length; c++) {
      final v = cells[c];
      s.updateCell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
        v is int ? IntCellValue(v) : TextCellValue('${v ?? ''}'),
        cellStyle: style,
      );
    }
  }

  final s = report.summary;

  // ---- Summary --------------------------------------------------------------
  final summary = excel['Summary'];
  excel.setDefaultSheet('Summary');
  excel.delete('Sheet1');
  var r = 0;
  row(summary, r++, [report.title], style: CellStyle(bold: true, fontSize: 14));
  row(summary, r++, ['Period', report.periodLabel]);
  row(summary, r++, ['Filters', report.filtersLabel]);
  row(summary, r++, [
    'Generated',
    '${_stamp.format(report.generatedAt)} by ${report.generatedBy}',
  ]);
  row(summary, r++, ['Working days in period', s.workingDays]);
  r++;
  row(summary, r++, ['Status', 'Activities'], style: header);
  row(summary, r++, ['Total', s.total], style: bold);
  for (final status in ReportStatus.values) {
    row(summary, r++, [status.label, s.count(status)]);
  }
  row(summary, r++, ['Overdue (open, past due date)', s.overdue.length]);
  summary.setColumnWidth(0, 32);
  summary.setColumnWidth(1, 40);

  // ---- Departments ------------------------------------------------------------
  final depts = excel['Departments'];
  r = 0;
  row(depts, r++, [
    'Department',
    'Activities',
    'Completed',
    'Open',
    'Blocked',
    'Escalated',
    'People reporting',
    'Outputs',
  ], style: header);
  for (final d in s.departments) {
    row(depts, r++, [
      d.name,
      d.activities,
      d.completed,
      d.open,
      d.blocked,
      d.escalated,
      d.people,
      report.outputsText(d.id, d.outputs),
    ]);
  }
  depts.setColumnWidth(0, 34);
  depts.setColumnWidth(7, 70);

  // ---- Entries ------------------------------------------------------------------
  const entryHeader = [
    'Date',
    'Person',
    'Department',
    'Activity / task',
    'Reference',
    'Outputs',
    'Status',
    'Priority',
    'Next action',
    'Challenge / blocker',
    'Due / follow-up',
    'Submitted',
  ];
  List<Object?> entryRow(ActivityReport e) => [
    _d(e.date),
    e.userName,
    e.departmentName,
    e.description,
    e.reference,
    report.outputsText(e.departmentId, e.outputs),
    e.status.label,
    e.priority.label,
    e.nextAction,
    e.blocker,
    _d(e.dueDate),
    e.createdAt == null ? '' : _stamp.format(e.createdAt!),
  ];
  void entriesSheet(String name, List<ActivityReport> list) {
    final sheet = excel[name];
    var i = 0;
    row(sheet, i++, entryHeader, style: header);
    for (final e in list) {
      row(sheet, i++, entryRow(e));
    }
    sheet.setColumnWidth(1, 20);
    sheet.setColumnWidth(2, 28);
    sheet.setColumnWidth(3, 50);
    sheet.setColumnWidth(5, 40);
    sheet.setColumnWidth(8, 36);
    sheet.setColumnWidth(9, 36);
  }

  entriesSheet('Entries', report.entries);
  final open = {
    for (final e in [...s.overdue, ...s.attention]) e.id: e,
  }.values.toList()..sort((a, b) => a.date.compareTo(b.date));
  entriesSheet('Open & overdue', open);

  // ---- Compliance -----------------------------------------------------------------
  final compliance = excel['Compliance'];
  r = 0;
  row(compliance, r++, [
    'Person',
    'Department',
    'Days submitted',
    'Working days',
    'Entries',
    'Submitted today',
    'Last report',
  ], style: header);
  for (final c in s.compliance) {
    row(compliance, r++, [
      c.fullName,
      c.departmentName,
      c.daysSubmitted,
      s.workingDays,
      c.entries,
      c.submittedToday ? 'Yes' : 'No',
      _d(c.lastDate),
    ]);
  }
  compliance.setColumnWidth(0, 24);
  compliance.setColumnWidth(1, 34);

  final bytes = excel.save(fileName: '${report.fileStem}.xlsx');
  if (bytes == null) throw StateError('Excel export failed.');
  return Uint8List.fromList(bytes);
}

/// The report as a PDF (A4 landscape): summary, departments, items needing
/// attention, compliance and every entry. [regular] and [bold] are the
/// app's font files, so any name or symbol prints correctly.
Future<Uint8List> operationsReportToPdf(
  OperationsReport report, {
  required ByteData regular,
  required ByteData bold,
}) async {
  final theme = pw.ThemeData.withFont(
    base: pw.Font.ttf(regular),
    bold: pw.Font.ttf(bold),
  );
  final doc = pw.Document(
    title: report.title,
    author: report.generatedBy,
    creator: 'S&A Hub',
    theme: theme,
  );
  const navy = PdfColor.fromInt(0xFF001A45);
  const grey = PdfColor.fromInt(0xFF5F6670);
  const line = PdfColor.fromInt(0xFFD5D9DE);
  final s = report.summary;

  pw.Widget heading(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
    child: pw.Text(
      text,
      style: pw.TextStyle(
        fontSize: 12,
        fontWeight: pw.FontWeight.bold,
        color: navy,
      ),
    ),
  );

  pw.Widget table(
    List<String> headers,
    List<List<String>> rows, {
    Map<int, pw.TableColumnWidth>? widths,
  }) => rows.isEmpty
      ? pw.Text('None.', style: const pw.TextStyle(fontSize: 9, color: grey))
      : pw.TableHelper.fromTextArray(
          headers: headers,
          data: rows,
          columnWidths: widths,
          headerStyle: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(color: navy),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 3,
          ),
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(color: line, width: 0.5),
            bottom: pw.BorderSide(color: line, width: 0.5),
          ),
          cellAlignment: pw.Alignment.topLeft,
          headerAlignment: pw.Alignment.centerLeft,
        );

  pw.Widget stat(String label, int value) => pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.all(8),
      margin: const pw.EdgeInsets.only(right: 6),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: grey)),
          pw.SizedBox(height: 2),
          pw.Text(
            '$value',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    ),
  );

  List<String> entryCells(ActivityReport e) => [
    _d(e.date),
    e.userName,
    e.departmentName,
    [
      e.description,
      if (e.reference.isNotEmpty) 'Ref: ${e.reference}',
    ].join('\n'),
    report.outputsText(e.departmentId, e.outputs),
    '${e.status.label}\n${e.priority.label}',
    [
      if (e.nextAction.isNotEmpty) 'Next: ${e.nextAction}',
      if (e.blocker.isNotEmpty) 'Blocker: ${e.blocker}',
    ].join('\n'),
    _d(e.dueDate),
  ];
  const entryHeaders = [
    'Date',
    'Person',
    'Department',
    'Activity / task',
    'Outputs',
    'Status',
    'Next action / blocker',
    'Due',
  ];
  const entryWidths = {
    0: pw.FixedColumnWidth(48),
    1: pw.FixedColumnWidth(60),
    2: pw.FixedColumnWidth(72),
    3: pw.FlexColumnWidth(3),
    4: pw.FlexColumnWidth(2),
    5: pw.FixedColumnWidth(50),
    6: pw.FlexColumnWidth(2.4),
    7: pw.FixedColumnWidth(48),
  };
  final open = {
    for (final e in [...s.overdue, ...s.attention]) e.id: e,
  }.values.toList()..sort((a, b) => a.date.compareTo(b.date));

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (context) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        margin: const pw.EdgeInsets.only(bottom: 6),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: line)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Studies and Awards Limited',
                    style: const pw.TextStyle(fontSize: 8, color: grey),
                  ),
                  pw.Text(
                    report.title,
                    style: pw.TextStyle(
                      fontSize: 15,
                      fontWeight: pw.FontWeight.bold,
                      color: navy,
                    ),
                  ),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  report.periodLabel,
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  report.filtersLabel,
                  style: const pw.TextStyle(fontSize: 8, color: grey),
                ),
              ],
            ),
          ],
        ),
      ),
      footer: (context) => pw.Row(
        children: [
          pw.Text(
            'Generated ${_stamp.format(report.generatedAt)} by '
            '${report.generatedBy} · from submitted daily reports',
            style: const pw.TextStyle(fontSize: 7, color: grey),
          ),
          pw.Spacer(),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: grey),
          ),
        ],
      ),
      build: (context) => [
        pw.Row(
          children: [
            stat('Activities', s.total),
            stat('Completed', s.count(ReportStatus.completed)),
            stat(
              'In progress / pending',
              s.count(ReportStatus.inProgress) + s.count(ReportStatus.pending),
            ),
            stat(
              'Blocked / escalated',
              s.count(ReportStatus.blocked) + s.count(ReportStatus.escalated),
            ),
            stat('Overdue', s.overdue.length),
          ],
        ),
        heading('Departments'),
        table(
          [
            'Department',
            'Activities',
            'Completed',
            'Open',
            'Blocked',
            'Escalated',
            'People',
            'Outputs',
          ],
          [
            for (final d in s.departments)
              [
                d.name,
                '${d.activities}',
                '${d.completed}',
                '${d.open}',
                '${d.blocked}',
                '${d.escalated}',
                '${d.people}',
                report.outputsText(d.id, d.outputs),
              ],
          ],
          widths: const {
            0: pw.FlexColumnWidth(2.2),
            7: pw.FlexColumnWidth(3.5),
          },
        ),
        heading('Needs attention: overdue, blocked and escalated'),
        table(entryHeaders, [
          for (final e in open) entryCells(e),
        ], widths: entryWidths),
        heading(
          'Submission compliance (${s.workingDays} working '
          'day${s.workingDays == 1 ? '' : 's'})',
        ),
        table(
          [
            'Person',
            'Department',
            'Days submitted',
            'Entries',
            'Today',
            'Last report',
          ],
          [
            for (final c in s.compliance)
              [
                c.fullName,
                c.departmentName,
                '${c.daysSubmitted} of ${s.workingDays}',
                '${c.entries}',
                c.submittedToday ? 'Submitted' : 'Not yet',
                _d(c.lastDate),
              ],
          ],
        ),
        heading('All entries (${report.entries.length})'),
        table(entryHeaders, [
          for (final e in report.entries) entryCells(e),
        ], widths: entryWidths),
      ],
    ),
  );
  return doc.save();
}
