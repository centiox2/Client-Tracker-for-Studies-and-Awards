import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';
import 'revenue_screen.dart'
    show RevenueEntryRow, deleteRevenueWithUndo, payerOf, showEditRevenueDialog;
import 'scan_payments.dart' show revenueEarliestDate;

/// Every transaction, a month at a time (newest first, grouped by day), or
/// everything matching a search on any date. Tap one to change its amount,
/// date, time, purpose or note; older payments are fixed here.
class AllRevenue extends ConsumerStatefulWidget {
  const AllRevenue({
    super.key,
    required this.readOnly,
    required this.padding,
    required this.header,
    required this.onOpenDay,
  });

  final bool readOnly;
  final EdgeInsets padding;
  final Widget header;
  final ValueChanged<DateTime> onOpenDay;

  @override
  ConsumerState<AllRevenue> createState() => _AllRevenueState();
}

class _AllRevenueState extends ConsumerState<AllRevenue> {
  final _query = TextEditingController();
  late DateTime _month = _thisMonth();

  static DateTime _thisMonth() {
    final n = DateTime.now();
    return DateTime(n.year, n.month);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: revenueEarliestDate,
      lastDate: DateTime.now(),
      helpText: 'Pick any day in the month',
    );
    if (picked != null) {
      setState(() => _month = DateTime(picked.year, picked.month));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dataVersionProvider);
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final currency = ref.watch(currencyProvider);
    final repo = ref.read(revenueRepositoryProvider);
    final searching = _query.text.trim().isNotEmpty;

    final List<RevenueEntry> entries;
    if (searching) {
      entries = repo.search(_query.text, limit: 500);
    } else {
      final last = DateTime(_month.year, _month.month + 1, 0);
      entries = repo.entriesBetween(_month, last).reversed.toList();
    }
    final total = entries.fold<int>(0, (s, e) => s + e.amountCents);

    // Grouped by day, newest day first; within a day, latest first.
    final byDay = <DateTime, List<RevenueEntry>>{};
    for (final e in entries) {
      byDay.putIfAbsent(e.date, () => []).add(e);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final now = DateTime.now();
    final atThisMonth = _month == _thisMonth();

    final monthBar = Row(
      children: [
        IconButton(
          tooltip: 'Earlier month',
          onPressed: _month.isAfter(revenueEarliestDate)
              ? () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1),
                )
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: InkWell(
            key: const ValueKey('all-revenue-month'),
            onTap: _pickMonth,
            borderRadius: BorderRadius.circular(Dt.rMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                DateFormat('MMMM y').format(_month),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Later month',
          onPressed: atThisMonth
              ? null
              : () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1),
                ),
          icon: const Icon(Icons.chevron_right),
        ),
        if (!atThisMonth)
          TextButton(
            onPressed: () => setState(() => _month = _thisMonth()),
            child: const Text('This month'),
          ),
      ],
    );

    final search = TextField(
      key: const ValueKey('all-revenue-search'),
      controller: _query,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 18),
        hintText: 'Search any date: name, M-Pesa code, amount, purpose…',
        isDense: true,
        suffixIcon: searching
            ? IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => setState(_query.clear),
              )
            : null,
      ),
    );

    String dayLabel(DateTime d) =>
        DateFormat(d.year == now.year ? 'EEEE d MMM' : 'EEEE d MMM y')
            .format(d);

    final list = <Widget>[];
    for (final d in days) {
      final items = byDay[d]!
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final dayTotal = items.fold<int>(0, (s, e) => s + e.amountCents);
      list.add(
        InkWell(
          onTap: () => widget.onOpenDay(d),
          child: Container(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(dayLabel(d), style: theme.textTheme.labelLarge),
                ),
                Text(
                  '${items.length} · ${formatMoney(dayTotal, currency)}',
                  style: Dt.tab(theme.textTheme.labelMedium!)
                      .copyWith(color: muted),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: muted),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < items.length; i++) {
        final e = items[i];
        list.add(
          RevenueEntryRow(
            index: i + 1,
            entry: e,
            currency: currency,
            onEdit: widget.readOnly
                ? null
                : () => showEditRevenueDialog(context, ref, e),
            onDelete: widget.readOnly
                ? null
                : () => deleteRevenueWithUndo(context, ref, e),
            onPayer: payerOf(e.note) == null
                ? null
                : () => setState(() => _query.text = payerOf(e.note)!),
          ),
        );
      }
    }

    return ListView(
      padding: widget.padding,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.header,
                const SizedBox(height: 10),
                search,
                if (!searching) ...[const SizedBox(height: 6), monthBar],
                const SizedBox(height: 10),
                AppPanel(
                  title: searching ? 'Found' : 'Transactions',
                  icon: searching ? Icons.search : Icons.receipt_long_outlined,
                  trailing: entries.isEmpty
                      ? null
                      : '${entries.length} · ${formatMoney(total, currency)}'
                            '${searching && entries.length == 500 ? ' (first 500)' : ''}',
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            searching
                                ? 'Nothing matches that search.'
                                : 'No transactions in '
                                      '${DateFormat('MMMM y').format(_month)}.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: list,
                        ),
                ),
                if (!widget.readOnly && entries.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Tap a transaction to change it. Tap a day to open it.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
