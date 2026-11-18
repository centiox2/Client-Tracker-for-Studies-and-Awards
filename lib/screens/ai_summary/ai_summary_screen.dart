import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../services/ai_summary_service.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';

String _stamp(Object? raw) {
  final date = DateTime.tryParse('$raw');
  return date == null
      ? '$raw'
      : '${DateFormat('d MMM y, HH:mm').format(date.toUtc().add(const Duration(hours: 3)))} Nairobi';
}

class AiSummaryPreview extends ConsumerWidget {
  const AiSummaryPreview({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!summaryAccessGranted(ref.watch(aiSummaryAccessProvider))) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(aiSummariesProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: AppPanel(
        title: 'AI daily summary',
        compactHeader: true,
        trailingWidget: IconButton(
          onPressed: () =>
              ref.read(appActionsProvider).selectTab(AppTab.aiSummary),
          tooltip: 'Read full summary',
          icon: const Icon(Icons.arrow_forward, size: 18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: state.when(
            loading: () => const Text('Loading AI summary…'),
            error: (_, _) => const Text(
              'Unable to load the summary. Open the summary page to retry.',
            ),
            data: (data) {
              final rows = data['summaries'] as List? ?? [];
              final latest = rows.firstOrNull as Map?;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summaryStatus(data)),
                  if (latest != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Latest · ${latest['summary_date']}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('${(latest['content'] as Map)['brief']}'),
                    const SizedBox(height: 8),
                    Text(
                      'AI generated · Data as of ${_stamp(latest['cutoff_at'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class AiSummaryScreen extends ConsumerStatefulWidget {
  const AiSummaryScreen({super.key});
  @override
  ConsumerState<AiSummaryScreen> createState() => _AiSummaryScreenState();
}

class _AiSummaryScreenState extends ConsumerState<AiSummaryScreen> {
  String? selected;
  @override
  Widget build(BuildContext context) {
    final access = ref.watch(aiSummaryAccessProvider);
    if (!summaryAccessGranted(access)) {
      return Center(
        child: Text(
          access.isLoading
              ? 'Checking access…'
              : 'Admin must assign AI summary access to your account.',
        ),
      );
    }
    return ref
        .watch(aiSummariesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Unable to load AI summaries.'),
                TextButton(
                  onPressed: () => ref.invalidate(aiSummariesProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (data) {
            final rows = (data['summaries'] as List? ?? []).cast<Map>();
            final row =
                rows.where((r) => r['summary_date'] == selected).firstOrNull ??
                rows.firstOrNull;
            final content = row?['content'] as Map?;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(summaryStatus(data)),
                        const SizedBox(height: 16),
                        if (rows.isNotEmpty)
                          DropdownButtonFormField<String>(
                            key: ValueKey(row!['summary_date']),
                            initialValue: '${row['summary_date']}',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Summary date',
                            ),
                            items: [
                              for (final r in rows)
                                DropdownMenuItem(
                                  value: '${r['summary_date']}',
                                  child: Text('${r['summary_date']}'),
                                ),
                            ],
                            onChanged: (v) => setState(() => selected = v),
                          ),
                        if (content != null) ...[
                          const SizedBox(height: 20),
                          Text(
                            '${content['brief']}',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'AI generated · Review against recorded data.\nData as of ${_stamp(row!['cutoff_at'])}\nModel: ${row['model']}',
                          ),
                          for (final pair in [
                            ('Highlights', 'highlights'),
                            ('Needs attention', 'risks'),
                            ('Suggested next steps', 'actions'),
                          ]) ...[
                            const SizedBox(height: 24),
                            Text(
                              pair.$1,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            for (final item
                                in (content[pair.$2] as List? ?? []))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text('• $item'),
                              ),
                          ],
                          for (final section
                              in (content['sections'] as List? ?? []))
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: AppPanel(
                                title: '${section['title']}',
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text('${section['body']}'),
                                ),
                              ),
                            ),
                          const SizedBox(height: 24),
                          ExpansionTile(
                            title: const Text(
                              'Recorded facts used in this summary',
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: SelectableText(
                                  const JsonEncoder.withIndent('  ')
                                      .convert(row['input_snapshot']),
                                ),
                              ),
                            ],
                          ),
                        ] else
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Text(
                              'No summary yet. Summaries will appear here once Gemini is configured and the scheduled run completes.',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
  }
}
