import '../models/staff.dart';
import '../repositories/client_count_repository.dart';

/// Facade over the repositories for all statistics. Every number is derived
/// from the underlying client-count rows at call time — the app never stores
/// calculated totals as a source of truth.
class StatisticsService {
  StatisticsService(this._counts);

  final ClientCountRepository _counts;

  WeekTotals weekTotals(Week week) => _counts.weekTotals(week.id);

  List<StaffWeekTotals> staffWeekTotals(Week week) =>
      _counts.staffWeekTotals(week.id);

  MonthTotals monthTotals(DateTime month) => _counts.monthTotals(month);

  DayTotals dayTotals(DayWithCounts day) {
    var n = 0, e = 0;
    for (final row in day.workingRows) {
      n += row.newClients;
      e += row.existingClients;
    }
    return DayTotals(newClients: n, existingClients: e);
  }
}
