import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai_summary_service.dart';
import '../../services/cloud/cloud_api.dart';
import '../../design/app_theme.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';

class AiSummarySettings extends ConsumerStatefulWidget {
  const AiSummarySettings({super.key});
  @override
  ConsumerState<AiSummarySettings> createState() => _AiSummarySettingsState();
}

class _AiSummarySettingsState extends ConsumerState<AiSummarySettings> {
  final keyInput = TextEditingController();
  final modelInput = TextEditingController();
  final assigned = <int>{};
  bool seeded = false, enabled = false, busy = false, replacing = false;
  bool saveError = false;
  String? message;
  @override
  void dispose() {
    keyInput.dispose();
    modelInput.dispose();
    super.dispose();
  }

  Future<void> save({required bool configured}) async {
    if (busy) return;
    final replacement = keyInput.text.trim();
    final expectKey = configured || replacement.isNotEmpty;
    setState(() {
      busy = true;
      message = null;
      saveError = false;
    });
    var saved = false;
    try {
      await ref
          .read(aiSummaryServiceProvider)
          .save(
            enabled: enabled,
            model: modelInput.text.trim(),
            users: assigned.toList(),
            key: replacement,
          );
      saved = true;
      if (!mounted) return;
      keyInput.clear();
      setState(() => replacing = false);
      ref.invalidate(aiSummaryAccessProvider);
      ref.invalidate(aiSummariesProvider);
      final confirmed = await ref.refresh(aiSummarySettingsProvider.future);
      if (!mounted) return;
      setState(() {
        saveError = expectKey && confirmed['configured'] != true;
        message = saveError
            ? 'Settings saved, but the server reports no Gemini key.'
            : 'AI summary settings saved.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          saveError = true;
          message = saved
              ? 'Settings saved. Could not verify the saved key. Retry loading settings.'
              : switch (error) {
                  CloudException(code: 'gemini_key_required') =>
                    'Add a Gemini API key to enable the daily schedule.',
                  CloudException(code: 'invalid_key') =>
                    'Check the Gemini API key and try again.',
                  CloudException(code: 'invalid_model') =>
                    'Enter a valid Gemini model name.',
                  _ => 'Could not save AI settings. Check the connection and try again.',
                };
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppPanel(
    title: 'AI daily summary',
    child: Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ref
                .watch(aiSummarySettingsProvider)
                .when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Unable to load AI settings.'),
                      TextButton(
                        onPressed: () =>
                            ref.invalidate(aiSummarySettingsProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                  data: (data) {
                    final users = (data['users'] as List? ?? []).cast<Map>();
                    final configured = data['configured'] == true;
                    if (!seeded) {
                      enabled = data['enabled'] == true;
                      modelInput.text = '${data['model']}';
                      assigned.addAll(
                        users
                            .where((u) => u['assigned'] == true)
                            .map((u) => u['id'] as int),
                      );
                      seeded = true;
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Schedule a company report for 5:05 pm Nairobi time. Admin can generate a report any time from Overview or AI summary.',
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable daily AI summary'),
                          value: enabled,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => enabled = v),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              'Gemini API key',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            StatusPill(
                              configured ? 'Key saved' : 'Key required',
                              tone: configured
                                  ? PillTone.positive
                                  : PillTone.warning,
                            ),
                            if (configured)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => setState(() {
                                        replacing = !replacing;
                                        if (!replacing) keyInput.clear();
                                      }),
                                child: Text(
                                  replacing
                                      ? 'Cancel replacement'
                                      : 'Replace key',
                                ),
                              ),
                          ],
                        ),
                        if (configured && !replacing)
                          Text(
                            'The saved key is used on every device and stays in place when you update the app.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: context.clarity.textMuted),
                          ),
                        if (!configured || replacing) ...[
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('gemini-api-key'),
                            controller: keyInput,
                            enabled: !busy,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'New API key',
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextField(
                          controller: modelInput,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Gemini model',
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'People with access',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Assigned people can view the company’s revenue and team activity in the report. Admin always has access.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: context.clarity.textMuted),
                        ),
                        for (final user in users)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${user['name']}'),
                            subtitle: Text('${user['role']}'),
                            value:
                                user['role'] == 'admin' ||
                                assigned.contains(user['id']),
                            onChanged: busy || user['role'] == 'admin'
                                ? null
                                : (v) => setState(
                                    () => v == true
                                        ? assigned.add(user['id'] as int)
                                        : assigned.remove(user['id']),
                                  ),
                          ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton(
                            onPressed: busy
                                ? null
                                : () => save(configured: configured),
                            child: Text(busy ? 'Saving…' : 'Save AI settings'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    message!,
                    style: TextStyle(
                      color: saveError
                          ? context.clarity.negativeFg
                          : context.clarity.positiveFg,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
