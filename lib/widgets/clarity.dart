import 'package:flutter/material.dart';

import '../design/app_theme.dart';

/// Clarity building blocks (see the design kit): page header, KPI cards,
/// status pills, meters, notices and list rows. Colours always come from
/// the tokens, so dark mode works by itself.

/// The page's side padding: 32, or 16 on phones.
double clarityHPad(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 640 ? 16.0 : 32.0;

/// Page padding: 28 top, 32 sides (16 on phones).
EdgeInsets clarityPagePadding(double width) => width < 640
    ? const EdgeInsets.fromLTRB(16, 20, 16, 32)
    : const EdgeInsets.fromLTRB(32, 28, 32, 40);

/// A page's header: the date (or other eyebrow), the page title, and a
/// toolbar with at most one primary button. Wraps on narrow screens.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.actions = const [],
  });

  final String title;

  /// Small muted line above the title (usually today's date).
  final String? eyebrow;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final phone = MediaQuery.sizeOf(context).width < 640;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null)
          Text(
            eyebrow!,
            key: const ValueKey('page-eyebrow'),
            style: theme.textTheme.labelMedium?.copyWith(
              color: c.textMuted,
              fontWeight: FontWeight.w400,
            ),
          ),
        if (eyebrow != null) const SizedBox(height: 6),
        Text(
          title,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: phone ? 24 : 28,
          ),
        ),
      ],
    );
    if (actions.isEmpty) return heading;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      runSpacing: 16,
      spacing: 16,
      children: [
        heading,
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    );
  }
}

/// A plain Clarity card: surface, 1px border, 12px radius.
class ClarityCard extends StatelessWidget {
  const ClarityCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final c = context.clarity;
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surface,
        border: Border.all(color: borderColor ?? c.border),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: child,
    );
  }
}

/// Which way a KPI moved.
enum DeltaTone { down, up, neutral }

/// A headline number: label → big number + unit → a delta or fact line.
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.caption,
    this.tone = DeltaTone.neutral,
    this.onTap,
    this.valueColor,
  });

  final String label;
  final String value;

  /// Small text after the number ("this week", "8.5 / day").
  final String? unit;

  /// The line below ("↓ 6 (33%) vs last week", "November 2026").
  final String? caption;
  final DeltaTone tone;
  final VoidCallback? onTap;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final card = ClarityCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: Dt.tab(theme.textTheme.displaySmall!)
                        .copyWith(color: valueColor),
                  ),
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    unit!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: c.textMuted,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (caption != null) ...[
            const SizedBox(height: 10),
            Text(
              caption!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: switch (tone) {
                  DeltaTone.down => c.negativeFg,
                  DeltaTone.up => c.positiveFg,
                  DeltaTone.neutral => c.textMuted,
                },
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: card),
    );
  }
}

/// A row of KPI cards that wraps by itself: each at least [minWidth] wide.
class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.children, this.minWidth = 190});

  final List<Widget> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = Dt.gap;
        var cols = ((box.maxWidth + gap) / (minWidth + gap)).floor();
        cols = cols.clamp(1, children.isEmpty ? 1 : children.length);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final row = children.sublist(i, (i + cols).clamp(0, children.length));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (j, child) in row.indexed) ...[
                    if (j > 0) const SizedBox(width: gap),
                    SizedBox(width: w, child: child),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const SizedBox(height: gap),
              r,
            ],
          ],
        );
      },
    );
  }
}

/// Main content left (2fr), supporting cards right (1fr) when there's room
/// (1180px of page); one column otherwise.
class MainAndSide extends StatelessWidget {
  const MainAndSide({
    super.key,
    required this.main,
    required this.side,
    this.breakpoint = 1000,
  });

  final Widget main;
  final List<Widget> side;

  /// Content width from which the two columns sit side by side.
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    Widget stack(List<Widget> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in items.indexed) ...[
          if (i > 0) const SizedBox(height: Dt.gap),
          w,
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < breakpoint) return stack([main, ...side]);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: main),
            const SizedBox(width: Dt.gap),
            Expanded(child: stack(side)),
          ],
        );
      },
    );
  }
}

/// How a status reads.
enum PillTone { positive, warning, neutral, negative, accent }

/// A status, spelled out: "Entered", "Due today", "Upcoming".
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.tone = PillTone.neutral});

  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.clarity;
    final (bg, fg) = switch (tone) {
      PillTone.positive => (c.positiveBg, c.positiveFg),
      PillTone.warning => (c.warningBg, c.warningFg),
      PillTone.neutral => (c.neutralBg, c.neutralFg),
      PillTone.negative => (c.negativeFg.withValues(alpha: 0.12), c.negativeFg),
      PillTone.accent => (c.accentSoft, c.accent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Dt.rPill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: Dt.font,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: fg,
          height: 1.3,
        ),
      ),
    );
  }
}

/// A chip with an icon ("Synced 08:27").
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.icon,
    this.tone = PillTone.positive,
  });

  final String label;
  final IconData icon;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.clarity;
    final (bg, fg) = switch (tone) {
      PillTone.positive => (c.positiveBg, c.positiveFg),
      PillTone.warning => (c.warningBg, c.warningFg),
      PillTone.neutral => (c.neutralBg, c.neutralFg),
      PillTone.negative => (c.negativeFg.withValues(alpha: 0.12), c.negativeFg),
      PillTone.accent => (c.accentSoft, c.accent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Dt.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontFamily: Dt.font, fontSize: 13, color: fg),
          ),
        ],
      ),
    );
  }
}

/// A label and number with a 6px bar under it (width = value ÷ highest).
class Meter extends StatelessWidget {
  const Meter({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    this.valueLabel,
    this.color,
  });

  final String label;
  final num value;
  final num max;
  final String? valueLabel;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final share = max <= 0 ? 0.0 : (value / max).clamp(0, 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              valueLabel ?? '$value',
              style: Dt.tab(theme.textTheme.bodyMedium!)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: c.track)),
                FractionallySizedBox(
                  widthFactor: share,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color ?? c.accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Something the person must act on: warm notice colours, a bold title, one
/// sentence, and a full-width button. One per screen at most.
class NoticeBox extends StatelessWidget {
  const NoticeBox({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.clarity;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.noticeBg,
        border: Border.all(color: c.noticeBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: Dt.font,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.noticeFg,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              fontFamily: Dt.font,
              fontSize: 12,
              height: 1.45,
              color: c.noticeFg,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  backgroundColor: c.surface,
                  foregroundColor: c.noticeFg,
                  side: BorderSide(color: c.noticeBtnBorder),
                  minimumSize: const Size(0, 36),
                  textStyle: const TextStyle(
                    fontFamily: Dt.font,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Label left, bold number right; rows divided by a subtle line.
class ListRows extends StatelessWidget {
  const ListRows({super.key, required this.rows});

  /// (label, caption or null, value, onTap or null)
  final List<(String, String?, String, VoidCallback?)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (label, caption, value, onTap)) in rows.indexed)
          InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: c.borderSubtle)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: label,
                        children: [
                          if (caption != null)
                            TextSpan(
                              text: ' · $caption',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.textMuted,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    value,
                    style: Dt.tab(theme.textTheme.bodyMedium!)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// "↓ 6 (33%) vs last week" / "↑ 3 (12%) vs last week" / "Same as last
/// week" — and which way it went.
(String, DeltaTone) deltaVsLast(
  int now,
  int before, {
  String vs = 'last week',
}) {
  if (before == 0 && now == 0) return ('Same as $vs', DeltaTone.neutral);
  final diff = now - before;
  if (diff == 0) return ('Same as $vs', DeltaTone.neutral);
  final pct = before == 0 ? null : (diff.abs() * 100 / before).round();
  final arrow = diff < 0 ? '↓' : '↑';
  return (
    '$arrow ${diff.abs()}${pct == null ? '' : ' ($pct%)'} vs $vs',
    diff < 0 ? DeltaTone.down : DeltaTone.up,
  );
}

/// A page's sections as underlined text tabs ("Day · All transactions ·
/// Insights"): the current one in the accent with a 2px line under it, on a
/// full-width subtle rule. Scrolls sideways if the tabs don't fit.
class UnderlineTabs<T> extends StatelessWidget {
  const UnderlineTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.trailing,
  });

  /// (value, label) for each tab.
  final List<(T, String)> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Something on the right of the tab row (a status line, a button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, (value, label)) in tabs.indexed) ...[
            if (i > 0) const SizedBox(width: 28),
            Semantics(
              selected: value == selected,
              button: true,
              child: InkWell(
                key: ValueKey('tab-$label'),
                onTap: () => onChanged(value),
                hoverColor: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: value == selected
                            ? c.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: value == selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: value == selected ? c.accent : c.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: row),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: trailing),
          ],
        ],
      ),
    );
  }
}

/// Two letters for an avatar: "Canisius Yego" → "CY", "Admin" → "AD".
String initialsOf(String name) {
  final words = name
      .split(RegExp(r'[\s/]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  if (words.length == 1) {
    final w = words.first;
    return (w.length >= 2 ? w.substring(0, 2) : w).toUpperCase();
  }
  return (words[0][0] + words[1][0]).toUpperCase();
}
