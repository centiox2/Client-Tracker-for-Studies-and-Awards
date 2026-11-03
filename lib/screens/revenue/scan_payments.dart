import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/payment_text_parser.dart';
import '../../services/photo_text.dart';
import '../../state/app_state.dart';

/// Pick a photo of the payment message(s); the text is read on this device
/// (phone or Windows) and each payment found is offered for adding.
Future<void> scanPaymentPhoto(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final path = await pickPhoto();
  if (path == null || !context.mounted) return;
  // Reading takes a moment (a few seconds on Windows): say so.
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Text('Reading the photo…'),
        ],
      ),
    ),
  );
  String text;
  try {
    text = await readPhotoText(path);
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  navigator.pop();
  if (!context.mounted) return;
  await _review(context, ref, text, day, fromPhoto: true);
}

/// Any device: paste the message text (from SMS, WhatsApp, or text copied
/// out of a photo) and each payment found is offered for adding.
Future<void> pastePaymentMessage(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
) async {
  final text = await _textDialog(
    context,
    title: 'Paste payment message',
    help:
        'Several messages at once are fine. You can also use Scan photo to '
        'read a picture of the message.',
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  await _review(context, ref, text, day, fromPhoto: false);
}

/// The message text, editable: pasted, or read from a photo and open for
/// corrections (a misread digit, say) before it's checked again.
Future<String?> _textDialog(
  BuildContext context, {
  required String title,
  required String help,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('paste-message'),
              controller: controller,
              autofocus: true,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText:
                    'UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM '
                    'Ksh45,740.00 received from …',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              help,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Dt.textMuted(Theme.of(context))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Read'),
        ),
      ],
    ),
  );
}

/// Returned by the review dialog when the admin wants to fix the text.
const _editText = <ParsedPayment>[];

Future<void> _review(
  BuildContext context,
  WidgetRef ref,
  String text,
  DateTime day, {
  required bool fromPhoto,
}) async {
  var current = text;
  while (true) {
    final found = parsePayments(current);
    if (found.isEmpty) {
      if (!fromPhoto) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No payment found in that text.')),
        );
        return;
      }
      // From a photo: show what was read so it can be corrected.
      final fixed = await _textDialog(
        context,
        title: 'No payment recognised',
        help: current.trim().isEmpty
            ? 'No text could be read from that photo. Try a sharper, '
                  'straight-on photo, or type the message here.'
            : 'This is the text read from the photo. Correct it (for '
                  'example the amount) and press Read.',
        initial: current,
      );
      if (fixed == null || fixed.trim().isEmpty || !context.mounted) return;
      current = fixed;
      continue;
    }
    final codes = [for (final p in found) ?p.code];
    final already = ref.read(revenueRepositoryProvider).existingCodes(codes);
    final chosen = await showDialog<List<ParsedPayment>>(
      context: context,
      builder: (_) => _ReviewDialog(
        found: found,
        already: already,
        currency: ref.read(currencyProvider),
        fallbackDay: day,
        canEditText: true,
      ),
    );
    if (!context.mounted || chosen == null) return;
    if (identical(chosen, _editText)) {
      final fixed = await _textDialog(
        context,
        title: fromPhoto ? 'Text from the photo' : 'Payment message',
        help: 'Correct anything that was misread, then press Read.',
        initial: current,
      );
      if (fixed == null || fixed.trim().isEmpty || !context.mounted) return;
      current = fixed;
      continue;
    }
    if (chosen.isEmpty) return;
    _addChosen(context, ref, chosen, day);
    return;
  }
}

/// The message's date, unless it can't be right (a misread year would file
/// the payment in 2062 or 2016, where nobody would look for it).
DateTime? _plausible(DateTime? t) {
  if (t == null) return null;
  final now = DateTime.now();
  if (t.isAfter(now.add(const Duration(days: 1))) ||
      t.isBefore(now.subtract(const Duration(days: 400)))) {
    return null;
  }
  return t;
}

void _addChosen(
  BuildContext context,
  WidgetRef ref,
  List<ParsedPayment> chosen,
  DateTime day,
) {
  final actions = ref.read(appActionsProvider);
  var total = 0;
  final days = <DateTime>{};
  for (final p in chosen) {
    final t = _plausible(p.time);
    final d = t == null ? day : DateTime(t.year, t.month, t.day);
    actions.addRevenue(d, p.amountCents, note: p.note);
    total += p.amountCents;
    days.add(d);
  }
  // Show the day the money was added to (the message's date).
  if (days.length == 1) ref.read(revenueDateProvider.notifier).set(days.first);
  final currency = ref.read(currencyProvider);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Added ${chosen.length} '
        '${chosen.length == 1 ? 'transaction' : 'transactions'} · '
        '${formatMoney(total, currency)}',
      ),
    ),
  );
}

/// Shows what was read; the admin ticks what to add. Money going out and
/// codes already saved start unticked.
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog({
    required this.found,
    required this.already,
    required this.currency,
    required this.fallbackDay,
    this.canEditText = false,
  });
  final bool canEditText;
  final List<ParsedPayment> found;
  final Set<String> already;
  final String currency;
  final DateTime fallbackDay;

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  late final List<bool> _ticked = [
    for (final p in widget.found)
      p.incoming && !widget.already.contains(p.code),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final count = _ticked.where((t) => t).length;
    return AlertDialog(
      title: Text(
        widget.found.length == 1
            ? 'Payment found'
            : '${widget.found.length} payments found',
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, p) in widget.found.indexed)
                CheckboxListTile(
                  value: _ticked[i],
                  onChanged: (v) => setState(() => _ticked[i] = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(
                    formatMoney(p.amountCents, widget.currency),
                    style: Dt.tab(theme.textTheme.titleMedium!)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          p.time == null
                              ? '${DateFormat('d MMM').format(widget.fallbackDay)} (no date in message)'
                              : _plausible(p.time) == null
                              ? '${DateFormat('d MMM').format(widget.fallbackDay)} '
                                    '(message says ${DateFormat('d MMM y').format(p.time!)} — looks misread)'
                              : DateFormat('d MMM, h:mm a').format(p.time!),
                          p.method,
                        ].join(' · '),
                      ),
                      if (p.payer != null)
                        Text(
                          'From ${p.payer}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (p.account != null)
                        Text(
                          'Account: ${p.account}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (p.code != null)
                        Text(p.code!, style: TextStyle(color: muted)),
                      if (!p.incoming)
                        Text(
                          'Money going out — not revenue',
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      else if (widget.already.contains(p.code))
                        Text(
                          'Already added',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Check the amounts against the photo. Balances are ignored.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canEditText)
          TextButton(
            onPressed: () => Navigator.of(context).pop(_editText),
            child: const Text('Edit text'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: count == 0
              ? null
              : () => Navigator.of(context).pop([
                  for (final (i, p) in widget.found.indexed)
                    if (_ticked[i]) p,
                ]),
          child: Text(count <= 1 ? 'Add' : 'Add $count'),
        ),
      ],
    );
  }
}
