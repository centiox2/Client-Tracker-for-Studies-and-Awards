import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../models/staff.dart';
import '../repositories/client_count_repository.dart';

/// Result of a successful export: the file bytes plus a label used for
/// default file names and snackbars.
class ExportResult {
  ExportResult({required this.bytes, required this.weekLabel});

  final Uint8List bytes;
  final String weekLabel;
}

/// Exports a week to `.xlsx`, generated from database data (no template).
///
/// Layout mirrors the user's original spreadsheet: one section per weekday
/// with Staff / New / Existing columns, a per-day Total row, then the weekly
/// totals and a per-staff weekly summary.
class ExportService {
  ExportService(this.getWeekWithDays);

  /// Supplies a fully hydrated week so the service stays decoupled from the
  /// database layer (easy to unit-test with fake data).
  final WeekWithDays Function(Week week) getWeekWithDays;

  ExportResult exportWeek(Week week) {
    final data = getWeekWithDays(week);
    final excel = Excel.createExcel();

    final sheet = excel['Weekly Clients'];
    excel.setDefaultSheet('Weekly Clients');
    excel.delete('Sheet1');

    final dayFmt = DateFormat('EEEE');
    final dateFmt = DateFormat('dd/MM/yyyy');

    final titleStyle = CellStyle(bold: true, fontSize: 14);
    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.blue,
      fontColorHex: ExcelColor.white,
    );
    final sectionStyle = CellStyle(bold: true);
    final totalStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.grey,
    );
    final numberStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    var r = 0;
    void writeRow(List<Object?> cells, {CellStyle? style}) {
      for (var c = 0; c < cells.length; c++) {
        final value = cells[c];
        sheet.updateCell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
          value is int
              ? IntCellValue(value)
              : value is double
              ? DoubleCellValue(value)
              : TextCellValue('${value ?? ''}'),
          cellStyle: style,
        );
      }
      r++;
    }

    sheet.updateCell(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r),
      TextCellValue(
        'Week of ${DateFormat('MMMM d, yyyy').format(week.startDate)}',
      ),
      cellStyle: titleStyle,
    );
    r += 2;

    final dayNewTotals = <int>[];
    final dayExistingTotals = <int>[];

    for (final day in data.days) {
      writeRow([
        '${dayFmt.format(day.day.date)}  ${dateFmt.format(day.day.date)}',
      ], style: sectionStyle);
      writeRow(['Staff', 'New', 'Existing'], style: headerStyle);

      var dayNew = 0, dayExisting = 0;
      for (final row in day.rows) {
        if (day.isOff(row.staffId)) {
          // Time off: show the reason the cells are blank instead of zeros.
          writeRow([row.staffName, 'Off', 'Off'], style: numberStyle);
          continue;
        }
        writeRow([
          row.staffName,
          row.newClients,
          row.existingClients,
        ], style: numberStyle);
        dayNew += row.newClients;
        dayExisting += row.existingClients;
      }
      writeRow(['Total', dayNew, dayExisting], style: totalStyle);
      dayNewTotals.add(dayNew);
      dayExistingTotals.add(dayExisting);
      r++;
    }

    final weekNew = dayNewTotals.fold<int>(0, (a, b) => a + b);
    final weekExisting = dayExistingTotals.fold<int>(0, (a, b) => a + b);
    // A dataless week would divide by zero here (empty days list) — divide by
    // the true day count and report 0.
    final avg = data.days.isEmpty
        ? 0.0
        : (weekNew + weekExisting) / data.days.length;

    writeRow(['WEEKLY TOTALS'], style: sectionStyle);
    writeRow(['Total New clients for the week', weekNew]);
    writeRow(['Total Existing clients for the week', weekExisting]);
    writeRow(['Combined Weekly Total', weekNew + weekExisting]);
    writeRow(['Daily Average', avg]);
    r++;

    // Per-staff weekly summary (factual totals only, no ranking). Numbers
    // recorded on a time-off day are excluded; the last column shows how
    // many days of the week the staff member was off.
    final perStaff = <int, (String, int, int, int)>{};
    for (final d in data.days) {
      for (final row in d.rows) {
        final prev =
            perStaff[row.staffId] ??
            (row.staffName.isNotEmpty ? row.staffName : '', 0, 0, 0);
        final off = d.isOff(row.staffId);
        perStaff[row.staffId] = (
          row.staffName.isNotEmpty ? row.staffName : prev.$1,
          prev.$2 + (off ? 0 : row.newClients),
          prev.$3 + (off ? 0 : row.existingClients),
          prev.$4 + (off ? 1 : 0),
        );
      }
    }
    writeRow([
      'Staff',
      'New',
      'Existing',
      'Total',
      'Days off',
    ], style: headerStyle);
    final ids = perStaff.keys.toList()..sort();
    for (final id in ids) {
      final (name, n, e, off) = perStaff[id]!;
      writeRow([name, n, e, n + e, off], style: numberStyle);
    }
    writeRow([
      'Total',
      weekNew,
      weekExisting,
      weekNew + weekExisting,
      '',
    ], style: totalStyle);

    final bytes = excel.save(fileName: 'weekly.xlsx');
    if (bytes == null) {
      throw StateError('Excel export failed to produce a file.');
    }

    return ExportResult(
      bytes: Uint8List.fromList(bytes),
      weekLabel: dateFmt.format(week.startDate),
    );
  }
}
