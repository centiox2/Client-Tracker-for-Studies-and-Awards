import 'package:flutter_test/flutter_test.dart';
import 'package:excel/excel.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/export_service.dart';
import 'package:client_tracker/services/statistics_service.dart';

void main() {
  late AppDatabase db;
  late StaffRepository staffRepo;
  late WeekRepository weekRepo;
  late ClientCountRepository countRepo;
  late StatisticsService stats;

  setUp(() {
    db = openInMemoryDatabase();
    staffRepo = StaffRepository(db);
    weekRepo = WeekRepository(db);
    countRepo = ClientCountRepository(db);
    stats = StatisticsService(countRepo);
  });

  tearDown(() => db.close());

  group('database', () {
    test('seeds the current spreadsheet staff on first open', () {
      final staff = staffRepo.getAll();
      expect(staff.length, 14);
      expect(staff.first.name, 'Beatrice');
      expect(
        staff.map((s) => s.name),
        containsAll(['Joy', 'Director/Eve', 'Cinthia']),
      );
    });

    test('export/restore roundtrip preserves all data', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      weekRepo.setShowZeros(week.id, false);
      final days = weekRepo.getDays(week.id);
      countRepo.saveCount(
        dayId: days.first.id,
        staffId: staffRepo.getActive().first.id,
        newClients: 5,
        existingClients: 3,
      );
      final before = db.exportToJson();

      final db2 = openInMemoryDatabase();
      db2.restoreFromJson(before);
      final weeks2 = WeekRepository(db2).getAllWeeks();
      expect(weeks2.length, 1);
      expect(weeks2.first.startDate, week.startDate);
      expect(weeks2.first.showZeros, isFalse);
      expect(
        ClientCountRepository(db2).weekTotals(weeks2.first.id).newClients,
        5,
      );
      db2.close();
    });
  });

  group('weeks', () {
    test('createWeekFor makes Monday–Friday and adds active staff', () {
      // Wednesday, Sep 30 2026 → week Mon 28 Sep – Fri 2 Oct.
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 30));
      expect(week.startDate.weekday, DateTime.monday);
      expect(week.startDate, DateTime(2026, 9, 28));
      expect(week.endDate, DateTime(2026, 10, 2));
      final days = weekRepo.getDays(week.id);
      expect(days.length, 5);
      expect(days.first.weekday, DateTime.monday);
      expect(days.last.weekday, DateTime.friday);
      // Every active staff has a zero row on every day.
      final day1 = countRepo.getDayWithCounts(days.first.id);
      expect(day1.rows.length, staffRepo.getActive().length);
    });

    test('rejects duplicate weeks', () {
      weekRepo.createWeekFor(DateTime(2026, 9, 28));
      expect(
        () => weekRepo.createWeekFor(DateTime(2026, 9, 29)),
        throwsStateError,
      );
    });

    test('findByDate finds a week from any of its days', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      expect(weekRepo.findByDate(DateTime(2026, 10, 1))!.id, week.id);
      expect(weekRepo.findByDate(DateTime(2026, 9, 27)), isNull);
    });

    test('deleting a week cascades to days and counts', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      weekRepo.deleteWeek(week.id);
      expect(weekRepo.getAllWeeks(), isEmpty);
      expect(db.raw.select('SELECT * FROM work_days;'), isEmpty);
      expect(db.raw.select('SELECT * FROM client_counts;'), isEmpty);
    });
  });

  group('client counts', () {
    test('values are cumulative — 3 then 5 stores 5, not 8', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final monday = weekRepo.getDays(week.id).first;
      final joy = staffRepo.getAll().firstWhere((s) => s.name == 'Joy');

      countRepo.saveCount(
        dayId: monday.id,
        staffId: joy.id,
        newClients: 3,
        existingClients: 0,
      );
      var row = countRepo.getDayWithCounts(monday.id).countFor(joy.id);
      expect(row.newClients, 3);

      countRepo.saveCount(
        dayId: monday.id,
        staffId: joy.id,
        newClients: 5,
        existingClients: 0,
      );
      row = countRepo.getDayWithCounts(monday.id).countFor(joy.id);
      expect(row.newClients, 5, reason: 'cumulative overwrite, not add');
    });
  });

  group('statistics', () {
    test('week totals derive from day rows with daily average', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final days = weekRepo.getDays(week.id);
      final joy = staffRepo.getAll().firstWhere((s) => s.name == 'Joy');
      final ian = staffRepo.getAll().firstWhere((s) => s.name == 'Ian');

      countRepo.saveCount(
        dayId: days[0].id,
        staffId: joy.id,
        newClients: 2,
        existingClients: 3,
      );
      countRepo.saveCount(
        dayId: days[0].id,
        staffId: ian.id,
        newClients: 1,
        existingClients: 0,
      );
      countRepo.saveCount(
        dayId: days[1].id,
        staffId: joy.id,
        newClients: 0,
        existingClients: 5,
      );

      final totals = stats.weekTotals(week);
      expect(totals.newClients, 3);
      expect(totals.existingClients, 8);
      expect(totals.total, 11);
      expect(totals.dailyAverage, closeTo(11 / 5, 0.001));
      expect(totals.perDay[days[0].id]!.total, 6);
      expect(totals.perDay[days[1].id]!.total, 5);
      expect(totals.perDay[days[2].id]!.total, 0);
    });

    test('staff week totals include deactivated staff history', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final days = weekRepo.getDays(week.id);
      final beatrice = staffRepo.getAll().firstWhere(
        (s) => s.name == 'Beatrice',
      );

      countRepo.saveCount(
        dayId: days[0].id,
        staffId: beatrice.id,
        newClients: 2,
        existingClients: 9,
      );

      // Beatrice leaves the company → deactivate.
      staffRepo.setActive(beatrice.id, false);

      // History still shows her numbers.
      final staffTotals = stats.staffWeekTotals(week);
      final hers = staffTotals.firstWhere((t) => t.name == 'Beatrice');
      expect(hers.total, 11);

      // New weeks exclude her…
      final week2 = weekRepo.createWeekFor(DateTime(2026, 10, 5));
      final day1 = countRepo.getDayWithCounts(
        weekRepo.getDays(week2.id).first.id,
      );
      expect(day1.rows.map((r) => r.staffName), isNot(contains('Beatrice')));
      // …but the old week still lists her with her numbers.
      final oldDay = countRepo.getDayWithCounts(days[0].id);
      expect(oldDay.rows.firstWhere((r) => r.staffId == beatrice.id).total, 11);
    });

    test('month totals aggregate from stored day data', () {
      final week1 = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final week2 = weekRepo.createWeekFor(DateTime(2026, 9, 21));
      final joy = staffRepo.getAll().firstWhere((s) => s.name == 'Joy');

      for (final w in [week1, week2]) {
        final days = weekRepo.getDays(w.id);
        countRepo.saveCount(
          dayId: days[0].id,
          staffId: joy.id,
          newClients: 1,
          existingClients: 2,
        );
      }
      // A week in October must not count towards September.
      final oct = weekRepo.createWeekFor(DateTime(2026, 10, 5));
      countRepo.saveCount(
        dayId: weekRepo.getDays(oct.id).first.id,
        staffId: joy.id,
        newClients: 100,
        existingClients: 0,
      );

      final sept = stats.monthTotals(DateTime(2026, 9, 15));
      expect(sept.newClients, 2);
      expect(sept.existingClients, 4);
      expect(sept.staffTotals.firstWhere((t) => t.name == 'Joy').total, 6);
    });
  });

  group('staff', () {
    test('add/rename/reorder', () {
      final id = staffRepo.add('New Person');
      staffRepo.rename(id, 'Renamed Person');
      var all = staffRepo.getAll();
      expect(all.last.name, 'Renamed Person');

      final order = all.map((s) => s.id).toList();
      order.insert(0, order.removeLast());
      staffRepo.reorder(order);
      expect(staffRepo.getAll().first.id, id);
    });

    test('delete removes counts; deactivate keeps them', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final monday = weekRepo.getDays(week.id).first;
      final collins = staffRepo.getAll().firstWhere((s) => s.name == 'Collins');
      countRepo.saveCount(
        dayId: monday.id,
        staffId: collins.id,
        newClients: 4,
        existingClients: 1,
      );

      staffRepo.setActive(collins.id, false);
      expect(
        countRepo.getDayWithCounts(monday.id).countFor(collins.id).newClients,
        4,
      );

      staffRepo.delete(collins.id);
      expect(
        db.raw.select('SELECT * FROM client_counts WHERE staff_id = ?;', [
          collins.id,
        ]),
        isEmpty,
      );
    });
  });

  test('batched week load matches loading each day on its own', () {
    final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
    final days = weekRepo.getDays(week.id);
    final joy = staffRepo.getAll().firstWhere((s) => s.name == 'Joy');
    final ian = staffRepo.getAll().firstWhere((s) => s.name == 'Ian');
    countRepo.saveCount(
      dayId: days[0].id,
      staffId: joy.id,
      newClients: 3,
      existingClients: 2,
    );
    countRepo.saveCount(
      dayId: days[3].id,
      staffId: ian.id,
      newClients: 0,
      existingClients: 5,
    );
    TimeOffRepository(db).setDay(dayId: days[2].id, staffId: joy.id, off: true);

    final batched = countRepo.weekDaysWithCounts(week.id);
    final single = [for (final d in days) countRepo.getDayWithCounts(d.id)];
    expect(batched.length, single.length);
    for (var i = 0; i < single.length; i++) {
      expect(batched[i].day.date, single[i].day.date);
      expect(batched[i].offStaffIds, single[i].offStaffIds);
      expect(
        batched[i].rows.map(
          (r) => (r.staffName, r.newClients, r.existingClients),
        ),
        single[i].rows.map(
          (r) => (r.staffName, r.newClients, r.existingClients),
        ),
      );
    }
    // Timestamps still read correctly although they're parsed lazily.
    expect(
      batched[0].countFor(joy.id).updatedAt.isAfter(DateTime(2020)),
      isTrue,
    );
    expect(week.createdAt.isAfter(DateTime(2020)), isTrue);
  });

  group('export', () {
    test('produces a valid xlsx from database data', () {
      final week = weekRepo.createWeekFor(DateTime(2026, 9, 28));
      final days = weekRepo.getDays(week.id);
      final joy = staffRepo.getAll().firstWhere((s) => s.name == 'Joy');
      countRepo.saveCount(
        dayId: days[0].id,
        staffId: joy.id,
        newClients: 2,
        existingClients: 4,
      );

      final service = ExportService((w) => countRepo.getWeekWithDays(w));
      final result = service.exportWeek(week);

      final bytes = result.bytes;
      // xlsx is a zip: starts with PK.
      expect(bytes.length, greaterThan(1000));
      expect(bytes[0], 0x50); // P
      expect(bytes[1], 0x4B); // K

      final workbook = Excel.decodeBytes(bytes);
      final averageRow = workbook['Weekly Clients'].rows.firstWhere(
        (row) =>
            (row.first?.value as TextCellValue?)?.value.text == 'Daily Average',
      );
      expect(averageRow[1]?.value, const DoubleCellValue(1.2));
    });
  });
}
