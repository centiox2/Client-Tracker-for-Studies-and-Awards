import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/photo_text.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';
import 'scan_payments.dart';

/// Revenue for one day: the admin types in each transaction (e.g. from the
/// WhatsApp payment photos) and the day's total adds itself up. Below: every
/// transaction of the day, and the week day by day.
///
/// [readOnly] (the boss's view): the same figures, without adding or editing.
class RevenueScreen extends ConsumerStatefulWidget {
  const RevenueScreen({super.key, this.readOnly = false});
  final bool readOnly;

  @override
  ConsumerState<RevenueScreen> createState() => _RevenueScreenState();
}

class _RevenueScreenState extends ConsumerState<RevenueScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _amountFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _add(DateTime day) {
    final cents = RevenueRepository.parseAmount(_amount.text);
    if (cents == null) {
      setState(() => _error = 'Enter an amount, e.g. 1500 or 1,500.50');
      _amountFocus.requestFocus();
      return;
    }
    ref.read(appActionsProvider).addRevenue(day, cents, note: _note.text);
    _amount.clear();
    _note.clear();
    setState(() => _error = null);
    // Ready for the next one straight away.
    _amountFocus.requestFocus();
  }

  void _delete(RevenueEntry entry) {
    final actions = ref.read(appActionsProvider);
    final currency = ref.read(currencyProvider);
    actions.deleteRevenue(entry.id);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed ${formatMoney(entry.amountCents, currency)}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => actions.restoreRevenue(entry),
          ),
        ),
      );
  }

  Future<void> _pickDay(DateTime day) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2020),
      lastDate: _today(),
    );
    if (picked != null) ref.read(revenueDateProvider.notifier).set(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = ref.watch(revenueDateProvider);
    final today = _today();
    final isToday = day == today;
    final entries = ref.watch(revenueEntriesProvider(day));
    final currency = ref.watch(currencyProvider);
    final total = entries.fold<int>(0, (s, e) => s + e.amountCents);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final week = ref.watch(
      revenueDaysProvider((monday, monday.add(const Duration(days: 6)))),
    );
    final month = ref.watch(
      revenueDaysProvider((DateTime(day.year, day.month, 1), day)),
    );
    final monthTotal = month.fold<int>(0, (s, d) => s + d.totalCents);
    final monthDays = month.where((d) => d.count > 0).length;

    return LayoutBuilder(
      builder: (context, viewport) {
        final phone = viewport.maxWidth < 600;
        final pad = phone ? 14.0 : 18.0;
        return ListView(
          padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DayNavigator(
                      day: day,
                      isToday: isToday,
                      onStep: (n) => ref
                          .read(revenueDateProvider.notifier)
                          .set(day.add(Duration(days: n))),
                      canStepForward: day.isBefore(today),
                      onPick: () => _pickDay(day),
                      onToday: () =>
                          ref.read(revenueDateProvider.notifier).set(today),
                    ),
                    const SizedBox(height: 12),
                    _TotalCard(
                      label: isToday
                          ? 'Revenue today'
                          : 'Revenue on ${DateFormat('EEEE d MMM').format(day)}',
                      total: formatMoney(total, currency),
                      count: entries.length,
                    ),
                    if (!widget.readOnly) ...[
                      const SizedBox(height: 12),
                      _AddPanel(
                        phone: phone,
                        currency: currency,
                        amount: _amount,
                        note: _note,
                        amountFocus: _amountFocus,
                        error: _error,
                        onSubmit: () => _add(day),
                        onScan: photoTextSupported
                            ? () => scanPaymentPhoto(context, ref, day)
                            : null,
                        onPaste: () => pastePaymentMessage(context, ref, day),
                        onChanged: () {
                          if (_error != null) setState(() => _error = null);
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    AppPanel(
                      title: 'Transactions',
                      icon: Icons.receipt_long_outlined,
                      trailing: entries.isEmpty
                          ? null
                          : '${entries.length} · ${formatMoney(total, currency)}',
                      child: entries.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                widget.readOnly
                                    ? 'No revenue recorded for this day.'
                                    : 'Nothing yet. Type each amount above '
                                          'and press Enter.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Dt.textMuted(theme),
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                for (final (i, e) in entries.indexed)
                                  _EntryRow(
                                    index: i + 1,
                                    entry: e,
                                    currency: currency,
                                    onEdit: widget.readOnly
                                        ? null
                                        : () => showEditRevenueDialog(
                                            context,
                                            ref,
                                            e,
                                          ),
                                    onDelete: widget.readOnly
                                        ? null
                                        : () => _delete(e),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    AppPanel(
                      title: 'Week of ${DateFormat('d MMM').format(monday)}',
                      icon: Icons.bar_chart,
                      trailing: formatMoney(
                        week.fold<int>(0, (s, d) => s + d.totalCents),
                        currency,
                      ),
                      child: _WeekBars(
                        days: week,
                        selected: day,
                        today: today,
                        currency: currency,
                        onSelect: (d) =>
                            ref.read(revenueDateProvider.notifier).set(d),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${DateFormat('MMMM').format(day)} '
                      '${isToday ? 'so far' : 'up to ${DateFormat('d MMM').format(day)}'}: '
                      '${formatMoney(monthTotal, currency)}'
                      '${monthDays == 0 ? '' : ' · ${formatMoney(monthTotal ~/ monthDays, currency)} a day on average '
                                '($monthDays ${monthDays == 1 ? 'day' : 'days'} with revenue)'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Dt.textMuted(theme),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DayNavigator extends StatelessWidget {
  const _DayNavigator({
    required this.day,
    required this.isToday,
    required this.onStep,
    required this.canStepForward,
    required this.onPick,
    required this.onToday,
  });
  final DateTime day;
  final bool isToday;
  final ValueChanged<int> onStep;
  final bool canStepForward;
  final VoidCallback onPick;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          visualDensity: VisualDensity.compact,
          onPressed: () => onStep(-1),
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        IconButton(
          tooltip: 'Next day',
          visualDensity: VisualDensity.compact,
          onPressed: canStepForward ? () => onStep(1) : null,
          icon: const Icon(Icons.chevron_right, size: 20),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(Dt.rMd),
            onTap: onPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      DateFormat('EEEE d MMMM y').format(day),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.calendar_today_outlined, size: 14),
                ],
              ),
            ),
          ),
        ),
        if (!isToday) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onToday, child: const Text('Today')),
        ],
      ],
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.label,
    required this.total,
    required this.count,
  });
  final String label;
  final String total;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              total,
              maxLines: 1,
              style: Dt.tab(theme.textTheme.headlineMedium!)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            count == 0
                ? 'No transactions'
                : '$count ${count == 1 ? 'transaction' : 'transactions'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPanel extends StatelessWidget {
  const _AddPanel({
    required this.phone,
    required this.currency,
    required this.amount,
    required this.note,
    required this.amountFocus,
    required this.error,
    required this.onSubmit,
    required this.onChanged,
    required this.onScan,
    required this.onPaste,
  });
  final bool phone;
  final String currency;
  final TextEditingController amount;
  final TextEditingController note;
  final FocusNode amountFocus;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback onChanged;

  /// Read a photo of the payment message; null where not available.
  final VoidCallback? onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final amountField = TextField(
      key: const ValueKey('revenue-amount'),
      controller: amount,
      focusNode: amountFocus,
      autofocus: !phone,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => onSubmit(),
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: 'Amount',
        prefixText: '$currency ',
        errorText: error,
        isDense: true,
      ),
    );
    final noteField = TextField(
      key: const ValueKey('revenue-note'),
      controller: note,
      maxLength: RevenueRepository.maxNoteLength,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => onSubmit(),
      decoration: const InputDecoration(
        labelText: 'Note (optional)',
        hintText: 'e.g. M-Pesa, client name',
        counterText: '',
        isDense: true,
      ),
    );
    final button = FilledButton.icon(
      onPressed: onSubmit,
      icon: const Icon(Icons.add, size: 16),
      label: const Text('Add'),
    );
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final fromMessage = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onScan != null)
          OutlinedButton.icon(
            key: const ValueKey('scan-photo'),
            onPressed: onScan,
            icon: const Icon(Icons.document_scanner_outlined, size: 16),
            label: const Text('Scan photo'),
          ),
        OutlinedButton.icon(
          key: const ValueKey('paste-payment'),
          onPressed: onPaste,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Paste message'),
        ),
      ],
    );
    return AppPanel(
      title: 'Add a transaction',
      icon: Icons.add_card_outlined,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: phone
            // On a phone, reading the message comes first: it's the quick way.
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fromMessage,
                  const SizedBox(height: 12),
                  Text('Or type it in', style: hint),
                  const SizedBox(height: 8),
                  amountField,
                  const SizedBox(height: 10),
                  noteField,
                  const SizedBox(height: 10),
                  button,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: amountField),
                      const SizedBox(width: 10),
                      Expanded(flex: 3, child: noteField),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: button,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  fromMessage,
                ],
              ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.index,
    required this.entry,
    required this.currency,
    required this.onEdit,
    required this.onDelete,
  });
  final int index;
  final RevenueEntry entry;
  final String currency;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    return InkWell(
      onTap: onEdit,
      child: Container(
        padding: EdgeInsets.fromLTRB(14, 10, onDelete == null ? 14 : 4, 10),
        decoration: BoxDecoration(
          border: Border(
            top: index == 1
                ? BorderSide.none
                : BorderSide(color: theme.colorScheme.outline),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$index',
                style: Dt.tab(theme.textTheme.labelSmall!)
                    .copyWith(color: muted),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.note.isEmpty ? 'Transaction' : entry.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: entry.note.isEmpty ? muted : null,
                    ),
                  ),
                  Text(
                    'Added ${DateFormat('HH:mm').format(entry.createdAt)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatMoney(entry.amountCents, currency),
              style: Dt.tab(theme.textTheme.bodyMedium!)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            if (onDelete != null)
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Monday to Sunday, one bar per day; tap a day to open it. The weekend
/// shows only when money came in then.
class _WeekBars extends StatelessWidget {
  const _WeekBars({
    required this.days,
    required this.selected,
    required this.today,
    required this.currency,
    required this.onSelect,
  });
  final List<RevenueDay> days;
  final DateTime selected;
  final DateTime today;
  final String currency;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = [
      for (final d in days)
        if (d.date.weekday <= 5 || d.count > 0) d,
    ];
    final max = shown.fold<int>(
      0,
      (m, d) => d.totalCents > m ? d.totalCents : m,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final d in shown)
            InkWell(
              onTap: d.date.isAfter(today) ? null : () => onSelect(d.date),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        DateFormat('EEE').format(d.date),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: d.date == selected
                              ? FontWeight.w700
                              : null,
                          color: d.date.isAfter(today)
                              ? Dt.textMuted(theme)
                              : null,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: max == 0 ? 0 : d.totalCents / max,
                          minHeight: 10,
                          backgroundColor: scheme.outline.withValues(
                            alpha: 0.35,
                          ),
                          color: d.date == selected
                              ? scheme.primary
                              : scheme.primary.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 118,
                      child: Text(
                        d.count == 0
                            ? '–'
                            : formatMoney(d.totalCents, currency),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Dt.tab(theme.textTheme.bodySmall!).copyWith(
                          fontWeight: d.date == selected
                              ? FontWeight.w700
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Changes the amount or note of one transaction.
Future<void> showEditRevenueDialog(
  BuildContext context,
  WidgetRef ref,
  RevenueEntry entry,
) async {
  final currency = ref.read(currencyProvider);
  final amount = TextEditingController(
    text: formatMoney(entry.amountCents, '').trim(),
  );
  final note = TextEditingController(text: entry.note);
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void save() {
          final cents = RevenueRepository.parseAmount(amount.text);
          if (cents == null) {
            setState(() => error = 'Enter an amount, e.g. 1500');
            return;
          }
          ref
              .read(appActionsProvider)
              .updateRevenue(entry.id, amountCents: cents, note: note.text);
          Navigator.of(context).pop();
        }

        return AlertDialog(
          title: const Text('Edit transaction'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onSubmitted: (_) => save(),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '$currency ',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLength: RevenueRepository.maxNoteLength,
                  onSubmitted: (_) => save(),
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: save, child: const Text('Save')),
          ],
        );
      },
    ),
  );
  // The controllers are left to the garbage collector: the dialog's closing
  // animation still uses them after showDialog returns.
}
