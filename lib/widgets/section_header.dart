import 'package:flutter/material.dart';

import '../design/app_theme.dart';

/// Uppercase micro-label section header (e.g. "TODAY", "THIS WEEK") with an
/// optional trailing widget. Pure typography — no decorative bars.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(title.toUpperCase(), style: microLabel(theme)),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}
