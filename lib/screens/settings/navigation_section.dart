import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/mobile_navigation.dart';
import '../../widgets/panels.dart';

class NavigationSection extends ConsumerWidget {
  const NavigationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(mobileBarTabsProvider);
    return AppPanel(
      title: 'Mobile and tablet navigation',
      subtitle:
          'Choose up to four pages for your bottom bar and put them in '
          'the order you prefer. Other pages stay in More. Saved for you on this device.',
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pinned.map((tab) => tab.label).join(' · '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('customize-navigation'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _NavigationEditor(),
              ),
              icon: const Icon(Icons.dock_outlined),
              label: const Text('Customize bottom bar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationEditor extends ConsumerStatefulWidget {
  const _NavigationEditor();
  @override
  ConsumerState<_NavigationEditor> createState() => _NavigationEditorState();
}

class _NavigationEditorState extends ConsumerState<_NavigationEditor> {
  late List<AppTab> _pinned = [...ref.read(mobileBarTabsProvider)];
  bool _defaults = false;

  void _move(int from, int to) => setState(() {
    _pinned.insert(to, _pinned.removeAt(from));
    _defaults = false;
  });

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(availableAppTabsProvider);
    _pinned.removeWhere((t) => !allowed.contains(t));
    final remaining = allowed.where((t) => !_pinned.contains(t)).toList();
    return AlertDialog(
      title: const Text('Customize bottom bar'),
      insetPadding: MediaQuery.sizeOf(context).width < 600
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
          : null,
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_pinned.length} of 4 pages selected',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Use the arrows to change the order. Remove a page to make room for another.',
            ),
            const SizedBox(height: 16),
            for (final (index, tab) in _pinned.indexed)
              Padding(
                key: ValueKey('pinned-${tab.name}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${index + 1}. ${tab.label}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          key: ValueKey('nav-up-${tab.name}'),
                          tooltip: 'Move ${tab.label} earlier',
                          onPressed: index == 0
                              ? null
                              : () => _move(index, index - 1),
                          icon: const Icon(Icons.arrow_upward, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('nav-down-${tab.name}'),
                          tooltip: 'Move ${tab.label} later',
                          onPressed: index == _pinned.length - 1
                              ? null
                              : () => _move(index, index + 1),
                          icon: const Icon(Icons.arrow_downward, size: 18),
                        ),
                        TextButton.icon(
                          key: ValueKey('nav-remove-${tab.name}'),
                          onPressed: _pinned.length == 1
                              ? null
                              : () => setState(() {
                                  _pinned.remove(tab);
                                  _defaults = false;
                                }),
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 18,
                          ),
                          label: const Text('Remove'),
                        ),
                      ],
                    ),
                    const Divider(),
                  ],
                ),
              ),
            if (remaining.isNotEmpty) ...[
              const Text('Other pages'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tab in remaining)
                    OutlinedButton.icon(
                      key: ValueKey('nav-add-${tab.name}'),
                      onPressed: _pinned.length >= 4
                          ? null
                          : () => setState(() {
                              _pinned.add(tab);
                              _defaults = false;
                            }),
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(tab.label),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextButton(
              key: const ValueKey('nav-reset'),
              onPressed: () => setState(() {
                // Read defaults without changing the saved choice until Save.
                _pinned = defaultMobileBarTabs(allowed);
                _defaults = true;
              }),
              child: const Text('Restore default order'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('nav-save'),
          onPressed: _pinned.isEmpty
              ? null
              : () {
                  final settings = ref.read(mobileNavigationProvider.notifier);
                  _defaults ? settings.reset() : settings.save(_pinned);
                  Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
