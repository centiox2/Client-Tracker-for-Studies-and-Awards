import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../repositories/revenue_repository.dart';

final _header = CellStyle(
  bold: true,
  backgroundColorHex: ExcelColor.blue,
  fontColorHex: ExcelColor.white,
);
final _total = CellStyle(bold: true, backgroundColorHex: ExcelColor.grey);

void _row(Sheet s, int r, List<Object?> cells, {CellStyle? style}) {
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

/// Amounts as numbers (in shillings, not cents) so Excel can add them up.
double _amount(int cents) => cents / 100;

/// Adds two sheets to [excel]: "Revenue" (every transaction, refunds as
/// negatives) and "Revenue by day" (each day's total), for [from]–[to].
void addRevenueSheets(
  Excel excel,
  List<RevenueEntry> entries, {
  required DateTime from,
  required DateTime to,
  required String currency,
}) {
  final tx = excel['Revenue'];
  var r = 0;
  _row(tx, r++, [
    'Date',
    'Time',
    'Amount ($currency)',
    'Type',
    'For',
    'Note',
  ], style: _header);
  for (final e in entries) {
    _row(tx, r++, [
      DateFormat('dd/MM/yyyy').format(e.date),
      DateFormat('HH:mm').format(e.createdAt),
      _amount(e.amountCents),
      e.isRefund ? 'Refund' : 'Payment',
      e.purpose,
      e.note,
    ]);
  }
  final total = entries.fold<int>(0, (s, e) => s + e.amountCents);
  _row(tx, r, [
    'Total',
    '',
    _amount(total),
    '${entries.length} transactions',
    '',
    '',
  ], style: _total);
  tx.setColumnWidth(0, 14);
  tx.setColumnWidth(2, 16);
  tx.setColumnWidth(4, 18);
  tx.setColumnWidth(5, 60);

  final byDay = excel['Revenue by day'];
  r = 0;
  _row(byDay, r++, [
    'Date',
    'Day',
    'Revenue ($currency)',
    'Payments',
  ], style: _header);
  final totals = <DateTime, (int, int)>{};
  for (final e in entries) {
    final (c, n) = totals[e.date] ?? (0, 0);
    // "Payments" counts money in; a refund lowers the revenue, not the
    // number of payments.
    totals[e.date] = (c + e.amountCents, n + (e.amountCents > 0 ? 1 : 0));
  }
  for (
    var d = DateTime(from.year, from.month, from.day);
    !d.isAfter(to);
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    final (c, n) = totals[d] ?? (0, 0);
    _row(byDay, r++, [
      DateFormat('dd/MM/yyyy').format(d),
      DateFormat('EEEE').format(d),
      _amount(c),
      n,
    ]);
  }
  _row(byDay, r, [
    'Total',
    '',
    _amount(total),
    entries.where((e) => e.amountCents > 0).length,
  ], style: _total);
  byDay.setColumnWidth(0, 14);
  byDay.setColumnWidth(1, 12);
  byDay.setColumnWidth(2, 18);
}

/// The summary lines for revenue: total, payments, refunds.
List<(String, Object)> revenueSummaryRows(
  List<RevenueEntry> entries,
  String currency,
) {
  final refunds = entries.where((e) => e.isRefund).toList();
  return [
    (
      'Revenue ($currency)',
      _amount(entries.fold<int>(0, (s, e) => s + e.amountCents)),
    ),
    ('Payments', entries.length - refunds.length),
    if (refunds.isNotEmpty)
      (
        'Refunds ($currency)',
        _amount(-refunds.fold<int>(0, (s, e) => s + e.amountCents)),
      ),
  ];
}

/// A revenue workbook for a period: Summary, Revenue, Revenue by day.
Uint8List revenueToExcel(
  List<RevenueEntry> entries, {
  required DateTime from,
  required DateTime to,
  required String currency,
  required String title,
}) {
  final excel = Excel.createExcel();
  final summary = excel['Summary'];
  excel.setDefaultSheet('Summary');
  excel.delete('Sheet1');
  var r = 0;
  _row(summary, r++, [title], style: CellStyle(bold: true, fontSize: 14));
  _row(summary, r++, ['Studies and Awards Limited · S&A Hub']);
  r++;
  for (final (label, value) in revenueSummaryRows(entries, currency)) {
    _row(summary, r++, [label, value]);
  }
  summary.setColumnWidth(0, 24);
  addRevenueSheets(excel, entries, from: from, to: to, currency: currency);
  final bytes = excel.save(fileName: 'revenue.xlsx');
  if (bytes == null) throw StateError('Excel export failed.');
  return Uint8List.fromList(bytes);
}
