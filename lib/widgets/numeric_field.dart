import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        LogicalKeyboardKey,
        FilteringTextInputFormatter,
        LengthLimitingTextInputFormatter;

import 'package:flutter/scheduler.dart';

import '../design/app_theme.dart';

/// A fast numeric field for cumulative client counts.
///
/// - Non-negative integers only; empty counts as 0.
/// - Content is fully selected on focus so typing replaces it instantly.
/// - Enter/Tab moves to the next field in [focusOrder] where practical.
///
/// Editorial styling hooks: [accent] tints the focus border (and adds a soft
/// glow), [valueColor] colors entered digits, [placeholder] shows in empty
/// fields (the mockups use an en dash).
class NumericField extends StatefulWidget {
  const NumericField({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.nextFocusNode,
    this.onSubmitted,
    this.width = 72,
    this.height = 30,
    this.fontSize = 13,
    this.autofocus = false,
    this.accent,
    this.valueColor,
    this.placeholder = '',
    this.showZero = false,
    this.onClear,
    this.plusOne = PlusOne.hidden,
    this.confirmEdit,
    this.dimGuarded = true,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final FocusNode? focusNode;
  final FocusNode? nextFocusNode;
  final VoidCallback? onSubmitted;
  final double width;
  final double height;
  final double fontSize;
  final bool autofocus;

  /// Focus border + glow color (defaults to the scheme primary).
  final Color? accent;

  /// Text color for the entered value (defaults to onSurface).
  final Color? valueColor;

  /// Hint shown when the field is empty (e.g. '–').
  final String placeholder;

  /// When true, a value of 0 is displayed as `0` instead of the blank
  /// placeholder. Used by the per-week "show zeros" preference.
  final bool showZero;

  /// Called when the user clears this field (Backspace on an empty field, or
  /// a dedicated Clear affordance). The caller should restore the previously
  /// committed value (via the undo buffer) rather than leaving a blank.
  final VoidCallback? onClear;

  /// A small "+" inside the field that adds one (counting clients as they
  /// arrive instead of retyping the day's running total).
  final PlusOne plusOne;

  /// Set for a guarded cell (a day in the future): the field is dimmed and
  /// read-only, and clicking it or typing a digit calls this first. When it
  /// returns true the caller unlocks the cell (rebuilding without it) and a
  /// digit that was typed is kept.
  final Future<bool> Function()? confirmEdit;

  /// Whether a guarded cell is shown faded (a day to come). A finished
  /// week's numbers stay at full strength: they're real, just settled.
  final bool dimGuarded;

  @override
  State<NumericField> createState() => _NumericFieldState();
}

/// When [NumericField] shows its "+1" button.
enum PlusOne {
  hidden,

  /// While the pointer is over the field or it's being edited (desktop).
  onHover,

  /// Always (touch screens, where there is no hover).
  always,
}

/// Turns drawn cells into real editors a few per frame, so a page with dozens
/// of cells (the weekly tracker) appears at once instead of building every
/// editor before its first frame. The whole grid is live within a few
/// frames; a cell that's pointed at or focused first goes live straight
/// away.
abstract final class _EditorQueue {
  static const _perFrame = 12;
  static final _waiting = <_NumericFieldState>[];
  static bool _scheduled = false;

  /// Cells that went live straight away in the frame being built.
  static int _builtNow = 0;

  /// Whether a new cell can be live straight away: the first dozen in a
  /// frame are (a lone field, a dialog's few); the rest of a big grid wait.
  static bool claim() {
    if (_builtNow == 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _builtNow = 0);
    }
    if (_builtNow >= _perFrame) return false;
    _builtNow++;
    return true;
  }

  static void add(_NumericFieldState cell) {
    _waiting.add(cell);
    _schedule();
  }

  static void remove(_NumericFieldState cell) => _waiting.remove(cell);

  static void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance
      ..scheduleFrameCallback((_) {
        _scheduled = false;
        for (var i = 0; i < _perFrame && _waiting.isNotEmpty; i++) {
          _waiting.removeAt(0)._goLive();
        }
        if (_waiting.isNotEmpty) _schedule();
      })
      ..scheduleFrame();
  }
}

class _NumericFieldState extends State<NumericField> {
  late final TextEditingController _controller;
  late FocusNode _focus;

  /// False while the cell is only drawn (see [_EditorQueue]).
  bool _live = false;
  bool _suppress = false;
  bool _focused = false;
  bool _hovering = false;
  bool _confirming = false;

  bool get _guarded => widget.confirmEdit != null;

  /// The most a cell can hold (as the repository and the Excel import).
  static const _max = 100000;

  /// Asks to unlock a guarded cell; [typed] is a digit to enter afterwards.
  Future<void> _requestEdit({String? typed}) async {
    if (_confirming) return;
    _confirming = true;
    try {
      final ok = await widget.confirmEdit!();
      if (!ok || !mounted) return;
      _focus.requestFocus();
      if (typed != null) {
        _suppress = true;
        _controller.text = typed;
        _controller.selection = TextSelection.collapsed(offset: typed.length);
        _suppress = false;
        widget.onChanged(int.parse(typed));
      }
    } finally {
      _confirming = false;
    }
  }

  /// "+1": shows the new value straight away (a focused field doesn't take
  /// outside updates) and saves it through the normal change path.
  void _increment() {
    // A guarded day (in the future) asks first, as typing would.
    if (_guarded) {
      _requestEdit(typed: '${widget.value + 1}');
      return;
    }
    final next = (widget.value + 1).clamp(0, _max);
    if (next == widget.value) return;
    _suppress = true;
    _controller.text = _display(next);
    _suppress = false;
    widget.onChanged(next);
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _display(widget.value));
    _focus = widget.focusNode ?? FocusNode();
    _focus.addListener(_onFocusChanged);
    if (widget.autofocus || _EditorQueue.claim()) {
      _live = true;
    } else {
      _EditorQueue.add(this);
    }
  }

  void _goLive() {
    if (_live || !mounted) return;
    _EditorQueue.remove(this);
    setState(() => _live = true);
  }

  @override
  void didUpdateWidget(covariant NumericField old) {
    super.didUpdateWidget(old);
    // A different focus node: listen to the new one, not the old (which
    // would otherwise call back into this field after it has gone).
    if (old.focusNode != widget.focusNode) {
      _focus.removeListener(_onFocusChanged);
      if (old.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _focus.addListener(_onFocusChanged);
    }
    // Refresh text when the value changes externally (e.g. refresh/reload),
    // but never while the user is editing this exact field. A show-zeros
    // preference change is different: it changes only the presentation of a
    // zero, so apply it even if this field retained focus after the toggle was
    // clicked. Otherwise focused cells can keep showing stale zeros/dashes.
    final zeroDisplayChanged =
        old.showZero != widget.showZero && widget.value == 0;
    final valueChanged =
        widget.value != int.tryParse(_controller.text.replaceAll(',', ''));
    if (zeroDisplayChanged || (!_focus.hasFocus && valueChanged)) {
      _controller.text = _display(widget.value);
    }
  }

  void _onFocusChanged() {
    // Focus can move as the field leaves the screen (a week switched, a
    // row scrolled away): nothing to redraw then.
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
    if (_focus.hasFocus) {
      // Select all so the first keystroke replaces the current value.
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    }
  }

  String _display(int v) => widget.showZero ? '$v' : (v == 0 ? '' : '$v');

  void _handleChange(String text) {
    if (_suppress) return;
    final cleaned = text.replaceAll(RegExp(r'[^0-9]'), '');
    // Never more than six digits reach int.parse, and never above the most
    // a cell may hold (a pasted phone number isn't a client count).
    final digits = cleaned.length > 6 ? cleaned.substring(0, 6) : cleaned;
    final parsed = digits.isEmpty ? 0 : int.parse(digits).clamp(0, _max);
    if (parsed != widget.value) {
      widget.onChanged(parsed);
    }
    // Keep the field showing the canonical value (strips junk chars).
    final display = _display(parsed);
    if (display != _controller.text) {
      _suppress = true;
      _controller.text = display;
      _controller.selection = TextSelection.collapsed(offset: display.length);
      _suppress = false;
    }
  }

  void _handleSubmitted() {
    widget.onSubmitted?.call();
    if (widget.nextFocusNode != null) {
      widget.nextFocusNode!.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    _EditorQueue.remove(this);
    // A focus node passed in outlives this field: stop listening to it.
    _focus.removeListener(_onFocusChanged);
    if (widget.focusNode == null) _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = widget.accent ?? scheme.primary;
    final dark = theme.brightness == Brightness.dark;

    // Quiet "well" styling: a soft fill and no outline at rest, so a grid of
    // dozens of fields reads as data rather than as a wall of boxes. The
    // accent outline appears only on the field being edited, and zeros are
    // drawn faint so the numbers that matter carry the colour.
    final rest = scheme.onSurface.withValues(alpha: dark ? 0.045 : 0.04);
    final valueColor = widget.value == 0
        ? Dt.textFaint(theme)
        : (widget.valueColor ?? scheme.onSurface);
    TextStyle digits(Color color, FontWeight weight) => Dt.tab(
      TextStyle(
        fontFamily: 'Inter',
        fontSize: widget.fontSize,
        fontWeight: weight,
        color: color,
      ),
    );

    if (!_live) {
      // Drawn like the editor at rest; pointing at it or clicking it makes
      // it the real editor at once (the click then places the cursor).
      final empty = _controller.text.isEmpty;
      final drawn = MouseRegion(
        onEnter: (_) => _goLive(),
        child: Listener(
          onPointerDown: (_) => _goLive(),
          child: SizedBox(
            width: widget.width.isFinite ? widget.width : null,
            height: widget.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: rest,
                borderRadius: BorderRadius.circular(Dt.rSm),
              ),
              child: Center(
                child: Text(
                  empty ? widget.placeholder : _controller.text,
                  maxLines: 1,
                  style: empty
                      ? digits(Dt.textFaint(theme), FontWeight.w400)
                      : digits(valueColor, FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      );
      return _guarded && widget.dimGuarded
          ? Opacity(opacity: 0.45, child: drawn)
          : drawn;
    }

    final field = Focus(
      // Keep this key-handler node separate from the TextField's node. The
      // EditableText inside TextField also installs a Focus widget for
      // `focusNode`; reusing `_focus` here attaches the same node twice in a
      // parent/child relationship and breaks the web focus tree when the
      // weekly grid mounts all of its inputs.
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      child: SizedBox(
        // Expanded cells pass infinity to mean "take the width my parent
        // gives me". Forwarding infinity as a tight SizedBox constraint
        // triggers Flutter's BoxConstraints assertion and paints the yellow
        // error stripe over every tracker field.
        width: widget.width.isFinite ? widget.width : null,
        height: widget.height,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Stack(
            children: [
              Positioned.fill(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  readOnly: _guarded,
                  onTap: _guarded ? _requestEdit : null,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  // Fill the whole box, so the "+" is centred on it.
                  expands: true,
                  maxLines: null,
                  cursorWidth: 1,
                  style: digits(valueColor, FontWeight.w600),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: _focused ? scheme.surfaceContainerLowest : rest,
                    hoverColor: scheme.onSurface.withValues(alpha: 0.05),
                    hintStyle: digits(Dt.textFaint(theme), FontWeight.w400),
                    hintText: widget.placeholder,
                    contentPadding: EdgeInsets.zero,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Dt.rSm),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Dt.rSm),
                      borderSide: BorderSide(color: accent, width: 1.5),
                    ),
                  ),
                  onChanged: _handleChange,
                  onSubmitted: (_) => _handleSubmitted(),
                ),
              ),
              if (!_guarded &&
                  (widget.plusOne == PlusOne.always ||
                      (widget.plusOne == PlusOne.onHover &&
                          (_hovering || _focused))))
                Positioned(
                  right: 2,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    // Not focusable: clicking "+" mustn't pull focus out of
                    // the field (or the Tab order) being typed in.
                    child: ExcludeFocus(
                      child: Tooltip(
                        message: 'Add one',
                        waitDuration: const Duration(milliseconds: 500),
                        child: InkWell(
                          onTap: _increment,
                          borderRadius: BorderRadius.circular(Dt.rSm),
                          child: Container(
                            width: 20,
                            height: 20,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(Dt.rSm),
                            ),
                            child: Icon(
                              Icons.add,
                              size: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return _guarded && widget.dimGuarded
        ? Opacity(opacity: 0.45, child: field)
        : field;
  }

  static final _digits = {
    for (var i = 0; i <= 9; i++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): '$i',
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + i): '$i',
    },
  };

  /// A Backspace on an already-empty field is treated as a clear gesture:
  /// the caller's [onClear] should restore the previously committed value
  /// (via the undo buffer) rather than leaving the field blank.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (_guarded && event is KeyDownEvent) {
      final digit = _digits[event.logicalKey];
      if (digit != null) {
        _requestEdit(typed: digit);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controller.text.isEmpty) {
      widget.onClear?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
