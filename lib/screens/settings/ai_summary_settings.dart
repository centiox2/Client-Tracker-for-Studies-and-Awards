import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai_summary_service.dart';
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
  bool seeded = false, enabled = false, busy = false;
  String? message;
  @override
  void dispose() {
    keyInput.dispose();
    modelInput.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await ref
          .read(aiSummaryServiceProvider)
          .save(
            enabled: enabled,
            model: modelInput.text.trim(),
            users: assigned.toList(),
            key: keyInput.text.trim().isEmpty ? null : keyInput.text.trim(),
          );
      if (!mounted) return;
      keyInput.clear();
      ref.invalidate(aiSummarySettingsProvider);
      ref.invalidate(aiSummaryAccessProvider);
      ref.invalidate(aiSummariesProvider);
      setState(() => message = 'AI summary settings saved.');
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not save. Check the model, API key and connection.',
        );
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
        child: ref
            .watch(aiSummarySettingsProvider)
            .when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Unable to load AI settings.'),
                  TextButton(
                    onPressed: () => ref.invalidate(aiSummarySettingsProvider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
              data: (data) {
                final users = (data['users'] as List? ?? []).cast<Map>();
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
                      'One company-wide summary, scheduled daily at 5:05 pm Africa/Nairobi, even when the app is closed. Failed scheduled runs retry at 5:15 and 5:25 pm. Admin can also use Generate report now on Overview or AI summary at any time, including with the schedule off.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Assigned users can see company information, including revenue and team activity, regardless of their other page permissions. Admin always has access. Only aggregate records are sent to Google Gemini; personal to-do items and names are excluded.',
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable daily AI summary'),
                      value: enabled,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => enabled = v),
                    ),
                    TextField(
                      controller: keyInput,
                      enabled: !busy,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: data['configured'] == true
                            ? 'Replace Gemini API key (optional)'
                            : 'Gemini API key',
                        helperMaxLines: 3,
                        helperText: 'Stored securely on the server. Leave blank to keep the saved key.',
                      ),
                    ),
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
                        onPressed: busy ? null : save,
                        child: Text(busy ? 'Saving…' : 'Save AI settings'),
                      ),
                    ),
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(message!),
                      ),
                  ],
                );
              },
            ),
      ),
    ),
  );
}
