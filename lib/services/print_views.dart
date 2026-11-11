import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../repositories/application_repository.dart';
import '../repositories/report_repository.dart';
import 'app_info.dart';
import 'export_actions.dart' show deliverFile;

// Printable pages (A4 PDFs, in the brand colours): one week, one month's
// report, one student's application. Open the saved file to print it.

const _navy = PdfColor.fromInt(0xFF001A45);
const _gold = PdfColor.fromInt(0xFFFBBA00);
const _grey = PdfColor.fromInt(0xFF5F6670);
const _line = PdfColor.fromInt(0xFFD5D9DE);
const _shade = PdfColor.fromInt(0xFFF3F5F8);

final _num = NumberFormat.decimalPattern();
String _n(num v) => _num.format(v);
String _d(DateTime? t) => t == null ? '—' : DateFormat('d MMM y').format(t);

class _Doc {
  _Doc(
    this.title,
    this.subtitle, {
    required ByteData regular,
    required ByteData bold,
  }) : doc = pw.Document(
         title: title,
         creator: 'S&A Hub ${AppInfo.version}',
         theme: pw.ThemeData.withFont(
           base: pw.Font.ttf(regular),
           bold: pw.Font.ttf(bold),
         ),
       );

  final String title;
  final String subtitle;
  final pw.Document doc;

  void page(List<pw.Widget> body, {bool landscape = false}) => doc.addPage(
    pw.MultiPage(
      pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 32, 36, 32),
      header: (c) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        margin: const pw.EdgeInsets.only(bottom: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _gold, width: 2)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'STUDIES AND AWARDS',
                    style: pw.TextStyle(
                      fontSize: 7,
                      letterSpacing: 1.2,
                      color: _grey,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: _navy,
                    ),
                  ),
                ],
              ),
            ),
            pw.Text(
              subtitle,
              style: const pw.TextStyle(fontSize: 9, color: _grey),
            ),
          ],
        ),
      ),
      footer: (c) => pw.Row(
        children: [
          pw.Text(
            'Printed ${DateFormat('d MMM y, HH:mm').format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 7, color: _grey),
          ),
          pw.Spacer(),
          pw.Text(
            'Page ${c.pageNumber} of ${c.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: _grey),
          ),
        ],
      ),
      build: (_) => body,
    ),
  );

  Future<Uint8List> save() => doc.save();
}

pw.Widget _heading(String text) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
  child: pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: 11,
      fontWeight: pw.FontWeight.bold,
      color: _navy,
    ),
  ),
);

pw.Widget _stats(List<(String, String)> items) => pw.Row(
  children: [
    for (final (label, value) in items)
      pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(8),
          margin: const pw.EdgeInsets.only(right: 6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _line, width: 0.7),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                label,
                style: const pw.TextStyle(fontSize: 8, color: _grey),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 15,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
  ],
);

/// A table; numeric columns (all but the first) are right-aligned, and a
/// last row named "Total" is bold.
pw.Widget _table(
  List<String> headers,
  List<List<String>> rows, {
  bool totalRow = false,
  double firstWidth = 3,
}) {
  if (rows.isEmpty) {
    return pw.Text(
      'Nothing recorded.',
      style: const pw.TextStyle(fontSize: 9, color: _grey),
    );
  }
  return pw.TableHelper.fromTextArray(
    headers: headers,
    data: rows,
    columnWidths: {
      0: pw.FlexColumnWidth(firstWidth),
      for (var i = 1; i < headers.length; i++) i: const pw.FlexColumnWidth(1),
    },
    headerStyle: pw.TextStyle(
      fontSize: 8,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.white,
    ),
    headerDecoration: const pw.BoxDecoration(color: _navy),
    cellStyle: const pw.TextStyle(fontSize: 8.5),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    oddRowDecoration: const pw.BoxDecoration(color: _shade),
    border: const pw.TableBorder(
      horizontalInside: pw.BorderSide(color: _line, width: 0.5),
      bottom: pw.BorderSide(color: _line, width: 0.5),
    ),
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignments: {
      for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight,
    },
    headerAlignments: {
      for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight,
    },
    cellDecoration: totalRow
        ? (index, data, row) => row == rows.length
              ? const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE6EAF0))
              : const pw.BoxDecoration()
        : null,
  );
}

/// One week: everyone's New / Existing for each day, the totals and notes.
Future<Uint8List> weekToPdf(
  Report r, {
  required ByteData regular,
  required ByteData bold,
}) async {
  final title = 'Week of ${DateFormat('d MMMM y').format(r.from)}';
  final doc = _Doc(
    title,
    '${DateFormat('EEE d MMM').format(r.from)} – ${DateFormat('EEE d MMM y').format(r.to)}',
    regular: regular,
    bold: bold,
  );
  final staff = [...r.staff]
    ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
  String cell(ReportStaff s, ReportDay d) {
    final c = r.cellFor(s.staffId, d.dayId);
    if (c == null) return '—';
    if (c.off) return 'Off';
    return '${c.newClients} / ${c.existingClients}';
  }

  final notes = [
    for (final d in r.days)
      if ((d.note ?? '').trim().isNotEmpty)
        [DateFormat('EEE d MMM').format(d.date), d.note!.trim()],
  ];
  doc.page(landscape: true, [
    _stats([
      ('New clients', _n(r.newClients)),
      ('Existing clients', _n(r.existingClients)),
      ('Total', _n(r.total)),
      ('Daily average', r.dailyAverage.toStringAsFixed(1)),
    ]),
    _heading('Clients by day  (New / Existing)'),
    _table(
      [
        'Staff',
        for (final d in r.days) DateFormat('EEE d').format(d.date),
        'New',
        'Existing',
        'Total',
      ],
      [
        for (final s in staff)
          [
            s.name,
            for (final d in r.days) cell(s, d),
            _n(s.newClients),
            _n(s.existingClients),
            _n(s.total),
          ],
        [
          'Total',
          for (final d in r.days) '${d.newClients} / ${d.existingClients}',
          _n(r.newClients),
          _n(r.existingClients),
          _n(r.total),
        ],
      ],
      totalRow: true,
      firstWidth: 2.4,
    ),
    if (notes.isNotEmpty) ...[
      _heading('Day notes'),
      _table(['Day', 'Note'], notes, firstWidth: 1),
    ],
  ]);
  return doc.save();
}

/// One period's report (usually a month): totals, week by week, each
/// person's numbers and the days.
Future<Uint8List> reportToPdf(
  Report r, {
  required String title,
  required ByteData regular,
  required ByteData bold,
}) async {
  final doc = _Doc(
    title,
    '${_d(r.from)} – ${_d(r.to)}',
    regular: regular,
    bold: bold,
  );
  final weeks = r.weeks;
  doc.page([
    _stats([
      ('New clients', _n(r.newClients)),
      ('Existing clients', _n(r.existingClients)),
      ('Total', _n(r.total)),
      ('Daily average', r.dailyAverage.toStringAsFixed(1)),
    ]),
    if (weeks.length > 1) ...[
      _heading('Week by week'),
      _table(
        ['Week of', 'New', 'Existing', 'Total', 'Daily avg'],
        [
          for (final w in weeks)
            [
              DateFormat('d MMM').format(w.start),
              _n(w.newClients),
              _n(w.existingClients),
              _n(w.total),
              w.dailyAverage.toStringAsFixed(1),
            ],
        ],
      ),
    ],
    _heading('By staff member'),
    _table(
      ['Staff', 'New', 'Existing', 'Total', 'Days worked', 'Days off'],
      [
        for (final s in r.staff)
          [
            s.name,
            _n(s.newClients),
            _n(s.existingClients),
            _n(s.total),
            '${s.daysWorked}',
            '${s.daysOff}',
          ],
        ['Total', _n(r.newClients), _n(r.existingClients), _n(r.total), '', ''],
      ],
      totalRow: true,
    ),
    _heading('Day by day'),
    _table(
      ['Day', 'New', 'Existing', 'Total', 'Note'],
      [
        for (final d in r.days)
          [
            DateFormat('EEE d MMM').format(d.date),
            _n(d.newClients),
            _n(d.existingClients),
            _n(d.newClients + d.existingClients),
            (d.note ?? '').trim(),
          ],
      ],
    ),
  ]);
  return doc.save();
}

/// One student's application: the details, dates, notes and history.
Future<Uint8List> applicationToPdf(
  Application a,
  List<ApplicationChange> history, {
  required ByteData regular,
  required ByteData bold,
}) async {
  final doc = _Doc(
    a.student.isEmpty ? 'Application' : a.student,
    a.status.isEmpty ? 'Application' : a.status,
    regular: regular,
    bold: bold,
  );
  pw.Widget field(String label, String value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 4),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 140,
          child: pw.Text(
            label,
            style: const pw.TextStyle(fontSize: 9, color: _grey),
          ),
        ),
        pw.Expanded(
          child: pw.Text(
            value.trim().isEmpty ? '—' : value.trim(),
            style: const pw.TextStyle(fontSize: 10),
          ),
        ),
      ],
    ),
  );
  final offerWait = a.offerWaitDays(DateTime.now());
  doc.page([
    _heading('Details'),
    field('Status', a.status),
    field('RTO', a.rto),
    field('Country', a.country),
    field('Assignee', a.assignee),
    _heading('Dates'),
    field('Documents submitted', _d(a.docDate)),
    field('Application submitted', _d(a.appDate)),
    field(
      'Offer letter received',
      a.offerDate != null
          ? _d(a.offerDate)
          : offerWait == null
          ? '—'
          : 'Not yet · waiting $offerWait days',
    ),
    field('COE issued', _d(a.coeDate)),
    _heading('Notes'),
    field('To do', a.todo),
    if (a.followUp.isNotEmpty) field('Follow-up', a.followUp),
    _heading('History'),
    _table(
      ['Date', 'Change'],
      [
        for (final h in history)
          [
            _d(h.at),
            '${h.field}: ${h.oldValue.isEmpty ? '—' : h.oldValue} → '
                '${h.newValue.isEmpty ? '—' : h.newValue}',
          ],
      ],
      firstWidth: 1,
    ),
  ]);
  return doc.save();
}

/// Makes a printable PDF with [build] (given the app's fonts) and saves it.
Future<void> savePrintable(
  BuildContext context, {
  required String fileName,
  required Future<Uint8List> Function(ByteData regular, ByteData bold) build,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final fonts = await Future.wait([
      rootBundle.load('assets/fonts/Inter-400.ttf'),
      rootBundle.load('assets/fonts/Inter-700.ttf'),
    ]);
    final bytes = await build(fonts[0], fonts[1]);
    if (!context.mounted) return;
    await deliverFile(
      context,
      dialogTitle: 'Save printable PDF',
      fileName: fileName.endsWith('.pdf') ? fileName : '$fileName.pdf',
      extension: 'pdf',
      bytes: bytes,
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Couldn’t make the PDF: $e')),
    );
  }
}
