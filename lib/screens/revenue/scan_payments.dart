import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/payment_text_parser.dart';
import '../../services/photo_text.dart';
import '../../state/app_state.dart';

/// Image files that can be dropped or picked.
const photoExtensions = {
  'jpg',
  'jpeg',
  'png',
  'bmp',
  'gif',
  'tif',
  'tiff',
  'webp',
  'heic',
};

bool isPhotoFile(String path) =>
    photoExtensions.contains(path.split('.').last.toLowerCase());

/// Pick one or more photos of payment messages; they're read on this device
/// (phone or Windows) and every payment found is offered for adding.
Future<void> scanPaymentPhotos(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
) async {
  final paths = await pickPhotos();
  if (paths.isEmpty || !context.mounted) return;
  await importPaymentPhotos(context, ref, day, paths);
}

/// Reads [paths] (picked or dragged onto the window) and offers every
/// payment found, each timed by its message (or, without a date in the
/// message, by the photo file's time).
Future<void> importPaymentPhotos(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
  List<String> paths,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final photos = paths.where(isPhotoFile).toList();
  if (photos.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Those aren’t photos (JPG, PNG…).')),
    );
    return;
  }
  // Reading takes a moment (a few seconds per photo): show progress.
  final done = ValueNotifier(0);
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: ValueListenableBuilder<int>(
        valueListenable: done,
        builder: (_, n, _) => Row(
          children: [
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: Text(
                photos.length == 1
                    ? 'Reading the photo…'
                    : 'Reading photo ${(n + 1).clamp(1, photos.length)} '
                          'of ${photos.length}…',
              ),
            ),
          ],
        ),
      ),
    ),
  );
  List<PhotoText> results;
  try {
    results = await readPhotoTexts(photos, onProgress: (n) => done.value = n);
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  navigator.pop();
  if (!context.mounted) return;
  await _review(context, ref, day, [
    for (final r in results)
      _Source(
        name: r.name,
        text: r.text ?? '',
        error: r.error,
        fileTime: r.fileTime,
      ),
  ]);
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
        'Several messages at once are fine. You can also use Scan photos to '
        'read pictures of the messages.',
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  if (parsePayments(text).isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No payment found in that text.')),
    );
    return;
  }
  await _review(context, ref, day, [_Source(name: null, text: text)]);
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

/// One photo (or a pasted text) and what was read from it.
class _Source {
  _Source({required this.name, required this.text, this.error, this.fileTime});

  /// The photo's file name; null for pasted text.
  final String? name;
  String text;
  final String? error;
  final DateTime? fileTime;
}

/// One payment found, with where it came from.
class _Candidate {
  _Candidate(this.payment, this.source);
  final ParsedPayment payment;
  final _Source source;

  /// The message's date, unless it can't be right (a misread year).
  DateTime? get messageTime => _plausible(payment.time);

  /// When the payment happened: the message's time, else the photo's.
  DateTime? get when => messageTime ?? _plausible(source.fileTime);

  /// Transaction code with letter O and zero treated alike (text readers
  /// mix them up), for spotting the same payment twice.
  String? get key => payment.code?.toUpperCase().replaceAll('O', '0');
}

/// A date that can't be right (a misread year would file the payment in
/// 2062 or 2016, where nobody would look for it) counts as no date.
DateTime? _plausible(DateTime? t) {
  if (t == null) return null;
  final now = DateTime.now();
  if (t.isAfter(now.add(const Duration(days: 1))) ||
      t.isBefore(now.subtract(const Duration(days: 400)))) {
    return null;
  }
  return t;
}

Future<void> _review(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
  List<_Source> sources,
) async {
  final chosen = await showDialog<List<_Candidate>>(
    context: context,
    builder: (_) => _ReviewDialog(
      sources: sources,
      currency: ref.read(currencyProvider),
      fallbackDay: day,
      existing: (codes) =>
          ref.read(revenueRepositoryProvider).existingCodes(codes),
    ),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;

  final actions = ref.read(appActionsProvider);
  var total = 0;
  final days = <DateTime>{};
  for (final c in chosen) {
    final t = c.when;
    final d = t == null ? day : DateTime(t.year, t.month, t.day);
    actions.addRevenue(d, c.payment.amountCents, note: c.payment.note, at: t);
    total += c.payment.amountCents;
    days.add(d);
  }
  // Show the day the money went on (the messages' date).
  if (days.length == 1) ref.read(revenueDateProvider.notifier).set(days.first);
  final currency = ref.read(currencyProvider);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Added ${chosen.length} '
        '${chosen.length == 1 ? 'transaction' : 'transactions'} · '
        '${formatMoney(total, currency)}'
        '${days.length > 1 ? ' across ${days.length} days' : ''}',
      ),
    ),
  );
}

/// Everything found, ticked unless it's money going out, already saved, or
/// the same payment seen again in another photo (screenshots overlap).
/// Photos with nothing found are listed so their text can be fixed.
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog({
    required this.sources,
    required this.currency,
    required this.fallbackDay,
    required this.existing,
  });
  final List<_Source> sources;
  final String currency;
  final DateTime fallbackDay;
  final Set<String> Function(Iterable<String> codes) existing;

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _items = <_Candidate>[];
  final _ticked = <_Candidate, bool>{};
  final _dupeOf = <_Candidate, _Candidate>{};
  final _saved = <_Candidate>{};

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  /// Re-reads every source's text and works out the flags.
  void _rebuild() {
    final before = Map.of(_ticked);
    _items
      ..clear()
      ..addAll([
        for (final s in widget.sources)
          for (final p in parsePayments(s.text)) _Candidate(p, s),
      ]);
    // Oldest first, as they happened.
    _items.sort((a, b) {
      final ta = a.when, tb = b.when;
      if (ta == null || tb == null) return 0;
      return ta.compareTo(tb);
    });
    final saved = widget.existing([for (final c in _items) ?c.payment.code]);
    _saved
      ..clear()
      ..addAll(_items.where((c) => saved.contains(c.payment.code)));
    _dupeOf.clear();
    final firstByKey = <String, _Candidate>{};
    for (final c in _items) {
      final k = c.key;
      if (k == null) continue;
      final first = firstByKey[k];
      if (first == null) {
        firstByKey[k] = c;
      } else {
        _dupeOf[c] = first;
      }
    }
    _ticked.clear();
    for (final c in _items) {
      final fresh =
          c.payment.incoming && !_saved.contains(c) && !_dupeOf.containsKey(c);
      // Keep the admin's own choice for a payment still there after a fix.
      final kept = before.entries
          .where(
            (e) =>
                e.key.source == c.source &&
                e.key.payment.code == c.payment.code &&
                e.key.payment.amountCents == c.payment.amountCents,
          )
          .firstOrNull;
      _ticked[c] = kept?.value ?? fresh;
    }
  }

  Future<void> _edit(_Source source) async {
    final fixed = await _textDialog(
      context,
      title: source.name == null
          ? 'Payment message'
          : 'Text from ${source.name}',
      help: source.text.trim().isEmpty
          ? 'No text could be read from this photo. Type the message here, '
                'or skip it.'
          : 'Correct anything that was misread (for example the amount), '
                'then press Read.',
      initial: source.text,
    );
    if (fixed == null || !mounted) return;
    setState(() {
      source.text = fixed;
      _rebuild();
    });
  }

  String _whenText(_Candidate c) {
    final f = DateFormat('d MMM, h:mm a');
    if (c.messageTime != null) return f.format(c.messageTime!);
    final misread = c.payment.time != null;
    if (c.when != null) {
      return '${f.format(c.when!)} (photo’s time'
          '${misread ? '; the message’s date looks misread' : ''})';
    }
    return '${DateFormat('d MMM').format(widget.fallbackDay)} '
        '(${misread ? 'the message’s date looks misread' : 'no date found'})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final error = theme.colorScheme.error;
    final chosen = [
      for (final c in _items)
        if (_ticked[c] ?? false) c,
    ];
    final total = chosen.fold<int>(0, (s, c) => s + c.payment.amountCents);
    final photos = widget.sources.where((s) => s.name != null).length;
    final empty = [
      for (final s in widget.sources)
        if (!_items.any((c) => c.source == s)) s,
    ];

    return AlertDialog(
      title: Text(
        _items.isEmpty
            ? 'No payments found'
            : _items.length == 1
            ? 'Payment found'
            : '${_items.length} payments found'
                  '${photos > 1 ? ' in $photos photos' : ''}',
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in _items)
                CheckboxListTile(
                  value: _ticked[c] ?? false,
                  onChanged: (v) => setState(() => _ticked[c] = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  secondary: IconButton(
                    tooltip: 'Edit text',
                    icon: const Icon(Icons.edit_note, size: 20),
                    onPressed: () => _edit(c.source),
                  ),
                  title: Text(
                    formatMoney(c.payment.amountCents, widget.currency),
                    style: Dt.tab(theme.textTheme.titleMedium!)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_whenText(c)} · ${c.payment.method}'),
                      if (c.payment.payer != null)
                        Text(
                          'From ${c.payment.payer}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (c.payment.account != null)
                        Text(
                          'Account: ${c.payment.account}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        [?c.payment.code, ?c.source.name].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: muted),
                      ),
                      if (!c.payment.incoming)
                        Text(
                          'Money going out — not revenue',
                          style: TextStyle(color: error),
                        )
                      else if (_saved.contains(c))
                        Text('Already added', style: TextStyle(color: error))
                      else if (_dupeOf[c] case final first?)
                        Text(
                          'Same payment as above'
                          '${first.source.name != null && first.source != c.source ? ' (${first.source.name})' : ''}',
                          style: TextStyle(color: error),
                        ),
                    ],
                  ),
                ),
              if (empty.isNotEmpty) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    empty.length == 1
                        ? 'No payment found in this photo:'
                        : 'No payment found in these photos:',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                for (final s in empty)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(
                      Icons.image_not_supported_outlined,
                      color: muted,
                    ),
                    title: Text(
                      s.name ?? 'Pasted text',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      s.error ??
                          (s.text.trim().isEmpty
                              ? 'No text could be read'
                              : 'Text read, but no payment in it'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: () => _edit(s),
                      child: const Text('Edit text'),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                'Check the amounts against the photos. Balances are ignored.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: chosen.isEmpty
              ? null
              : () => Navigator.of(context).pop(chosen),
          child: Text(
            chosen.length <= 1
                ? 'Add'
                : 'Add ${chosen.length} · ${formatMoney(total, widget.currency)}',
          ),
        ),
      ],
    );
  }
}
