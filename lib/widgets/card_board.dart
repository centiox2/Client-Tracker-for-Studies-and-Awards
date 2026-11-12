import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../state/app_state.dart';

/// One card on a [CardBoard].
class BoardCard {
  const BoardCard(this.id, this.child, {this.column = 0});

  /// Steady name, used to remember where it was put.
  final String id;
  final Widget child;

  /// Where it starts out (0 = first column), before anyone moves it.
  final int column;
}

/// Cards in columns that can be moved anywhere: drag one (press and hold on
/// a phone or tablet) onto another card to put it there, or onto the empty
/// space under any column. Where each card sits is remembered on this
/// device, separately for each number of columns (a phone's single column
/// keeps its own order).
class CardBoard extends ConsumerStatefulWidget {
  const CardBoard({
    super.key,
    required this.boardKey,
    required this.cards,
    this.maxColumns = 3,
    this.minColumnWidth = 380,
  });

  /// Names the saved layout ("overview", "applications.quick").
  final String boardKey;
  final List<BoardCard> cards;
  final int maxColumns;
  final double minColumnWidth;

  /// Prefix of the saved layouts (Settings › Reset card order clears it).
  static const prefPrefix = 'board.';

  @override
  ConsumerState<CardBoard> createState() => _CardBoardState();
}

class _CardBoardState extends ConsumerState<CardBoard> {
  bool _dragging = false;

  String _pref(int cols) => '${CardBoard.prefPrefix}${widget.boardKey}.$cols';

  /// The saved layout: each column's card ids, top to bottom.
  List<List<String>> _layout(int cols) {
    final ids = [for (final c in widget.cards) c.id];
    final columns = List.generate(cols, (_) => <String>[]);
    final raw = ref.read(uiPrefProvider).get(_pref(cols));
    final placed = <String>{};
    if (raw != null && raw.isNotEmpty) {
      for (final (i, col) in raw.split('\u0002').indexed) {
        if (i >= cols) break;
        for (final id in col.split('\u0001')) {
          if (ids.contains(id) && placed.add(id)) columns[i].add(id);
        }
      }
    }
    // Cards not placed yet (new ones, or nothing saved): their own column.
    for (final card in widget.cards) {
      if (placed.contains(card.id)) continue;
      final col = cols == 1 ? 0 : card.column.clamp(0, cols - 1);
      columns[col].add(card.id);
    }
    if (cols == 1 && (raw == null || raw.isEmpty)) {
      // One column with nothing saved: read the default layout row by row.
      columns[0]
        ..clear()
        ..addAll(_rowOrder());
    }
    return columns;
  }

  /// The default columns read across, for one column.
  List<String> _rowOrder() {
    final cols = widget.maxColumns;
    final byCol = List.generate(cols, (_) => <String>[]);
    for (final c in widget.cards) {
      byCol[c.column.clamp(0, cols - 1)].add(c.id);
    }
    final out = <String>[];
    for (var row = 0; ; row++) {
      var any = false;
      for (final col in byCol) {
        if (row < col.length) {
          out.add(col[row]);
          any = true;
        }
      }
      if (!any) break;
    }
    return out;
  }

  void _save(int cols, List<List<String>> layout) {
    ref
        .read(uiPrefProvider)
        .set(
          _pref(cols),
          [for (final c in layout) c.join('\u0001')].join('\u0002'),
        );
  }

  /// Puts [id] into column [col] before [before] (null: at the bottom).
  void _move(int cols, String id, int col, String? before) {
    final layout = _layout(cols);
    final fromCol = layout.indexWhere((c) => c.contains(id));
    final fromIndex = fromCol < 0 ? -1 : layout[fromCol].indexOf(id);
    for (final c in layout) {
      c.remove(id);
    }
    final target = layout[col];
    var at = before == null ? target.length : target.indexOf(before);
    if (at < 0) at = target.length;
    // Dropped on a card further down its own column: it goes after it.
    if (before != null && fromCol == col) {
      final beforeIndex = layout[col].indexOf(before);
      if (fromIndex >= 0 && fromIndex <= beforeIndex) at = beforeIndex + 1;
    }
    target.insert(at.clamp(0, target.length), id);
    _save(cols, layout);
    setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(cardOrderVersionProvider);
    final c = context.clarity;
    final byId = {for (final card in widget.cards) card.id: card.child};
    final touch =
        MediaQuery.sizeOf(context).width < 1050 ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    return LayoutBuilder(
      builder: (context, box) {
        const gap = Dt.gap;
        final cols = ((box.maxWidth + gap) / (widget.minColumnWidth + gap))
            .floor()
            .clamp(1, widget.maxColumns);
        final width = (box.maxWidth - gap * (cols - 1)) / cols;
        final layout = _layout(cols);

        Widget draggable(String id) {
          final child = byId[id]!;
          final feedback = Material(
            color: Colors.transparent,
            elevation: 10,
            borderRadius: BorderRadius.circular(Dt.rMd),
            child: Opacity(
              opacity: 0.92,
              child: SizedBox(width: width, child: child),
            ),
          );
          final ghost = Opacity(opacity: 0.3, child: child);
          void start() => setState(() => _dragging = true);
          void end() => setState(() => _dragging = false);
          return touch
              ? LongPressDraggable<String>(
                  data: id,
                  feedback: feedback,
                  childWhenDragging: ghost,
                  hapticFeedbackOnStart: true,
                  onDragStarted: start,
                  onDragEnd: (_) => end(),
                  child: child,
                )
              : Draggable<String>(
                  data: id,
                  feedback: feedback,
                  childWhenDragging: ghost,
                  onDragStarted: start,
                  onDragEnd: (_) => end(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: child,
                  ),
                );
        }

        Widget slot(int col, String id) => DragTarget<String>(
          onWillAcceptWithDetails: (d) => d.data != id,
          onAcceptWithDetails: (d) => _move(cols, d.data, col, id),
          builder: (context, candidates, _) => DecoratedBox(
            key: ValueKey('board-card-$id'),
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Dt.rMd),
              border: candidates.isEmpty
                  ? null
                  : Border.all(color: c.accent, width: 2),
            ),
            child: draggable(id),
          ),
        );

        // The space under a column: drop here to put a card at its bottom.
        Widget tail(int col) => DragTarget<String>(
          onAcceptWithDetails: (d) => _move(cols, d.data, col, null),
          builder: (context, candidates, _) => AnimatedContainer(
            key: ValueKey('board-tail-$col'),
            duration: const Duration(milliseconds: 160),
            height: _dragging ? 120 : 0,
            margin: EdgeInsets.only(top: _dragging ? gap : 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Dt.rMd),
              color: candidates.isEmpty ? null : c.accentSoft,
              border: _dragging
                  ? Border.all(
                      color: candidates.isEmpty ? c.border : c.accent,
                      width: candidates.isEmpty ? 1 : 2,
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: _dragging
                ? Text(
                    'Drop here',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: c.textMuted),
                  )
                : null,
          ),
        );

        Widget column(int col) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, id) in layout[col].indexed) ...[
              if (i > 0) const SizedBox(height: gap),
              slot(col, id),
            ],
            tail(col),
          ],
        );

        if (cols == 1) return column(0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cols; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              SizedBox(width: width, child: column(i)),
            ],
          ],
        );
      },
    );
  }
}
