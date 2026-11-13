import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/photo_text.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/panels.dart';
import 'revenue_all.dart';
import 'revenue_insights.dart';
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

enum RevenueView { day, all, insights }

class _RevenueScreenState extends ConsumerState<RevenueScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _amountFocus = FocusNode();
  String? _error;

  /// True while photos are being dragged over the page.
  bool _dragging = false;

  /// The time for the next typed transaction; null means "now".
  TimeOfDay? _time;

  /// What the next typed transaction is for ('' = not set).
  String _purpose = '';

  /// The next typed transaction is money paid back.
  bool _refund = false;

  /// Day (enter and see one day), All (every transaction, to find and fix
  /// older ones) or Insights (charts and figures).
  // Remembered on this device (Settings-free): the page reopens as left.
  late RevenueView _viewSaved = ref
      .read(uiPrefProvider)
      .pick('revenue.view', RevenueView.values, RevenueView.day);
  RevenueView get _view => _viewSaved;
  set _view(RevenueView v) {
    _viewSaved = v;
    ref.read(uiPrefProvider).set('revenue.view', v.name);
  }

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
    final t = _time ?? TimeOfDay.now();
    ref
        .read(appActionsProvider)
        .addRevenue(
          day,
          _refund ? -cents : cents,
          note: _note.text,
          at: DateTime(day.year, day.month, day.day, t.hour, t.minute),
          purpose: _purpose,
        );
    _amount.clear();
    _note.clear();
    // Back to "now" for the next one; a refund is a one-off.
    setState(() {
      _error = null;
      _time = null;
      _refund = false;
    });
    // Ready for the next one straight away.
    _amountFocus.requestFocus();
  }

  /// Search (or a payer's history, when [query] is their name); picking a
  /// result opens its day.
  Future<void> _openSearch(String query) async {
    final picked = await showRevenueSearch(context, ref, initial: query);
    if (picked == null || !mounted) return;
    ref.read(revenueDateProvider.notifier).set(picked.date);
    setState(() => _view = RevenueView.day);
  }

  void _delete(RevenueEntry entry) =>
      deleteRevenueWithUndo(context, ref, entry);

  Future<void> _pickDay(DateTime day) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: revenueEarliestDate,
      lastDate: _today(),
    );
    if (picked != null) ref.read(revenueDateProvider.notifier).set(picked);
  }

  /// The "N" shortcut: back to today's entry form, cursor in the amount.
  void _newPayment() {
    if (widget.readOnly) return;
    ref.read(revenueDateProvider.notifier).set(_today());
    setState(() => _view = RevenueView.day);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _amountFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(newPaymentRequestProvider, (_, _) => _newPayment());
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
    final monthDays = month.where((d) => d.entries > 0).length;

    final page = LayoutBuilder(
      builder: (context, viewport) {
        final phone = viewport.maxWidth < 600;
        final pad = clarityHPad(context);
        final viewSwitch = UnderlineTabs<RevenueView>(
          key: const ValueKey('revenue-view'),
          tabs: [
            (RevenueView.day, 'Day'),
            (RevenueView.all, phone ? 'All' : 'All transactions'),
            (RevenueView.insights, 'Insights'),
          ],
          selected: _view,
          onChanged: (v) => setState(() => _view = v),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('revenue-search'),
                tooltip: 'Search payments',
                onPressed: () => _openSearch(''),
                icon: const Icon(Icons.search),
              ),
              // Wide screens have "Change log" in the page header.
              if (MediaQuery.sizeOf(context).width < 920)
                IconButton(
                  key: const ValueKey('revenue-history'),
                  tooltip: 'Revenue history',
                  onPressed: () => showRevenueHistory(context, ref),
                  icon: const Icon(Icons.history),
                ),
            ],
          ),
        );
        if (_view == RevenueView.all) {
          return AllRevenue(
            readOnly: widget.readOnly,
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
            header: viewSwitch,
            onOpenDay: (d) {
              ref.read(revenueDateProvider.notifier).set(d);
              setState(() => _view = RevenueView.day);
            },
          );
        }
        if (_view == RevenueView.insights) {
          return ListView(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Dt.contentMaxWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      viewSwitch,
                      const SizedBox(height: 12),
                      RevenueInsights(phone: phone),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        final totalCard = _TotalCard(
          label: isToday
              ? 'Revenue today'
              : 'Revenue on ${DateFormat('EEEE d MMM').format(day)}',
          total: formatMoney(total, currency),
          count: entries.length,
        );
        final addPanel = widget.readOnly
            ? null
            : _AddPanel(
                phone: phone,
                currency: currency,
                amount: _amount,
                note: _note,
                amountFocus: _amountFocus,
                error: _error,
                onSubmit: () => _add(day),
                day: day,
                time: _time,
                onPickDay: () => _pickDay(day),
                onPickTime: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: _time ?? TimeOfDay.now(),
                  );
                  if (t != null) setState(() => _time = t);
                },
                onClearTime: () => setState(() => _time = null),
                purposes: ref.watch(revenuePurposesProvider),
                purpose: _purpose,
                onPurpose: (p) => setState(() => _purpose = p),
                refund: _refund,
                onRefund: (r) => setState(() => _refund = r),
                onScan: photoTextSupported
                    ? () => scanPaymentPhotos(context, ref, day)
                    : null,
                onPaste: () => pastePaymentMessage(context, ref, day),
                onChanged: () {
                  if (_error != null) setState(() => _error = null);
                },
              );
        final transactions = AppPanel(
          title: 'Transactions',
          icon: Icons.receipt_long_outlined,
          trailing: entries.isEmpty
              ? null
              : '${entries.length} · ${formatMoney(total, currency)}',
          child: entries.isEmpty
              ? PanelEmpty(
                  key: const ValueKey('revenue-day-empty'),
                  icon: Icons.receipt_long_outlined,
                  title: isToday
                      ? 'No payments yet today'
                      : 'No payments on ${DateFormat('EEEE d MMM').format(day)}',
                  message: widget.readOnly
                      ? null
                      : phone
                      ? 'Type each amount above and press Enter.'
                      : 'Type each amount above and press Enter, or drop '
                            'payment photos on this page.',
                  actions: [
                    (
                      isToday
                          ? 'See yesterday’s payments'
                          : 'See the day before',
                      () => ref
                          .read(revenueDateProvider.notifier)
                          .set(day.subtract(const Duration(days: 1))),
                    ),
                    if (!isToday)
                      (
                        'Back to today',
                        () => ref.read(revenueDateProvider.notifier).set(today),
                      ),
                    ('Find a payment', () => _openSearch('')),
                  ],
                )
              : Column(
                  children: [
                    for (final (i, e) in entries.indexed)
                      RevenueEntryRow(
                        index: i + 1,
                        entry: e,
                        currency: currency,
                        onEdit: widget.readOnly
                            ? null
                            : () => showEditRevenueDialog(context, ref, e),
                        onDelete: widget.readOnly ? null : () => _delete(e),
                        onPayer: payerOf(e.note) == null
                            ? null
                            : () => _openSearch(payerOf(e.note)!),
                      ),
                  ],
                ),
        );
        final weekPanel = AppPanel(
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
            onSelect: (d) => ref.read(revenueDateProvider.notifier).set(d),
          ),
        );
        final monthLine = Text(
          '${DateFormat('MMMM').format(day)} '
          '${isToday ? 'so far' : 'up to ${DateFormat('d MMM').format(day)}'}: '
          '${formatMoney(monthTotal, currency)}'
          '${monthDays == 0 ? '' : ' · ${formatMoney((monthTotal / monthDays / 100).round() * 100, currency)} a day on average '
                    '($monthDays ${monthDays == 1 ? 'day' : 'days'} with revenue)'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        );
        // Wide screens: entering on the left, the day's list on the right.
        final wide = viewport.maxWidth >= 1100;
        final dayBody = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        totalCard,
                        if (addPanel != null) ...[
                          const SizedBox(height: 12),
                          addPanel,
                        ],
                        const SizedBox(height: 12),
                        weekPanel,
                        const SizedBox(height: 12),
                        monthLine,
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 6, child: transactions),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  totalCard,
                  if (addPanel != null) ...[
                    const SizedBox(height: 12),
                    addPanel,
                  ],
                  const SizedBox(height: 12),
                  transactions,
                  const SizedBox(height: 12),
                  weekPanel,
                  const SizedBox(height: 12),
                  monthLine,
                ],
              );
        return ListView(
          padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? Dt.contentMaxWidth : 820,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    viewSwitch,
                    const SizedBox(height: 8),
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
                    dayBody,
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
    if (widget.readOnly || !photoDropSupported) return page;
    // Windows: drag any number of payment photos onto the page.
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final paths = [for (final f in details.files) f.path];
        importPaymentPhotos(context, ref, day, paths);
      },
      child: Stack(
        children: [
          page,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface
                        .withValues(alpha: 0.92),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(Dt.rMd),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Drop payment photos to read them',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Each payment goes on the date in its message',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
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
                      DateFormat(
                        MediaQuery.sizeOf(context).width < 600
                            ? 'EEE d MMM'
                            : 'EEEE d MMMM y',
                      ).format(day),
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
        IconButton(
          tooltip: 'Next day',
          visualDensity: VisualDensity.compact,
          onPressed: canStepForward ? () => onStep(1) : null,
          icon: const Icon(Icons.chevron_right, size: 20),
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
    required this.day,
    required this.time,
    required this.onPickDay,
    required this.onPickTime,
    required this.onClearTime,
    required this.purposes,
    required this.purpose,
    required this.onPurpose,
    required this.refund,
    required this.onRefund,
  });

  final List<String> purposes;
  final String purpose;
  final ValueChanged<String> onPurpose;
  final bool refund;
  final ValueChanged<bool> onRefund;

  /// The date the transaction goes on (the page's day).
  final DateTime day;

  /// Its time; null means "now".
  final TimeOfDay? time;
  final VoidCallback onPickDay;
  final VoidCallback onPickTime;
  final VoidCallback onClearTime;
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
    final purposeBox = PurposeField(
      key: const ValueKey('revenue-purpose'),
      purposes: purposes,
      value: purpose,
      onChanged: onPurpose,
    );
    final refundSwitch = RefundSwitch(value: refund, onChanged: onRefund);
    final dateBox = PickerBox(
      key: const ValueKey('revenue-date'),
      label: 'Date',
      // Small phones: no weekday, so the date isn't cut short.
      value: DateFormat(
        day.year != DateTime.now().year
            ? 'd MMM y'
            : MediaQuery.sizeOf(context).width < 400
            ? 'd MMM'
            : 'EEE d MMM',
      ).format(day),
      icon: Icons.calendar_today_outlined,
      onTap: onPickDay,
    );
    final timeBox = PickerBox(
      key: const ValueKey('revenue-time'),
      label: 'Time',
      value: time == null ? 'Now' : time!.format(context),
      icon: Icons.schedule,
      onTap: onPickTime,
      onClear: time == null ? null : onClearTime,
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
            label: const Text('Scan photos'),
          ),
        OutlinedButton.icon(
          key: const ValueKey('paste-payment'),
          onPressed: onPaste,
          icon: const Icon(Icons.content_paste, size: 16),
          label: Text(
            photoPasteSupported ? 'Paste message or image' : 'Paste message',
          ),
        ),
        if (photoDropSupported && onScan != null)
          Text('or drag photos onto this page, or press Ctrl+V', style: hint),
      ],
    );
    return AppPanel(
      title: 'Add a transaction',
      icon: Icons.add_card_outlined,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
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
                  Row(
                    children: [
                      Expanded(child: dateBox),
                      const SizedBox(width: 10),
                      Expanded(child: timeBox),
                    ],
                  ),
                  const SizedBox(height: 10),
                  purposeBox,
                  const SizedBox(height: 10),
                  noteField,
                  refundSwitch,
                  const SizedBox(height: 4),
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
                      Expanded(flex: 2, child: dateBox),
                      const SizedBox(width: 10),
                      Expanded(flex: 2, child: timeBox),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: purposeBox),
                      const SizedBox(width: 10),
                      Expanded(flex: 4, child: noteField),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: button,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: fromMessage),
                      refundSwitch,
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// What a payment was for: a dropdown of the purposes set in Settings,
/// plus "Not set". A purpose no longer in the list still shows.
class PurposeField extends StatelessWidget {
  const PurposeField({
    super.key,
    required this.purposes,
    required this.value,
    required this.onChanged,
  });
  final List<String> purposes;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      '',
      ...purposes,
      if (value.isNotEmpty && !purposes.contains(value)) value,
    ];
    return DropdownButtonFormField<String>(
      initialValue: value,
      // The same size as the text fields beside it.
      style: Theme.of(context).textTheme.bodyLarge,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'For', isDense: true),
      items: [
        for (final o in options)
          DropdownMenuItem(
            value: o,
            child: Text(
              o.isEmpty ? 'Not set' : o,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => onChanged(v ?? ''),
    );
  }
}

/// "Refund — money paid back": the amount is saved as negative and
/// subtracted from the totals.
class RefundSwitch extends StatelessWidget {
  const RefundSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const ValueKey('revenue-refund'),
      borderRadius: BorderRadius.circular(Dt.rMd),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
            Flexible(
              child: Text(
                'Refund (money paid back)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: value ? theme.colorScheme.error : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A date or time box: looks like the text fields beside it, opens a
/// picker when tapped. [onClear] (optional) shows a clear button.
class PickerBox extends StatelessWidget {
  const PickerBox({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.onClear,
  });
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(Dt.rMd),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        suffixIcon: onClear == null
            ? Icon(icon, size: 16)
            : IconButton(
                tooltip: 'Back to now',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: onClear,
              ),
      ),
      child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

class RevenueEntryRow extends StatelessWidget {
  const RevenueEntryRow({
    super.key,
    required this.index,
    required this.entry,
    required this.currency,
    required this.onEdit,
    required this.onDelete,
    this.onPayer,
  });

  /// Shows every payment from this entry's payer.
  final VoidCallback? onPayer;
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
                    // Phones and tablets: two lines, so the name and code
                    // aren't cut off.
                    maxLines: MediaQuery.sizeOf(context).width < 1100 ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: entry.note.isEmpty ? muted : null,
                    ),
                  ),
                  Text(
                    [
                      DateFormat('HH:mm').format(entry.createdAt),
                      if (entry.isRefund) 'Refund',
                      if (entry.purpose.isNotEmpty) entry.purpose,
                    ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: entry.isRefund ? theme.colorScheme.error : muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatMoney(entry.amountCents, currency),
              style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                fontWeight: FontWeight.w600,
                color: entry.isRefund ? theme.colorScheme.error : null,
              ),
            ),
            if (onPayer != null)
              IconButton(
                tooltip: 'All payments from this payer',
                visualDensity: VisualDensity.compact,
                onPressed: onPayer,
                icon: const Icon(Icons.person_search_outlined, size: 18),
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
        if (d.date.weekday <= 5 || d.entries > 0) d,
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
                          value: max <= 0
                              ? 0
                              : (d.totalCents / max).clamp(0.0, 1.0),
                          minHeight: 10,
                          backgroundColor: scheme.outline.withValues(
                            alpha: 0.35,
                          ),
                          color: d.date == selected
                              ? Dt.money(theme.brightness)
                              : Dt.money(theme.brightness)
                                    .withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 118,
                      child: Text(
                        d.entries == 0
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
/// Removes [entry], with an Undo card that goes away by itself.
void deleteRevenueWithUndo(
  BuildContext context,
  WidgetRef ref,
  RevenueEntry entry,
) {
  final actions = ref.read(appActionsProvider);
  final currency = ref.read(currencyProvider);
  actions.deleteRevenue(entry.id);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Removed ${formatMoney(entry.amountCents, currency)}'),
        duration: const Duration(seconds: 6),
        // Flutter keeps a card with a button up until it's tapped otherwise.
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => actions.restoreRevenue(entry),
        ),
      ),
    );
}

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
  var purpose = entry.purpose;
  var refund = entry.isRefund;
  final purposes = ref.read(revenuePurposesProvider);
  var at = entry.createdAt;
  // Older entries kept the day separately from the time they were typed.
  if (!DateUtils.isSameDay(at, entry.date)) {
    at = DateTime(
      entry.date.year,
      entry.date.month,
      entry.date.day,
      at.hour,
      at.minute,
    );
  }
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
              .updateRevenue(
                entry.id,
                amountCents: refund ? -cents : cents,
                note: note.text,
                at: at,
                purpose: purpose,
              );
          // Follow the entry if it moved to another day.
          ref.read(revenueDateProvider.notifier).set(at);
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
                Row(
                  children: [
                    Expanded(
                      child: PickerBox(
                        label: 'Date',
                        value: DateFormat('d MMM y').format(at),
                        icon: Icons.calendar_today_outlined,
                        onTap: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: at,
                            firstDate: revenueEarliestDate,
                            lastDate: DateTime.now(),
                          );
                          if (d != null) {
                            setState(
                              () => at = DateTime(
                                d.year,
                                d.month,
                                d.day,
                                at.hour,
                                at.minute,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PickerBox(
                        label: 'Time',
                        value: TimeOfDay.fromDateTime(at).format(context),
                        icon: Icons.schedule,
                        onTap: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(at),
                          );
                          if (t != null) {
                            setState(
                              () => at = DateTime(
                                at.year,
                                at.month,
                                at.day,
                                t.hour,
                                t.minute,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                PurposeField(
                  purposes: purposes,
                  value: purpose,
                  onChanged: (p) => setState(() => purpose = p),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: RefundSwitch(
                    value: refund,
                    onChanged: (r) => setState(() => refund = r),
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

/// Every change to the revenue, newest first: what was added, edited,
/// deleted or put back, from which device and when.
Future<void> showRevenueHistory(BuildContext context, WidgetRef ref) {
  final changes = ref.read(revenueRepositoryProvider).changes();
  final currency = ref.read(currencyProvider);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final muted = Dt.textMuted(theme);
      String day(DateTime d) =>
          DateFormat(d.year == DateTime.now().year ? 'd MMM' : 'd MMM y')
              .format(d);
      return AlertDialog(
        title: const Text('Revenue history'),
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        content: SizedBox(
          width: 520,
          height: 480,
          child: changes.isEmpty
              ? Center(
                  child: Text(
                    'No changes yet.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                )
              : ListView.separated(
                  itemCount: changes.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: theme.colorScheme.outline),
                  itemBuilder: (context, i) {
                    final c = changes[i];
                    final (icon, verb, color) = switch (c.action) {
                      'added' => (
                        Icons.add_circle_outline,
                        'Added',
                        Dt.statusGreen(theme.brightness),
                      ),
                      'deleted' => (
                        Icons.remove_circle_outline,
                        'Deleted',
                        theme.colorScheme.error,
                      ),
                      'restored' => (Icons.undo, 'Put back', muted),
                      _ => (Icons.edit_outlined, 'Edited', muted),
                    };
                    final what = <String>[
                      if (c.oldAmountCents != null &&
                          c.oldAmountCents != c.amountCents)
                        'from ${formatMoney(c.oldAmountCents!, currency)} '
                            'to ${formatMoney(c.amountCents, currency)}'
                      else
                        formatMoney(c.amountCents, currency),
                      if (c.oldDate != null && c.oldDate != c.date)
                        'moved from ${day(c.oldDate!)} to ${day(c.date)}'
                      else
                        'on ${day(c.date)}',
                    ];
                    final noteChanged =
                        c.oldNote != null && c.oldNote != c.note;
                    return ListTile(
                      dense: true,
                      leading: Icon(icon, color: color, size: 20),
                      title: Text('$verb · ${what.join(' · ')}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (c.note.isNotEmpty || noteChanged)
                            Text(
                              noteChanged
                                  ? 'Note was “${c.oldNote}”, now “${c.note}”'
                                  : c.note,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          Text(
                            '${DateFormat('d MMM y, HH:mm').format(c.changedAt)}'
                            '${c.device.isEmpty ? '' : ' · ${c.device}'}',
                            style: TextStyle(color: muted),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

/// The payer's name in a scanned payment's note ("M-Pesa · David Kangogo ·
/// Acc: … · CODE" → "David Kangogo"); null for notes without one.
String? payerOf(String note) {
  final parts = note.split(' · ');
  if (parts.length < 2) return null;
  const methods = {'M-Pesa', 'Airtel Money', 'Bank', 'Payment'};
  if (!methods.contains(parts[0])) return null;
  final name = parts[1].trim();
  if (name.isEmpty || name.startsWith('Acc:')) return null;
  // A transaction code, not a name.
  if (RegExp(r'^[A-Z0-9]{8,}$').hasMatch(name)) return null;
  return name;
}

/// Search every payment, on any date, by name, M-Pesa code, amount, note or
/// purpose. Shows how many match and their total — so a payer's name gives
/// their full payment history. Returns the payment picked, if any.
Future<RevenueEntry?> showRevenueSearch(
  BuildContext context,
  WidgetRef ref, {
  String initial = '',
}) => showDialog<RevenueEntry>(
  context: context,
  builder: (_) => _SearchDialog(initial: initial),
);

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog({required this.initial});
  final String initial;

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  late final _query = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dataVersionProvider);
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final currency = ref.watch(currencyProvider);
    final results = ref.read(revenueRepositoryProvider).search(_query.text);
    final total = results.fold<int>(0, (s, e) => s + e.amountCents);
    final first = results.isEmpty ? null : results.last.date;
    final last = results.isEmpty ? null : results.first.date;
    String day(DateTime d) =>
        DateFormat(d.year == DateTime.now().year ? 'd MMM' : 'd MMM y')
            .format(d);

    return AlertDialog(
      title: Text(widget.initial.isEmpty ? 'Search payments' : widget.initial),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 540,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('revenue-search-field'),
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Name, M-Pesa code, amount, purpose…',
                isDense: true,
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(_query.clear),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            if (_query.text.trim().isNotEmpty)
              Text(
                results.isEmpty
                    ? 'Nothing found.'
                    : '${results.length} '
                          '${results.length == 1 ? 'payment' : 'payments'} · '
                          '${formatMoney(total, currency)}'
                          '${first == null || first == last ? '' : ' · ${day(first)} – ${day(last!)}'}'
                          '${results.length == 200 ? ' (first 200 shown)' : ''}',
                style: theme.textTheme.labelMedium,
              ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.separated(
                itemCount: results.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: theme.colorScheme.outline),
                itemBuilder: (context, i) {
                  final e = results[i];
                  final payer = payerOf(e.note);
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    onTap: () => Navigator.of(context).pop(e),
                    title: Text(
                      e.note.isEmpty ? 'Transaction' : e.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        // The payment's own date (the time can be when it
                        // was typed, for one added to an earlier day).
                        '${DateFormat('EEE d MMM y').format(e.date)}, '
                            '${DateFormat('HH:mm').format(e.createdAt)}',
                        if (e.isRefund) 'Refund',
                        if (e.purpose.isNotEmpty) e.purpose,
                      ].join(' · '),
                      style: TextStyle(color: muted),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatMoney(e.amountCents, currency),
                          style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                            fontWeight: FontWeight.w600,
                            color: e.isRefund ? theme.colorScheme.error : null,
                          ),
                        ),
                        if (payer != null && payer != _query.text)
                          IconButton(
                            tooltip: 'All payments from $payer',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.person_search_outlined,
                              size: 18,
                            ),
                            onPressed: () =>
                                setState(() => _query.text = payer),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
