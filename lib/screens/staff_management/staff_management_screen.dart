import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../models/staff.dart';
import '../../repositories/client_count_repository.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../../widgets/undo_snack.dart';
import '../reports/reports_screen.dart' show showStaffProfile;

/// The team: order, rename, deactivate or delete staff, and add new ones.
/// Same panel style as the dashboard and Reports.
///
/// [readOnly] (the boss's view): just the team list, with no editing.
class StaffManagementScreen extends ConsumerStatefulWidget {
  const StaffManagementScreen({super.key, this.readOnly = false});
  final bool readOnly;

  @override
  ConsumerState<StaffManagementScreen> createState() =>
      _StaffManagementScreenState();
}

class _StaffManagementScreenState extends ConsumerState<StaffManagementScreen> {
  // Explicit controllers: the table and the side column are two vertical
  // scrollables and must not share the primary one.
  final _tableController = ScrollController();
  final _sideController = ScrollController();

  @override
  void dispose() {
    _tableController.dispose();
    _sideController.dispose();
    super.dispose();
  }

  void _add(String name) {
    if (name.trim().isEmpty) return;
    ref.read(staffRepositoryProvider).add(name);
    ref.read(dataVersionProvider.notifier).bump();
  }

  void _setActive(Staff member, bool active) {
    ref.read(staffRepositoryProvider).setActive(member.id, active);
    ref.read(dataVersionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(staffListProvider);
    final active = staff.where((s) => s.active).toList();
    final inactive = staff.where((s) => !s.active).toList();

    // Totals for the week being worked with (if any).
    final weekData = ref.watch(currentWeekProvider);
    final weekTotals = <int, int>{
      for (final t in weekData?.staffTotals ?? const <StaffWeekTotals>[])
        t.staffId: t.total,
    };

    return LayoutBuilder(
      builder: (context, viewport) {
        final pad = clarityHPad(context);
        final wide = viewport.maxWidth >= 1080;

        final team = _Panel(
          title: 'Team',
          icon: Icons.groups_outlined,
          trailing: '${active.length} active · ${inactive.length} inactive',
          expandChild: true,
          child: _StaffTable(
            staff: staff,
            weekTotals: weekTotals,
            tableController: _tableController,
            readOnly: widget.readOnly,
            onToggleActive: (m) => _setActive(m, !m.active),
          ),
        );
        if (widget.readOnly) {
          return Padding(
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 18),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: team,
              ),
            ),
          );
        }
        final side = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AddStaffPanel(onAdd: _add),
            const SizedBox(height: 12),
            _InactivePanel(
              inactive: inactive,
              onReactivate: (m) => _setActive(m, true),
            ),
            if (weekData != null) ...[
              const SizedBox(height: Dt.gap),
              _WeekGlance(data: weekData),
            ],
          ],
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 18, pad, 18),
          // Top, not centred: a short page mustn't float mid-screen.
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: team),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 320,
                          child: SingleChildScrollView(
                            controller: _sideController,
                            child: side,
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      controller: _sideController,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Bounded so the reorderable list inside has a
                          // height to work with: tall enough for everyone,
                          // so the page scrolls, not a box inside it.
                          SizedBox(
                            height: (staff.length * 49 + 96)
                                .clamp(240.0, double.infinity)
                                .toDouble(),
                            child: team,
                          ),
                          const SizedBox(height: 12),
                          side,
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String? initial,
}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Full name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

// ---------------------------------------------------------------- table -----

/// Column widths shared by the header and rows.
const double _gripW = 28;
const double _avatarW = 38;
const double _statusW = 100;
const double _weekW = 84;
const double _actionsW = 124;

/// The team table: drag to reorder, rename, mark inactive, delete.
class _StaffTable extends ConsumerWidget {
  const _StaffTable({
    required this.staff,
    required this.weekTotals,
    required this.tableController,
    required this.readOnly,
    required this.onToggleActive,
  });

  final List<Staff> staff;
  final Map<int, int> weekTotals;
  final ScrollController tableController;

  /// No grip and no row actions.
  final bool readOnly;
  final ValueChanged<Staff> onToggleActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final head = (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 10.5,
      color: Dt.textMuted(theme),
    );

    final header = Container(
      height: 34,
      padding: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Row(
        children: [
          SizedBox(width: (readOnly ? 14 : _gripW) + _avatarW),
          Expanded(child: Text('Name', style: head)),
          if (!compact)
            SizedBox(
              width: _statusW,
              child: Text('Status', style: head),
            ),
          SizedBox(
            width: compact ? 52 : _weekW,
            child: Text(
              compact ? 'Week' : 'This week',
              style: head,
              maxLines: 1,
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(width: readOnly ? 6 : _actionsW),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: Scrollbar(
            controller: tableController,
            thumbVisibility: true,
            child: ReorderableListView.builder(
              scrollController: tableController,
              itemCount: staff.length,
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) => Material(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Dt.rSm),
                child: child,
              ),
              onReorderItem: (oldIndex, newIndex) {
                final ids = staff.map((s) => s.id).toList();
                ids.insert(newIndex, ids.removeAt(oldIndex));
                ref.read(staffRepositoryProvider).reorder(ids);
                ref.read(dataVersionProvider.notifier).bump();
              },
              itemBuilder: (context, i) {
                final member = staff[i];
                return _StaffRow(
                  key: ValueKey('staff-${member.id}'),
                  member: member,
                  index: i,
                  last: i == staff.length - 1,
                  compact: compact,
                  readOnly: readOnly,
                  weekTotal: weekTotals[member.id] ?? 0,
                  onEdit: () => _renameStaff(context, ref, member),
                  onToggleActive: () => onToggleActive(member),
                  onDelete: () => _confirmDelete(context, ref, member),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _renameStaff(
    BuildContext context,
    WidgetRef ref,
    Staff member,
  ) async {
    final name = await _promptName(
      context,
      title: 'Rename ${member.name}',
      initial: member.name,
    );
    if (name != null && name.trim().isNotEmpty) {
      ref.read(staffRepositoryProvider).rename(member.id, name);
      ref.read(dataVersionProvider.notifier).bump();
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Staff member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${member.name}?'),
        content: Text(
          'This removes ${member.name} and all their recorded '
          'numbers from every week. If ${member.name} has left, prefer '
          '"Mark inactive" — past weeks keep their name and history intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final removed = ref.read(staffRepositoryProvider).delete(member.id);
      ref.read(dataVersionProvider.notifier).bump();
      if (!context.mounted) return;
      showUndoSnack(context, 'Deleted ${member.name}', () {
        removed.restore(ref.read(databaseProvider));
        ref.read(dataVersionProvider.notifier).bump();
      });
    }
  }
}

/// One team row: grip, initial, name, status, this week, actions.
class _StaffRow extends StatelessWidget {
  const _StaffRow({
    super.key,
    required this.member,
    required this.index,
    required this.last,
    required this.weekTotal,
    required this.compact,
    required this.readOnly,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  final Staff member;
  final int index;
  final bool last;
  final int weekTotal;
  final bool compact;
  final bool readOnly;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = Dt.textMuted(theme);

    Widget action(
      IconData icon,
      String tooltip,
      VoidCallback onTap, {
      bool danger = false,
    }) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: Icon(icon, color: danger ? scheme.error : muted),
      );
    }

    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: member.active
                ? Dt.statusGreen(theme.brightness)
                : scheme.outline,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          member.active ? 'Active' : 'Inactive',
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
      ],
    );

    final name = Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'View ${member.name}’s profile',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          borderRadius: BorderRadius.circular(Dt.rSm),
          onTap: () => showStaffProfile(context, member.id),
          // Rows are a fixed height: a long name shrinks a little to fit
          // rather than being cut short.
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                member.name,
                maxLines: 1,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: member.active ? null : muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Container(
      height: 48,
      padding: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(
                  color: scheme.outline.withValues(alpha: 0.6),
                ),
              ),
      ),
      child: Row(
        children: [
          if (readOnly)
            const SizedBox(width: 14)
          else
            // Grip — the drag handle, in-row so nothing can overlap it.
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SizedBox(
                  width: _gripW,
                  height: 48,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 14,
                    color: Dt.textFaint(theme),
                  ),
                ),
              ),
            ),
          SizedBox(
            width: _avatarW,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHigh,
                ),
                child: Text(
                  member.name.isEmpty
                      ? '?'
                      : member.name.trim().contains(' ')
                      ? initialsOf(member.name)
                      : member.name[0].toUpperCase(),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: compact
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [name, status],
                  )
                : name,
          ),
          if (!compact) SizedBox(width: _statusW, child: status),
          SizedBox(
            width: compact ? 52 : _weekW,
            child: Text(
              weekTotal == 0 ? '–' : '$weekTotal',
              textAlign: TextAlign.right,
              style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
                fontWeight: FontWeight.w600,
                color: weekTotal == 0 ? Dt.textFaint(theme) : null,
              ),
            ),
          ),
          if (readOnly)
            const SizedBox(width: 6)
          else
            SizedBox(
              width: _actionsW,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  action(Icons.edit_outlined, 'Rename', onEdit),
                  action(
                    member.active
                        ? Icons.do_not_disturb_on_outlined
                        : Icons.add_circle_outline,
                    member.active
                        ? 'Mark inactive (keeps history)'
                        : 'Reactivate',
                    onToggleActive,
                  ),
                  action(
                    Icons.delete_outline,
                    'Delete permanently',
                    onDelete,
                    danger: true,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- panels -----

/// Bordered panel with a title bar — same chrome as the dashboard/Reports.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.expandChild = false,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? trailing;

  /// Fill the panel's height with [child] (for the scrolling team list).
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// Add-staff form: Enter or the button submits.
class _AddStaffPanel extends StatefulWidget {
  const _AddStaffPanel({required this.onAdd});
  final ValueChanged<String> onAdd;

  @override
  State<_AddStaffPanel> createState() => _AddStaffPanelState();
}

class _AddStaffPanelState extends State<_AddStaffPanel> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    widget.onAdd(name);
    _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Panel(
      title: 'Add staff member',
      icon: Icons.person_add_alt,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Faith Wanjiru',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add to the team'),
            ),
            const SizedBox(height: 10),
            Text(
              'New staff go to the bottom of the list and join new weeks '
              'automatically. Drag the handle on a row to reorder.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Dt.textMuted(theme),
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inactive staff, each with a one-click Reactivate.
class _InactivePanel extends StatelessWidget {
  const _InactivePanel({required this.inactive, required this.onReactivate});

  final List<Staff> inactive;
  final ValueChanged<Staff> onReactivate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Panel(
      title: 'Inactive',
      icon: Icons.person_off_outlined,
      trailing: '${inactive.length}',
      child: inactive.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Text(
                'No one is inactive. Marking someone inactive keeps their past '
                'numbers but leaves them out of new weeks.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Dt.textMuted(theme),
                  height: 1.45,
                ),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < inactive.length; i++)
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 4, 6, 4),
                    decoration: BoxDecoration(
                      border: i == inactive.length - 1
                          ? null
                          : Border(
                              bottom: BorderSide(
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            inactive[i].name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => onReactivate(inactive[i]),
                          child: const Text('Reactivate'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// "This week at a glance": who saw clients, who saw the most, who hasn't
/// yet (of the people on this week's board).
class _WeekGlance extends StatelessWidget {
  const _WeekGlance({required this.data});
  final CurrentWeekData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final rows = data.staffTotals;
    final saw = rows.where((r) => r.total > 0).toList();
    final top = saw.isEmpty
        ? 0
        : saw.map((r) => r.total).reduce((a, b) => a > b ? a : b);
    final leaders = saw.where((r) => r.total == top).map((r) => r.name);
    final none = rows.where((r) => r.total == 0).map((r) => r.name).toList();
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return AppPanel(
      key: const ValueKey('week-glance'),
      title: 'This week at a glance',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        child: Column(
          children: [
            line('Saw clients', '${saw.length} of ${rows.length}'),
            line(
              'Most clients',
              saw.isEmpty ? '—' : '${leaders.join(', ')} · $top',
            ),
            line('No clients yet', none.isEmpty ? '—' : none.join(', ')),
          ],
        ),
      ),
    );
  }
}
