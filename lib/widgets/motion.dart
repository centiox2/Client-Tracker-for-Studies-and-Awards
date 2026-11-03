import 'package:flutter/material.dart';

/// The app's motion: short, quiet and purposeful. Everything here turns off
/// when the device asks for reduced motion.
abstract final class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 650);

  static const curve = Curves.easeOutCubic;

  /// [d], or zero when the user has asked for less motion.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// Cross-fades (with a slight rise) between pages or views. Give each child
/// a distinct key.
class FadeThroughSwitcher extends StatelessWidget {
  const FadeThroughSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, Motion.medium),
    switchInCurve: Motion.curve,
    switchOutCurve: Curves.easeIn,
    // Only the incoming page lays out; the old one just fades on top.
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.topCenter,
      children: [
        for (final p in previous) IgnorePointer(child: p),
        ?current,
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.012),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: child,
  );
}

/// Fades and rises into place the first time it's built — panels and tiles
/// arriving on screen. [index] staggers a group.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    final delay = (index.clamp(0, 8) * 0.06);
    final duration = Motion.of(context, const Duration(milliseconds: 420));
    if (duration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Interval(delay / (1 + delay), 1, curve: Motion.curve),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

/// A number that counts to its value: up from zero when it first appears,
/// then from the old value to the new one when it changes. Text that isn't a
/// plain number ("26.3" counts too; "Tuesday" or "–") fades instead.
class AnimatedValueText extends StatelessWidget {
  const AnimatedValueText(
    this.value, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String value;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  static final _number = RegExp(r'^-?\d+(\.\d+)?$');

  @override
  Widget build(BuildContext context) {
    Text text(String s) => Text(
      s,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
    final duration = Motion.of(context, Motion.slow);
    if (!_number.hasMatch(value) || duration == Duration.zero) {
      return AnimatedSwitcher(
        duration: Motion.of(context, Motion.fast),
        child: KeyedSubtree(key: ValueKey(value), child: text(value)),
      );
    }
    final decimals = value.contains('.') ? value.split('.').last.length : 0;
    final target = double.parse(value);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: duration,
      curve: Motion.curve,
      builder: (context, v, _) =>
          // The final frame shows the exact text it was given.
          text(v == target ? value : v.toStringAsFixed(decimals)),
    );
  }
}

/// Grows its child in from one edge when first built — chart bars rising
/// from the axis. [index] staggers bars left to right.
class GrowIn extends StatelessWidget {
  const GrowIn({
    super.key,
    required this.child,
    this.index = 0,
    this.axis = Axis.vertical,
  });

  final Widget child;
  final int index;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final duration = Motion.of(context, Motion.slow);
    if (duration == Duration.zero) return child;
    final delay = index.clamp(0, 20) * 0.035;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Interval(delay / (1 + delay), 1, curve: Motion.curve),
      child: child,
      builder: (context, t, child) => Transform.scale(
        scaleX: axis == Axis.horizontal ? t : 1,
        scaleY: axis == Axis.vertical ? t : 1,
        alignment: axis == Axis.vertical
            ? Alignment.bottomCenter
            : Alignment.centerLeft,
        child: child,
      ),
    );
  }
}

/// A filled share of a track (progress and share bars) that slides to its
/// new length when the value changes.
class AnimatedFraction extends StatelessWidget {
  const AnimatedFraction({
    super.key,
    required this.fraction,
    required this.color,
  });

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
    duration: Motion.of(context, Motion.slow),
    curve: Motion.curve,
    builder: (context, f, _) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: f,
      child: Container(color: color),
    ),
  );
}

/// The "Live" dot: sends out a ring each time [pingKey] changes (a new
/// update arrived), so the boss sees when numbers move.
class LiveDot extends StatefulWidget {
  const LiveDot({super.key, required this.color, this.size = 8, this.pingKey});

  final Color color;
  final double size;
  final Object? pingKey;

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didUpdateWidget(covariant LiveDot old) {
    super.didUpdateWidget(old);
    if (old.pingKey != widget.pingKey &&
        Motion.of(context, Motion.slow) != Duration.zero) {
      // Two rings for a new update.
      _ring
        ..reset()
        ..forward().then((_) {
          if (mounted) _ring.forward(from: 0);
        });
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _ring,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_ring.value);
              if (_ring.value == 0) return const SizedBox.shrink();
              return Container(
                width: s + s * 2.2 * t,
                height: s + s * 2.2 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.7 * (1 - t)),
                    width: 1.5,
                  ),
                ),
              );
            },
          ),
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
