import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../state/app_state.dart';
import '../../widgets/week_label.dart';
import '../history/history_screen.dart' show weekMatchesQuery;
import '../weekly_tracker/new_week_dialog.dart';

/// Opens the Ctrl+K quick search: jump to a page, a week or a staff member.
Future<void> showQuickSearch(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  builder: (_) => const _QuickSearchDialog(),
);

class _Result {
  const _Result({
    required this.group,
    required this.icon,
    required this.title,
    required this.run,
    this.subtitle,
  });

  final String group;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Runs after the dialog has closed, with the shell's context.
  final void Function(BuildContext context, WidgetRef ref) run;
}

const _pages = <(AppTab, String, IconData)>[
  (AppTab.home, 'Overview', Icons.space_dashboard_outlined),
  (AppTab.week, 'Weekly tracker', Icons.calendar_view_week_outlined),
  (AppTab.revenue, 'Revenue', Icons.payments_outlined),
  (AppTab.applications, 'Applications', Icons.school_outlined),
  (AppTab.history, 'History', Icons.history),
  (AppTab.staff, 'Staff', Icons.groups_2_outlined),
  (AppTab.reports, 'Reports', Icons.insights_outlined),
  (AppTab.settings, 'Settings', Icons.settings_outlined),
];

class _QuickSearchDialog extends ConsumerStatefulWidget {
  const _QuickSearchDialog();

  @override
  ConsumerState<_QuickSearchDialog> createState() => _QuickSearchDialogState();
}

class _QuickSearchDialogState extends ConsumerState<_QuickSearchDialog> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  int _highlight = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Result> _results(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    final results = <_Result>[];

    final role = ref.read(sessionProvider);
    for (final (tab, label, icon) in _pages) {
      if (tab == AppTab.revenue && !(role?.seesRevenue ?? false)) continue;
      if (tab == AppTab.settings && !(role?.isAdmin ?? false)) continue;
      if (query.isEmpty || label.toLowerCase().contains(query)) {
        results.add(
          _Result(
            group: 'Pages',
            icon: icon,
            title: label,
            run: (_, ref) => ref.read(appActionsProvider).selectTab(tab),
          ),
        );
      }
    }

    if (query.isEmpty || 'new week'.contains(query)) {
      results.add(
        _Result(
          group: 'Actions',
          icon: Icons.add,
          title: 'New week…',
          subtitle: 'Create or open a Monday–Friday week',
          run: (context, ref) async {
            final id = await showNewWeekDialog(context, ref);
            if (id != null) ref.read(appActionsProvider).selectTab(AppTab.week);
          },
        ),
      );
    }

    final weeks = ref
        .read(historyProvider)
        .where((w) => weekMatchesQuery(w, query))
        .take(query.isEmpty ? 4 : 8);
    for (final w in weeks) {
      results.add(
        _Result(
          group: query.isEmpty ? 'Recent weeks' : 'Weeks',
          icon: Icons.calendar_month_outlined,
          title: weekRangeLabel(w.week.startDate, w.week.endDate),
          subtitle: '${w.totals.total} clients · open in tracker',
          run: (_, ref) => ref
              .read(appActionsProvider)
              .selectTab(AppTab.week, weekId: w.week.id),
        ),
      );
    }

    if (query.isNotEmpty) {
      final staff = ref
          .read(staffListProvider)
          .where((s) => s.name.toLowerCase().contains(query))
          .take(8);
      for (final s in staff) {
        results.add(
          _Result(
            group: 'Staff',
            icon: Icons.person_outline,
            title: s.name,
            subtitle: s.active
                ? 'Active · open Staff'
                : 'Inactive · open Staff',
            run: (_, ref) =>
                ref.read(appActionsProvider).selectTab(AppTab.staff),
          ),
        );
      }
    }
    return results;
  }

  void _choose(_Result result) {
    // Run against the shell's context: this dialog's context is gone once
    // it pops, and follow-up dialogs (New week) need a live one.
    final shell = ref.read(shellContextProvider);
    Navigator.of(context).pop();
    if (shell != null && shell.mounted) result.run(shell, ref);
  }

  KeyEventResult _onKey(List<_Result> results, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (results.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() {
        _highlight = (_highlight + step) % results.length;
        if (_highlight < 0) _highlight += results.length;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _choose(results[_highlight.clamp(0, results.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = _results(_controller.text);
    final highlight = results.isEmpty
        ? -1
        : _highlight.clamp(0, results.length - 1);

    final rows = <Widget>[];
    String? group;
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.group != group) {
        group = r.group;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              group.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                letterSpacing: 0.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      rows.add(
        _ResultRow(
          result: r,
          highlighted: i == highlight,
          onTap: () => _choose(r),
          onHover: () => setState(() => _highlight = i),
        ),
      );
    }

    return Dialog(
      alignment: const Alignment(0, -0.6),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: Focus(
          onKeyEvent: (_, event) => _onKey(results, event),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(Dt.s12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  onChanged: (_) => setState(() => _highlight = 0),
                  decoration: const InputDecoration(
                    hintText: 'Search pages, weeks (e.g. 28/09) or staff…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: results.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No matches for “${_controller.text.trim()}”',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: rows,
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '↑↓ to move · Enter to open · Esc to close',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final _Result result;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: highlighted ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(Dt.rSm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Dt.rSm),
          onTap: onTap,
          onHover: (inside) {
            if (inside) onHover();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Icon(result.icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.title,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (result.subtitle != null)
                        Text(
                          result.subtitle!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (highlighted)
                  Icon(
                    Icons.keyboard_return,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
