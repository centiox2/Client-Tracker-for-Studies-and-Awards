import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/payment_text_parser.dart';
import '../../services/photo_text.dart';
import '../../services/share_receiver.dart';
import '../../state/app_state.dart';
import 'revenue_screen.dart' show PickerBox, PurposeField;

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
  List<String> paths, {
  bool shared = false,
}) async {
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
  try {
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
    await reviewPhotoTexts(context, ref, day, results);
  } finally {
    // The photos were only shown while reviewing; never kept.
    await discardPickedPhotos();
    if (shared) await deleteSharedCopies(paths);
  }
}

/// A message's text shared into the app (Messages → Share): straight to the
/// review, as if pasted.
Future<void> reviewSharedText(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
  String text,
) async {
  if (parsePayments(text).isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No payment found in the shared text.')),
    );
    return;
  }
  await _review(context, ref, day, [_Source(name: null, text: text)]);
}

/// The review for photos already read: each payment found, beside the
/// photo it came from.
@visibleForTesting
Future<void> reviewPhotoTexts(
  BuildContext context,
  WidgetRef ref,
  DateTime day,
  List<PhotoText> results,
) => _review(context, ref, day, [
  for (final r in results)
    _Source(
      name: r.name,
      path: r.path,
      text: r.text ?? '',
      error: r.error,
      fileTime: r.fileTime,
    ),
]);

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
/// corrections (a misread digit, say) before it's checked again. With
/// [photoPath], the photo is shown beside the text to compare.
Future<String?> _textDialog(
  BuildContext context, {
  required String title,
  required String help,
  String initial = '',
  String? photoPath,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      final wide = photoPath != null && size.width >= 900;
      final field = TextField(
        key: const ValueKey('paste-message'),
        controller: controller,
        autofocus: true,
        minLines: wide ? null : 5,
        maxLines: wide ? null : 12,
        expands: wide,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          hintText:
              'UK3JPO8PVA Confirmed. on 3/11/26 at 1:38 PM '
              'Ksh45,740.00 received from …',
        ),
      );
      final helpText = Text(
        help,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Dt.textMuted(Theme.of(context))),
      );
      return AlertDialog(
        title: Text(title),
        content: wide
            ? SizedBox(
                width: math.min(1000, size.width - 120),
                height: math.min(560, size.height - 240),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _ZoomPhoto(path: photoPath)),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 380,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: field),
                          const SizedBox(height: 10),
                          helpText,
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (photoPath != null) ...[
                        SizedBox(
                          height: 220,
                          child: _ZoomPhoto(path: photoPath),
                        ),
                        const SizedBox(height: 12),
                      ],
                      field,
                      const SizedBox(height: 10),
                      helpText,
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
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Read'),
          ),
        ],
      );
    },
  );
}

/// A photo you can zoom (pinch or scroll) and drag around, to check figures.
class _ZoomPhoto extends StatelessWidget {
  const _ZoomPhoto({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Dt.rMd),
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InteractiveViewer(
        key: ValueKey(path),
        maxScale: 6,
        child: Center(child: photoView(path)),
      ),
    ),
  );
}

/// The photo full-screen (phones), zoomable.
Future<void> _showPhoto(BuildContext context, _Source s) => showDialog<void>(
  context: context,
  builder: (context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: Text(s.name ?? 'Photo', overflow: TextOverflow.ellipsis),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: photoView(s.path!)),
      ),
    ),
  ),
);

/// One photo (or a pasted text) and what was read from it.
class _Source {
  _Source({
    required this.name,
    required this.text,
    this.path,
    this.error,
    this.fileTime,
  });

  /// The photo on disk (shown while reviewing); null for pasted text.
  final String? path;

  /// The photo's file name; null for pasted text.
  final String? name;
  String text;
  final String? error;
  final DateTime? fileTime;
}

/// One payment found, with where it came from.
class _Candidate {
  _Candidate(this.payment, this.source);

  /// What was read — or, once the admin has corrected it, what they set.
  ParsedPayment payment;
  final _Source source;

  /// What it was for: the admin's choice for this one, else the batch's.
  String purpose = '';
  String? ownPurpose;

  /// The date and time the admin set; overrides anything read.
  DateTime? setTime;

  /// Corrected by hand: kept as it is when other photos' text is re-read.
  bool edited = false;

  /// The message's date, unless it can't be right (a misread year).
  DateTime? get messageTime => _plausible(payment.time);

  /// When the payment happened: as set by the admin, else the message's
  /// time, else the photo's.
  DateTime? get when => setTime ?? messageTime ?? _plausible(source.fileTime);

  /// What spots the same payment twice (see [paymentDuplicateKey]).
  String? get key => paymentDuplicateKey(payment, when);
}

/// What spots the same payment twice: the transaction code, with letter O
/// and zero treated alike (text readers mix them up). Without a code (bank
/// slips, a code cut off in the photo), the amount, day and payer — for
/// amounts of KSh 100 and up, so small round sums don't collide.
String? paymentDuplicateKey(ParsedPayment p, DateTime? when) {
  final code = p.code;
  if (code != null) return code.toUpperCase().replaceAll('O', '0');
  if (p.amountCents < 10000) return null;
  final day = when == null ? '' : '${when.year}-${when.month}-${when.day}';
  final payer = (p.payer ?? '').toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return 'amount:${p.amountCents}|$day|$payer';
}

/// The amount a reviewed payment is saved with: positive for money
/// received, negative (a refund) for money going out.
int revenueAmountFor(ParsedPayment p) =>
    p.incoming ? p.amountCents.abs() : -p.amountCents.abs();

/// The earliest date a payment message can have (M-Pesa began in 2007).
final revenueEarliestDate = DateTime(2007);

/// A date that can't be right counts as no date: in the future (a misread
/// year like "3/11/62"), or before payment messages existed. Older messages
/// — last year's, or years back — keep their own date.
DateTime? _plausible(DateTime? t) {
  if (t == null) return null;
  if (t.isAfter(DateTime.now().add(const Duration(days: 1))) ||
      t.isBefore(revenueEarliestDate)) {
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
      purposes: ref.read(revenuePurposesProvider),
      existing: (codes) =>
          ref.read(revenueRepositoryProvider).existingCodes(codes),
    ),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;

  final actions = ref.read(appActionsProvider);
  var total = 0;
  final days = <DateTime>{};
  final added = <int>[];
  for (final c in chosen) {
    final t = c.when;
    final d = t == null ? day : DateTime(t.year, t.month, t.day);
    // Money going out that the admin ticked is a refund: it comes off the
    // day's revenue (refunds are negative amounts).
    final cents = revenueAmountFor(c.payment);
    added.add(
      actions.addRevenue(
        d,
        cents,
        note: c.payment.note,
        at: t,
        purpose: c.purpose,
      ),
    );
    total += cents;
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
      // The whole batch comes back out in one tap.
      duration: const Duration(seconds: 8),
      // Flutter keeps a snackbar with an action up until it's tapped;
      // let it go away by itself.
      persist: false,
      showCloseIcon: true,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => actions.removeRevenue(added),
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
    required this.purposes,
  });
  final List<String> purposes;
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

  /// The photo shown beside the list (wide screens).
  _Source? _shown;

  /// What the ticked payments are for ('' = not set).
  String _purpose = '';

  List<_Source> get _photos => [
    for (final s in widget.sources)
      if (s.path != null) s,
  ];

  @override
  void initState() {
    super.initState();
    _rebuild();
    _shown = _items.firstOrNull?.source.path != null
        ? _items.first.source
        : _photos.firstOrNull;
  }

  /// The text each source had when it was last read.
  final _readText = <_Source, String>{};

  /// Reads any source whose text changed (not the others, so corrections
  /// made by hand stay) and works out the flags.
  void _rebuild() {
    final before = Map.of(_ticked);
    final kept = <_Candidate>[
      for (final c in _items)
        if (_readText[c.source] == c.source.text) c,
    ];
    _items
      ..clear()
      ..addAll([
        for (final s in widget.sources)
          if (_readText[s] == s.text)
            ...kept.where((c) => c.source == s)
          else
            for (final p in parsePayments(s.text)) _Candidate(p, s),
      ]);
    for (final s in widget.sources) {
      _readText[s] = s.text;
    }
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
      if (before.containsKey(c)) {
        _ticked[c] = before[c]!;
        continue;
      }
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
      photoPath: source.path,
    );
    if (fixed == null || !mounted) return;
    setState(() {
      source.text = fixed;
      _rebuild();
    });
  }

  /// Every detail of one payment as fields: amount, date, time, who paid,
  /// code, method, purpose — beside its photo.
  Future<void> _details(_Candidate c) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _DetailsDialog(
        candidate: c,
        currency: widget.currency,
        purposes: widget.purposes,
        batchPurpose: _purpose,
        fallbackDay: widget.fallbackDay,
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      _ticked[c] = true;
      _rebuild();
    });
  }

  /// "3 Nov, 1:38 PM", with the year whenever it isn't this year, so an
  /// older message's date is plain to check.
  static String _at(DateTime t) => DateFormat(
    t.year == DateTime.now().year ? 'd MMM, h:mm a' : 'd MMM y, h:mm a',
  ).format(t);

  String _whenText(_Candidate c) {
    if (c.setTime != null) return _at(c.setTime!);
    if (c.messageTime != null) return _at(c.messageTime!);
    final misread = c.payment.time != null;
    if (c.when != null) {
      return '${_at(c.when!)} (photo’s time'
          '${misread ? '; the message’s date looks misread' : ''})';
    }
    return '${DateFormat('d MMM y').format(widget.fallbackDay)} '
        '(${misread ? 'the message’s date looks misread' : 'no date found'})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final error = theme.colorScheme.error;
    final size = MediaQuery.sizeOf(context);
    // Side by side when there's room and there are photos to compare.
    final wide = size.width >= 960 && _photos.isNotEmpty;
    final chosen = [
      for (final c in _items)
        if (_ticked[c] ?? false) c,
    ];
    final total = chosen.fold<int>(0, (s, c) => s + c.payment.amountCents);
    final photos = _photos.length;
    final empty = [
      for (final s in widget.sources)
        if (!_items.any((c) => c.source == s)) s,
    ];

    final title = Text(
      _items.isEmpty
          ? 'No payments found'
          : _items.length == 1
          ? 'Payment found'
          : '${_items.length} payments found'
                '${photos > 1 ? ' in $photos photos' : ''}',
      style: theme.textTheme.headlineSmall,
    );

    Widget thumb(_Source s) => InkWell(
      onTap: () => _showPhoto(context, s),
      borderRadius: BorderRadius.circular(6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 56,
          child: photoView(s.path!, fit: BoxFit.cover),
        ),
      ),
    );

    Widget item(_Candidate c) {
      final ticked = _ticked[c] ?? false;
      return ListTile(
        key: ValueKey(c),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        selected: wide && c.source == _shown,
        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
        selectedColor: theme.colorScheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dt.rMd),
        ),
        // Wide: a tap shows this payment's photo. Narrow: a tap ticks.
        onTap: wide && c.source.path != null
            ? () => setState(() => _shown = c.source)
            : () => setState(() => _ticked[c] = !ticked),
        leading: Checkbox(
          value: ticked,
          onChanged: (v) => setState(() => _ticked[c] = v ?? false),
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
            if (c.ownPurpose != null && c.ownPurpose!.isNotEmpty)
              Text('For ${c.ownPurpose}'),
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
                'Money going out — ticked, it’s recorded as a refund '
                '(−${formatMoney(c.payment.amountCents, widget.currency)})',
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!wide && c.source.path != null) thumb(c.source),
            IconButton(
              key: ValueKey('edit-payment-${_items.indexOf(c)}'),
              tooltip: 'Check and correct the details',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _details(c),
            ),
          ],
        ),
      );
    }

    final list = <Widget>[
      for (final c in _items) item(c),
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
            selected: wide && s == _shown,
            onTap: wide && s.path != null
                ? () => setState(() => _shown = s)
                : null,
            leading: !wide && s.path != null
                ? thumb(s)
                : Icon(Icons.image_not_supported_outlined, color: muted),
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
    ];
    final purposeBox = SizedBox(
      width: 260,
      child: PurposeField(
        purposes: widget.purposes,
        value: _purpose,
        onChanged: (p) => setState(() => _purpose = p),
      ),
    );
    final hint = Text(
      wide
          ? 'Tap a payment to see its photo. Balances are ignored.'
          : 'Check the amounts against the photos. Balances are ignored.',
      style: theme.textTheme.bodySmall?.copyWith(color: muted),
    );
    final actions = [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: chosen.isEmpty
            ? null
            : () {
                for (final c in chosen) {
                  c.purpose = c.ownPurpose ?? _purpose;
                }
                Navigator.of(context).pop(chosen);
              },
        child: Text(
          chosen.length <= 1
              ? 'Add'
              : 'Add ${chosen.length} · ${formatMoney(total, widget.currency)}',
        ),
      ),
    ];

    if (!wide) {
      return AlertDialog(
        title: title,
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...list,
                const SizedBox(height: 8),
                hint,
                if (_items.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  purposeBox,
                ],
              ],
            ),
          ),
        ),
        actions: actions,
      );
    }

    // Wide: the photo on the left, what was read from it on the right.
    final shown = _shown;
    final index = shown == null ? -1 : _photos.indexOf(shown);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(1240, size.width - 48),
        height: size.height - 48,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Previous photo',
                                onPressed: index > 0
                                    ? () => setState(
                                        () => _shown = _photos[index - 1],
                                      )
                                    : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Expanded(
                                child: Text(
                                  shown == null
                                      ? ''
                                      : '${shown.name}'
                                            '${photos > 1 ? ' · photo ${index + 1} of $photos' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next photo',
                                onPressed: index >= 0 && index < photos - 1
                                    ? () => setState(
                                        () => _shown = _photos[index + 1],
                                      )
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: shown?.path == null
                                ? const SizedBox()
                                : _ZoomPhoto(path: shown!.path!),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Scroll or pinch to zoom, drag to move.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: ListView(children: list)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: hint),
                  if (_items.isNotEmpty) ...[
                    purposeBox,
                    const SizedBox(width: 12),
                  ],
                  ...actions.expand((a) => [const SizedBox(width: 8), a]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One payment's details as fields, beside its photo, so anything misread —
/// the date most of all — is set right without editing the message text.
class _DetailsDialog extends StatefulWidget {
  const _DetailsDialog({
    required this.candidate,
    required this.currency,
    required this.purposes,
    required this.batchPurpose,
    required this.fallbackDay,
  });
  final _Candidate candidate;
  final String currency;
  final List<String> purposes;
  final String batchPurpose;
  final DateTime fallbackDay;

  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  static const _methods = ['M-Pesa', 'Airtel Money', 'Bank', 'Payment'];

  late final _Candidate c = widget.candidate;
  late final _amount = TextEditingController(
    text: formatMoney(c.payment.amountCents, '').trim(),
  );
  late final _payer = TextEditingController(text: c.payment.payer ?? '');
  late final _account = TextEditingController(text: c.payment.account ?? '');
  late final _code = TextEditingController(text: c.payment.code ?? '');
  late final _text = TextEditingController(text: c.source.text);
  late String _method = _methods.contains(c.payment.method)
      ? c.payment.method
      : 'Payment';
  late bool _incoming = c.payment.incoming;
  late String _purpose = c.ownPurpose ?? widget.batchPurpose;
  late DateTime _at =
      c.when ??
      DateTime(
        widget.fallbackDay.year,
        widget.fallbackDay.month,
        widget.fallbackDay.day,
        12,
      );
  String? _error;
  int _purposeKey = 0;

  @override
  void dispose() {
    for (final t in [_amount, _payer, _account, _code, _text]) {
      t.dispose();
    }
    super.dispose();
  }

  /// Fills the fields again from the message text (after fixing it).
  void _readAgain() {
    final found = parsePayments(_text.text);
    if (found.isEmpty) {
      setState(() => _error = 'No payment found in that text.');
      return;
    }
    // The same one again when the text holds several.
    final mine = [
      for (final o in parsePayments(c.source.text))
        o.code == c.payment.code && o.amountCents == c.payment.amountCents,
    ].indexOf(true);
    final p = found[mine >= 0 && mine < found.length ? mine : 0];
    setState(() {
      _error = null;
      _amount.text = formatMoney(p.amountCents, '').trim();
      _payer.text = p.payer ?? '';
      _account.text = p.account ?? '';
      _code.text = p.code ?? '';
      _method = _methods.contains(p.method) ? p.method : 'Payment';
      _incoming = p.incoming;
      final t = _plausible(p.time);
      if (t != null) _at = t;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _at.isAfter(now) ? now : _at,
      firstDate: revenueEarliestDate,
      lastDate: now,
    );
    if (picked != null) {
      setState(
        () => _at = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _at.hour,
          _at.minute,
        ),
      );
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (picked != null) {
      setState(
        () => _at = DateTime(
          _at.year,
          _at.month,
          _at.day,
          picked.hour,
          picked.minute,
        ),
      );
    }
  }

  void _save() {
    final cents = RevenueRepository.parseAmount(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Enter the amount, e.g. 3000 or 3,000.50');
      return;
    }
    c
      ..payment = c.payment.copyWith(
        amountCents: cents,
        method: _method,
        payer: _payer.text,
        account: _account.text,
        code: _code.text.toUpperCase(),
        incoming: _incoming,
      )
      ..setTime = _at
      ..ownPurpose = _purpose
      ..edited = true;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final size = MediaQuery.sizeOf(context);
    final path = c.source.path;
    final wide = path != null && size.width >= 900;
    final messageAt = c.messageTime;

    Widget gap([double h = 12]) => SizedBox(height: h);
    // Side by side when there's room; one above the other on a phone.
    Widget pair(Widget a, Widget b) => LayoutBuilder(
      builder: (context, box) => box.maxWidth < 360
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [a, gap(), b],
            )
          : Row(
              children: [
                Expanded(child: a),
                const SizedBox(width: 10),
                Expanded(child: b),
              ],
            ),
    );
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('detail-amount'),
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: Dt.tab(theme.textTheme.titleMedium!)
              .copyWith(fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            labelText: 'Amount',
            prefixText: '${widget.currency} ',
            isDense: true,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        gap(),
        pair(
          PickerBox(
            key: const ValueKey('detail-date'),
            label: 'Date',
            value: DateFormat('EEE d MMM y').format(_at),
            icon: Icons.calendar_today_outlined,
            onTap: _pickDate,
          ),
          PickerBox(
            key: const ValueKey('detail-time'),
            label: 'Time',
            value: DateFormat('h:mm a').format(_at),
            icon: Icons.schedule,
            onTap: _pickTime,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(
            messageAt != null
                ? 'Read from the message: '
                      '${DateFormat('d MMM y, h:mm a').format(messageAt)}'
                : c.payment.time != null
                ? 'The message’s date looked misread — please check.'
                : 'No date found in the message — please check.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: messageAt != null ? muted : theme.colorScheme.error,
            ),
          ),
        ),
        gap(),
        TextField(
          key: const ValueKey('detail-payer'),
          controller: _payer,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'From (who paid)',
            isDense: true,
          ),
        ),
        gap(),
        pair(
          TextField(
            key: const ValueKey('detail-code'),
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Transaction code',
              isDense: true,
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: _method,
            isExpanded: true,
            style: theme.textTheme.bodyLarge,
            decoration: const InputDecoration(
              labelText: 'Paid by',
              isDense: true,
            ),
            items: [
              for (final m in _methods)
                DropdownMenuItem(value: m, child: Text(m)),
            ],
            onChanged: (m) => setState(() => _method = m ?? _method),
          ),
        ),
        gap(),
        TextField(
          controller: _account,
          decoration: const InputDecoration(
            labelText: 'Account (optional)',
            isDense: true,
          ),
        ),
        gap(),
        PurposeField(
          key: ValueKey('detail-purpose-$_purposeKey'),
          purposes: widget.purposes,
          value: _purpose,
          onChanged: (p) => setState(() => _purpose = p),
        ),
        gap(6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _incoming,
          onChanged: (v) => setState(() => _incoming = v),
          title: const Text('Money received'),
          subtitle: Text(
            _incoming
                ? 'Counts as revenue'
                : 'Money going out — if ticked, recorded as a refund',
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text('Message text', style: theme.textTheme.labelLarge),
          subtitle: Text(
            'Fix the text and fill the fields again from it',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          children: [
            TextField(
              key: const ValueKey('detail-text'),
              controller: _text,
              minLines: 3,
              maxLines: 8,
              style: theme.textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  _readAgain();
                  _purposeKey++;
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Read again'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );

    return AlertDialog(
      title: const Text('Payment details'),
      content: wide
          ? SizedBox(
              width: math.min(1040, size.width - 120),
              height: math.min(620, size.height - 220),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _ZoomPhoto(path: path)),
                  const SizedBox(width: 18),
                  SizedBox(
                    width: 400,
                    child: SingleChildScrollView(child: fields),
                  ),
                ],
              ),
            )
          : SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (path != null) ...[
                      SizedBox(height: 200, child: _ZoomPhoto(path: path)),
                      gap(),
                    ],
                    fields,
                  ],
                ),
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('detail-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
