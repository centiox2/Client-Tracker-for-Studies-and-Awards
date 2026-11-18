import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';

final aiSummaryServiceProvider = Provider(
  (ref) => AiSummaryService(ref.read(cloudSyncProvider.notifier).callAsUser),
);

class AiSummaryService {
  AiSummaryService(this.call);
  final Future<Object?> Function(String, [Map<String, Object?>?]) call;
  Future<bool> access() async => await call('ai_summary_access') == true;
  Future<Map<String, dynamic>> read() async =>
      Map<String, dynamic>.from(await call('ai_summary_read') as Map);
  Future<Map<String, dynamic>> settings() async =>
      Map<String, dynamic>.from(await call('ai_summary_settings') as Map);
  Future<void> save({
    required bool enabled,
    required String model,
    required List<int> users,
    String? key,
  }) async {
    await call('ai_summary_configure', {
      'p_enabled': enabled,
      'p_model': model,
      'p_user_ids': users,
      'p_key': key,
    });
  }
}

void _refresh(Ref ref) {
  final timer = Timer(const Duration(minutes: 1), () => ref.invalidateSelf());
  ref.onDispose(timer.cancel);
}

final aiSummaryAccessProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.watch(currentUserProvider);
  if (!ref.watch(accountsEnabledProvider) ||
      ref.watch(currentUserProvider) == null) {
    return false;
  }
  final result = await ref.watch(aiSummaryServiceProvider).access();
  if (ref.mounted) _refresh(ref);
  return result;
});
final aiSummariesProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  ref.watch(currentUserProvider);
  if (!await ref.watch(aiSummaryAccessProvider.future)) {
    throw StateError('Access has not been assigned.');
  }
  final result = await ref.watch(aiSummaryServiceProvider).read();
  if (ref.mounted) _refresh(ref);
  return result;
});
final aiSummarySettingsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      ref.watch(currentUserProvider);
      return ref.watch(aiSummaryServiceProvider).settings();
    });

String summaryStatus(Map<String, dynamic> data) {
  if (data['enabled'] != true) {
    return 'Daily AI summaries are off. Admin can enable them in Settings.';
  }
  if (data['configured'] != true) {
    return 'Waiting for Admin to configure Gemini.';
  }
  return switch (data['status']) {
    'running' => 'Today’s summary is being prepared.',
    'failed' => 'Today’s summary could not be generated. Earlier summaries remain available.',
    'ready' => 'Today’s summary is ready.',
    _ => 'The next summary will be prepared after 5 pm (Nairobi), at 5:05 pm.',
  };
}

bool summaryAccessGranted(AsyncValue<bool> access) =>
    !access.isReloading && access.value == true;
