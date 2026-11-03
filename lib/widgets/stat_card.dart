import 'package:flutter/material.dart';

import '../design/app_theme.dart';

/// A compact statistics card. Numbers are data: values use tabular figures
/// and stay in the foreground color — color lives in the 6px meaning dot
/// beside the label, not in the digits.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.subtitle,
    this.icon,
    this.color,
    this.width,
  });

  final String label;
  final String value;
  final String? subtitle;
  final IconData? icon;
  final Color? color;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final meaning = color;

    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Dt.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (meaning != null) ...[
                    MeaningDot(meaning),
                    const SizedBox(width: Dt.s8),
                  ] else if (icon != null) ...[
                    Icon(icon, size: 14, color: Dt.textMuted(theme)),
                    const SizedBox(width: Dt.s8),
                  ],
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: microLabel(theme),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Dt.s8),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: Dt.numeral(
                    context,
                    size: theme.textTheme.headlineSmall!.fontSize,
                    weight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: Dt.s4),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Dt.textMuted(theme),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
