import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../repositories/report_repository.dart';

/// Turns a Reports period (a day, week or month) into files: a full Excel
/// workbook, and a printable page (print → "Save as PDF" makes the PDF).

String _avg(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _pct(int part, int total) =>
    total == 0 ? '–' : '${(part * 100 / total).round()}%';

/// Workbook with four sheets: Summary, By staff, By day, Staff by day.
String _change(int now, int before) {
  final diff = now - before;
  if (diff == 0) return 'same';
  final pct = before == 0 ? '' : ' (${(diff.abs() * 100 / before).round()}%)';
  return '${diff > 0 ? '+' : '−'}${diff.abs()}$pct';
}

/// Ranges longer than about two months get a month-by-month section instead
/// of hundreds of day rows (a year report, say).
bool _longRange(Report r) => r.to.difference(r.from).inDays > 62;

/// Workbook with Summary, By staff, By day (or By month) and Staff by day.
/// [previous] adds the comparison with the period before.
Uint8List reportToExcel(
  Report report, {
  required String title,
  int? target,
  Report? previous,
}) {
  final excel = Excel.createExcel();
  final header = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.blue,
    fontColorHex: ExcelColor.white,
  );
  final totalStyle = CellStyle(bold: true, backgroundColorHex: ExcelColor.grey);

  Sheet sheet(String name) => excel[name];
  void row(Sheet s, int r, List<Object?> cells, {CellStyle? style}) {
    for (var c = 0; c < cells.length; c++) {
      final v = cells[c];
      s.updateCell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
        v is int
            ? IntCellValue(v)
            : v is double
            ? DoubleCellValue(v)
            : TextCellValue('${v ?? ''}'),
        cellStyle: style,
      );
    }
  }

  // ---- Summary ------------------------------------------------------------
  final summary = sheet('Summary');
  excel.setDefaultSheet('Summary');
  excel.delete('Sheet1');
  var r = 0;
  row(summary, r++, [title], style: CellStyle(bold: true, fontSize: 14));
  row(summary, r++, ['Studies and Awards Limited · Client Tracker']);
  r++;
  for (final (label, value) in <(String, Object)>[
    ('Total clients', report.total),
    ('New clients', report.newClients),
    ('Existing clients', report.existingClients),
    ('Average per day', double.parse(_avg(report.dailyAverage))),
    ('Working days so far', report.staffedDaysSoFar),
    ('Staff who saw clients', report.staffWithClients),
    if (target != null) ('Daily target', target),
  ]) {
    row(summary, r++, [label, value]);
  }
  if (previous != null) {
    r++;
    row(summary, r++, [
      'Compared with ${DateFormat('d MMM y').format(previous.from)} – '
          '${DateFormat('d MMM y').format(previous.to)}',
    ], style: CellStyle(bold: true));
    row(summary, r++, [
      'Total clients',
      previous.total,
      _change(report.total, previous.total),
    ]);
    row(summary, r++, [
      'New clients',
      previous.newClients,
      _change(report.newClients, previous.newClients),
    ]);
    row(summary, r++, [
      'Existing clients',
      previous.existingClients,
      _change(report.existingClients, previous.existingClients),
    ]);
  }
  row(summary, r + 1, [
    'Numbers for staff marked off are excluded. The daily average counts '
        'working days so far, skipping holidays.',
  ]);

  // ---- By staff -----------------------------------------------------------
  final byStaff = sheet('By staff');
  r = 0;
  row(byStaff, r++, [
    'Staff',
    'New',
    'Existing',
    'Total',
    'Share of clients',
    'Avg / day',
    'Days worked',
    'Days off',
  ], style: header);
  for (final s in report.staff) {
    row(byStaff, r++, [
      s.active ? s.name : '${s.name} (inactive)',
      s.newClients,
      s.existingClients,
      s.total,
      _pct(s.total, report.total),
      s.daysWorked == 0 ? 0.0 : double.parse(_avg(s.total / s.daysWorked)),
      s.daysWorked,
      s.daysOff,
    ]);
  }
  row(byStaff, r, [
    'Total',
    report.newClients,
    report.existingClients,
    report.total,
  ], style: totalStyle);

  // ---- By month (long ranges) ----------------------------------------------
  final months = report.months;
  if (months.length > 1) {
    final byMonth = sheet('By month');
    var m = 0;
    row(byMonth, m++, [
      'Month',
      'New',
      'Existing',
      'Total',
      'Average per day',
    ], style: header);
    for (final b in months) {
      row(byMonth, m++, [
        DateFormat('MMMM y').format(b.start),
        b.newClients,
        b.existingClients,
        b.total,
        double.parse(_avg(b.dailyAverage)),
      ]);
    }
    byMonth.setColumnWidth(0, 24);
  }

  // ---- By day -------------------------------------------------------------
  final byDay = sheet('By day');
  r = 0;
  row(byDay, r++, [
    'Day',
    'New',
    'Existing',
    'Total',
    'Staff off',
    'Note',
  ], style: header);
  for (final d in report.days) {
    row(byDay, r++, [
      DateFormat('EEE dd/MM/yyyy').format(d.date),
      d.newClients,
      d.existingClients,
      d.total,
      d.isHoliday ? 'Holiday' : d.offCount,
      d.note ?? '',
    ]);
  }
  row(byDay, r, [
    'Total',
    report.newClients,
    report.existingClients,
    report.total,
  ], style: totalStyle);

  // ---- Staff by day -------------------------------------------------------
  final grid = sheet('Staff by day');
  final staff = [...report.staff]
    ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
  row(grid, 0, [
    'Staff',
    for (final d in report.days) DateFormat('EEE dd/MM').format(d.date),
    'Total',
  ], style: header);
  for (var i = 0; i < staff.length; i++) {
    final s = staff[i];
    row(grid, i + 1, [
      s.name,
      for (final d in report.days)
        switch (report.cellFor(s.staffId, d.dayId)) {
          null => '',
          final c when c.off => 'Off',
          final c => c.total,
        },
      s.total,
    ]);
  }
  row(grid, staff.length + 1, [
    'Day total',
    for (final d in report.days) d.isHoliday ? 'Holiday' : d.total,
    report.total,
  ], style: totalStyle);
  for (final s in [summary, byStaff, byDay, grid]) {
    s.setColumnWidth(0, 24);
  }

  final bytes = excel.save(fileName: 'report.xlsx');
  if (bytes == null) throw StateError('Excel export failed.');
  return Uint8List.fromList(bytes);
}

/// A self-contained, print-ready page. Opening it shows the browser's print
/// dialog, where "Save as PDF" produces the PDF.
Uint8List reportToPrintableHtml(
  Report report, {
  required String title,
  int? target,
  Report? previous,
}) {
  String esc(String s) => const HtmlEscape().convert(s);
  final staff = report.staff;
  final b = StringBuffer()
    ..writeln('<!doctype html><html><head><meta charset="utf-8">')
    ..writeln('<title>${esc(title)}</title>')
    ..writeln('''<style>
      body{font:13px/1.45 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;
           color:#1d1d1f;margin:32px;}
      h1{font-size:20px;margin:0 0 4px} .sub{color:#666;margin:0 0 20px}
      .kpis{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:20px}
      .kpi{border:1px solid #ddd;border-radius:8px;padding:10px 14px;min-width:120px}
      .kpi b{display:block;font-size:20px}
      .kpi span{color:#666;font-size:11px}
      h2{font-size:14px;margin:22px 0 8px}
      table{border-collapse:collapse;width:100%}
      th,td{border-bottom:1px solid #e5e5e5;padding:6px 8px;text-align:right}
      th{font-size:11px;color:#666;font-weight:600}
      th:first-child,td:first-child{text-align:left}
      td.note{text-align:left;color:#555}
      tfoot td{font-weight:700;border-top:1px solid #999}
      .muted{color:#999} .foot{color:#888;font-size:11px;margin-top:20px}
      @media print{body{margin:12mm}}
    </style></head><body>''')
    ..writeln('<h1>${esc(title)}</h1>')
    ..writeln(
      '<p class="sub">Studies and Awards Limited · Client Tracker report · '
      'printed '
      '${esc(DateFormat('d MMM y, HH:mm').format(DateTime.now()))}</p>',
    )
    ..writeln('<div class="kpis">');
  void kpi(String label, String value) => b.writeln(
    '<div class="kpi"><span>${esc(label)}</span><b>${esc(value)}</b></div>',
  );
  kpi('Total clients', '${report.total}');
  kpi('New', '${report.newClients}');
  kpi('Existing', '${report.existingClients}');
  kpi('Average per day', _avg(report.dailyAverage));
  kpi('Staff who saw clients', '${report.staffWithClients}');
  if (target != null) kpi('Daily target', '$target');
  b.writeln('</div>');
  if (previous != null) {
    b.writeln(
      '<p class="sub">Compared with '
      '${esc(DateFormat('d MMM y').format(previous.from))} – '
      '${esc(DateFormat('d MMM y').format(previous.to))}: '
      'total ${esc(_change(report.total, previous.total))}, '
      'new ${esc(_change(report.newClients, previous.newClients))}, '
      'existing ${esc(_change(report.existingClients, previous.existingClients))}.'
      '</p>',
    );
  }
  final busiest = report.weekdayAverages
      .where((w) => w.days > 0)
      .fold(
        null as WeekdayAverage?,
        (WeekdayAverage? best, w) =>
            best == null || w.average > best.average ? w : best,
      );
  if (report.staff.isNotEmpty && report.staff.first.total > 0) {
    final top = report.staff.first;
    b.writeln(
      '<p class="sub">Most clients: <b>${esc(top.name)}</b> (${top.total})'
      '${busiest == null || report.days.length < 10 ? '' : ' · Busiest weekday: <b>${esc(DateFormat('EEEE').format(DateTime(2024, 1, busiest.weekday)))}</b> (${_avg(busiest.average)} a day)'}'
      '</p>',
    );
  }
  b
    ..writeln('<h2>Clients by staff</h2><table><thead><tr>')
    ..writeln(
      '<th>Staff</th><th>New</th><th>Existing</th><th>Total</th>'
      '<th>Share</th><th>Avg / day</th><th>Days off</th></tr></thead><tbody>',
    );
  for (final s in staff) {
    final muted = s.total == 0 ? ' class="muted"' : '';
    b.writeln(
      '<tr$muted><td>${esc(s.name)}</td><td>${s.newClients}</td>'
      '<td>${s.existingClients}</td><td><b>${s.total}</b></td>'
      '<td>${_pct(s.total, report.total)}</td>'
      '<td>${s.daysWorked == 0 ? '–' : _avg(s.total / s.daysWorked)}</td>'
      '<td>${s.daysOff == 0 ? '–' : s.daysOff}</td></tr>',
    );
  }
  b.writeln(
    '</tbody><tfoot><tr><td>Total</td><td>${report.newClients}</td>'
    '<td>${report.existingClients}</td><td>${report.total}</td>'
    '<td></td><td></td><td></td></tr></tfoot></table>',
  );
  if (_longRange(report)) {
    b
      ..writeln('<h2>Month by month</h2><table><thead><tr>')
      ..writeln(
        '<th>Month</th><th>New</th><th>Existing</th><th>Total</th>'
        '<th>A day</th></tr></thead><tbody>',
      );
    for (final m in report.months) {
      b.writeln(
        '<tr><td>${esc(DateFormat('MMMM y').format(m.start))}</td>'
        '<td>${m.newClients}</td><td>${m.existingClients}</td>'
        '<td><b>${m.total}</b></td><td>${_avg(m.dailyAverage)}</td></tr>',
      );
    }
    b
      ..writeln('</tbody></table>')
      ..writeln(
        '<p class="foot">Numbers for staff marked off are excluded. The daily '
        'average counts working days so far, skipping holidays.</p>',
      )
      ..writeln('<script>window.onload=function(){window.print();};</script>')
      ..writeln('</body></html>');
    return Uint8List.fromList(utf8.encode(b.toString()));
  }
  b
    ..writeln('<h2>Day by day</h2><table><thead><tr>')
    ..writeln(
      '<th>Day</th><th>New</th><th>Existing</th><th>Total</th>'
      '<th>Staff off</th><th style="text-align:left">Note</th>'
      '</tr></thead><tbody>',
    );
  for (final d in report.days) {
    b.writeln(
      '<tr><td>${esc(DateFormat('EEE d MMM').format(d.date))}</td>'
      '<td>${d.newClients}</td><td>${d.existingClients}</td>'
      '<td><b>${d.total}</b></td>'
      '<td>${d.isHoliday ? 'Holiday' : (d.offCount == 0 ? '–' : '${d.offCount}')}</td>'
      '<td class="note">${esc(d.note ?? '')}</td></tr>',
    );
  }
  b
    ..writeln('</tbody></table>')
    ..writeln(
      '<p class="foot">Numbers for staff marked off are excluded. The daily '
      'average counts working days so far, skipping holidays.</p>',
    )
    ..writeln('<script>window.onload=function(){window.print();};</script>')
    ..writeln('</body></html>');
  return Uint8List.fromList(utf8.encode(b.toString()));
}
