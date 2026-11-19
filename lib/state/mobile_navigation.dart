import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state.dart';
import '../services/ai_summary_service.dart';

/// The same access rules drive the sidebar, bottom bar and its editor.
final availableAppTabsProvider = Provider<List<AppTab>>((ref) {
  final role = ref.watch(sessionProvider);
  final user = ref.watch(currentUserProvider);
  final accounts = ref.watch(accountsEnabledProvider);
  final aiAccess =
      accounts && summaryAccessGranted(ref.watch(aiSummaryAccessProvider));
  final tabs = role?.canEdit == true
      ? AppTab.values
      : const [
          AppTab.dailyReports,
          AppTab.todo,
          AppTab.reports,
          AppTab.revenue,
          AppTab.applications,
          AppTab.history,
          AppTab.staff,
          AppTab.aiSummary,
          AppTab.settings,
        ];
  final byRole = [
    for (final tab in tabs)
      if ((tab != AppTab.revenue || (role?.seesRevenue ?? false)) &&
          (tab != AppTab.dailyReports || accounts) &&
          (tab != AppTab.aiSummary || aiAccess))
        tab,
  ];
  return [
    for (final tab in byRole)
      if (tab == AppTab.aiSummary ||
          tab == AppTab.settings ||
          tab == AppTab.todo ||
          (user?.mayOpen(tab.name) ?? true))
        tab,
  ];
});

/// Saved locally for this person, so a shared phone keeps separate choices.
final mobileNavigationProvider =
    NotifierProvider<MobileNavigationNotifier, List<AppTab>?>(
      MobileNavigationNotifier.new,
    );

class MobileNavigationNotifier extends Notifier<List<AppTab>?> {
  static const maxPinned = 4;
  late String _key;

  @override
  List<AppTab>? build() {
    final user = ref.watch(currentUserProvider);
    final role = ref.watch(sessionProvider);
    _key =
        'navigation.bottom.${user == null ? 'profile.${role?.name}' : 'user.${user.id}'}';
    final saved = ref.read(uiPrefProvider).get(_key);
    if (saved == null) return null;
    try {
      final names = jsonDecode(saved) as List;
      final tabs = <AppTab>[];
      for (final name in names) {
        final tab = AppTab.values.where((t) => t.name == name).firstOrNull;
        if (tab != null && !tabs.contains(tab)) tabs.add(tab);
      }
      return tabs.isEmpty ? null : List.unmodifiable(tabs.take(maxPinned));
    } catch (_) {
      return null;
    }
  }

  void save(List<AppTab> tabs) {
    final allowed = ref.read(availableAppTabsProvider);
    final selected = tabs.where(allowed.contains).toSet().toList();
    if (selected.isEmpty || selected.length > maxPinned) {
      throw ArgumentError('Choose between one and four available pages.');
    }
    ref
        .read(uiPrefProvider)
        .set(_key, jsonEncode(selected.map((t) => t.name).toList()));
    state = List.unmodifiable(selected);
  }

  void reset() {
    ref.read(uiPrefProvider).set(_key, 'null');
    state = null;
  }
}

/// A saved page that is no longer allowed never appears in navigation.
final mobileBarTabsProvider = Provider<List<AppTab>>((ref) {
  final allowed = ref.watch(availableAppTabsProvider);
  final saved = ref.watch(mobileNavigationProvider);
  final selected = saved?.where(allowed.contains).toList() ?? [];
  if (selected.isNotEmpty) return selected;
  return defaultMobileBarTabs(allowed);
});

List<AppTab> defaultMobileBarTabs(List<AppTab> allowed) {
  final defaults = [
    AppTab.home,
    if (allowed.contains(AppTab.dailyReports)) AppTab.applications,
    AppTab.week,
    AppTab.reports,
    AppTab.revenue,
    ...allowed,
  ];
  return defaults
      .where(allowed.contains)
      .toSet()
      .take(MobileNavigationNotifier.maxPinned)
      .toList();
}
