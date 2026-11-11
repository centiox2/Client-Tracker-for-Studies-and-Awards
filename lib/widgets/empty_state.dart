import 'package:flutter/material.dart';

import '../design/app_theme.dart';

/// Quiet empty state: faint icon in a hairline-bordered tile, short title,
/// single primary action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Dt.s32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outline),
              ),
              child: Icon(icon, size: 22, color: Dt.textFaint(theme)),
            ),
            const SizedBox(height: Dt.s16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: Dt.s8),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Dt.textMuted(theme),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: Dt.s20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add, size: 16),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The empty state inside a card: an icon, what's missing, what to do, and
/// up to two links that help (e.g. "See yesterday's payments").
class PanelEmpty extends StatelessWidget {
  const PanelEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? message;

  /// (label, onPressed)
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outline),
            ),
            child: Icon(icon, size: 18, color: Dt.textFaint(theme)),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                for (final (label, onPressed) in actions)
                  TextButton(onPressed: onPressed, child: Text(label)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
