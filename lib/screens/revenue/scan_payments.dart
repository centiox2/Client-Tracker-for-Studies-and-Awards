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
import 'revenue_screen.dart' show PurposeField;

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
  final ParsedPayment payment;
  final _Source source;

  /// What it was for (chosen in the review for the whole batch).
  String purpose = '';

  /// The message's date, unless it can't be right (a misread year).
  DateTime? get messageTime => _plausible(payment.time);

  /// When the payment happened: the message's time, else the photo's.
  DateTime? get when => messageTime ?? _plausible(source.fileTime);

  /// Transaction code with letter O and zero treated alike (text readers
  /// mix them up), for spotting the same payment twice.
  String? get key => payment.code?.toUpperCase().replaceAll('O', '0');
}

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
    added.add(
      actions.addRevenue(
        d,
        c.payment.amountCents,
        note: c.payment.note,
        at: t,
        purpose: c.purpose,
      ),
    );
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
      photoPath: source.path,
    );
    if (fixed == null || !mounted) return;
    setState(() {
      source.text = fixed;
      _rebuild();
    });
  }

  /// "3 Nov, 1:38 PM", with the year whenever it isn't this year, so an
  /// older message's date is plain to check.
  static String _at(DateTime t) => DateFormat(
    t.year == DateTime.now().year ? 'd MMM, h:mm a' : 'd MMM y, h:mm a',
  ).format(t);

  String _whenText(_Candidate c) {
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!wide && c.source.path != null) thumb(c.source),
            IconButton(
              tooltip: 'Edit text',
              icon: const Icon(Icons.edit_note, size: 20),
              onPressed: () => _edit(c.source),
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
                  c.purpose = _purpose;
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
