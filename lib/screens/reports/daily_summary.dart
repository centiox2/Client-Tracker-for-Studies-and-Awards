part of 'reports_screen.dart';

/// A short end-of-day message for the boss, ready to paste into WhatsApp
/// or an email.
String buildDailySummary({
  required DateTime day,
  required Report today,
  required Report? sameDayLastWeek,
  required Report weekSoFar,
  required Report monthSoFar,
  int? target,
  ({int today, int todayCount, int week, int month})? revenue,
  String currency = 'KSh',
}) {
  String avg(double v) => _QuickView._avg(v);
  String plural(int n, String one, String many) => n == 1 ? one : many;
  final dayName = DateFormat('EEEE').format(day);
  final b = StringBuffer()
    ..writeln('${Dt.companyName} – client update')
    ..writeln(DateFormat('EEEE d MMMM y').format(day))
    ..writeln();

  final holiday = today.days.isNotEmpty && today.days.first.isHoliday;
  if (today.days.isEmpty) {
    b.writeln('$dayName: not tracked.');
  } else if (holiday) {
    b.writeln('$dayName: holiday – the whole team was off.');
  } else {
    b.write(
      '$dayName: ${today.total} ${plural(today.total, 'client', 'clients')} '
      '(${today.newClients} new, ${today.existingClients} existing)',
    );
    if (target != null) {
      b.write(
        today.total >= target
            ? ' – target of $target met'
            : ' – target $target',
      );
    }
    b.writeln();
    if (sameDayLastWeek != null && sameDayLastWeek.days.isNotEmpty) {
      final diff = today.total - sameDayLastWeek.total;
      b.writeln(
        diff == 0
            ? 'Same as last $dayName (${sameDayLastWeek.total})'
            : '${diff > 0 ? 'Up' : 'Down'} ${diff.abs()} on last $dayName '
                  '(${sameDayLastWeek.total})',
      );
    }
    final seen = today.staff.where((s) => s.total > 0).toList();
    if (seen.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Who saw clients:');
      for (final s in seen) {
        b.writeln(
          '• ${s.name}: ${s.total} (${s.newClients} new, '
          '${s.existingClients} existing)',
        );
      }
    }
    final notYet = today.staff
        .where((s) => s.total == 0 && s.daysOff == 0)
        .map((s) => s.name)
        .toList();
    final off = today.staff
        .where((s) => s.daysOff > 0)
        .map((s) => s.name)
        .toList();
    if (notYet.isNotEmpty) b.writeln('No clients: ${notYet.join(', ')}');
    if (off.isNotEmpty) b.writeln('Off: ${off.join(', ')}');
  }

  b
    ..writeln()
    ..writeln(
      'This week so far: ${weekSoFar.total} '
      '${plural(weekSoFar.total, 'client', 'clients')} '
      '(${avg(weekSoFar.dailyAverage)} a day)',
    )
    ..write(
      '${DateFormat('MMMM').format(day)} so far: ${monthSoFar.total} '
      '${plural(monthSoFar.total, 'client', 'clients')} '
      '(${avg(monthSoFar.dailyAverage)} a day)',
    );
  if (revenue != null) {
    b
      ..writeln()
      ..writeln()
      ..writeln(
        'Revenue $dayName: ${formatMoney(revenue.today, currency)} '
        '(${revenue.todayCount} '
        '${plural(revenue.todayCount, 'payment', 'payments')})',
      )
      ..writeln('This week: ${formatMoney(revenue.week, currency)}')
      ..write(
        '${DateFormat('MMMM').format(day)} so far: '
        '${formatMoney(revenue.month, currency)}',
      );
  }
  return b.toString();
}

/// Shows today's summary with a Copy button.
Future<void> showDailySummary(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _DailySummaryDialog(),
);

class _DailySummaryDialog extends ConsumerWidget {
  const _DailySummaryDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final day = _lastWeekday(DateTime.now());
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final lastWeek = day.subtract(const Duration(days: 7));
    final text = buildDailySummary(
      day: day,
      today: ref.watch(reportProvider((day, day))),
      sameDayLastWeek: ref.watch(reportProvider((lastWeek, lastWeek))),
      weekSoFar: ref.watch(reportProvider((monday, day))),
      monthSoFar: ref.watch(
        reportProvider((DateTime(day.year, day.month, 1), day)),
      ),
      target: ref.watch(dailyTargetProvider),
      revenue: () {
        int sum(List<RevenueDay> ds) => ds.fold(0, (s, d) => s + d.totalCents);
        final dayRevenue = ref.watch(revenueDaysProvider((day, day))).single;
        return (
          today: dayRevenue.totalCents,
          todayCount: dayRevenue.count,
          week: sum(ref.watch(revenueDaysProvider((monday, day)))),
          month: sum(
            ref.watch(
              revenueDaysProvider((DateTime(day.year, day.month, 1), day)),
            ),
          ),
        );
      }(),
      currency: ref.watch(currencyProvider),
    );
    return AlertDialog(
      title: const Text('Daily summary'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Copy this and paste it into WhatsApp, a text or an email.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border.all(color: theme.colorScheme.outline),
                  borderRadius: BorderRadius.circular(Dt.rMd),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Summary copied — paste it anywhere'),
              ),
            );
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}
