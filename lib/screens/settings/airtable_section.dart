import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/airtable_sync_service.dart';
import '../../widgets/panels.dart';

/// Settings › Airtable (admins): when the Applications Tracker was last read,
/// and how many of this month's Airtable API calls are used.
class AirtableSection extends ConsumerStatefulWidget {
  const AirtableSection({super.key});

  @override
  ConsumerState<AirtableSection> createState() => _AirtableSectionState();
}

class _AirtableSectionState extends ConsumerState<AirtableSection> {
  bool _busy = false;

  static String _when(DateTime? t) =>
      t == null ? 'not yet' : DateFormat('d MMM, h:mm a').format(t);

  Future<void> _readAll() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await ref.read(airtableSyncProvider).syncNow(full: true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.error != null
                ? describeAirtableError(r.error!)
                : r.skipped != null
                ? 'A sync is already running. Try again in a minute.'
                : 'Read all ${r.total} applications (${r.calls} calls)'
                      '${r.nothingChanged ? ' — no changes' : ''}.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeAirtableError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
      ref.invalidate(airtableStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    final async = ref.watch(airtableStatusProvider);
    final s = async.value;
    return AppPanel(
      title: 'Airtable',
      icon: Icons.sync_alt,
      trailing: s == null || !s.enabled
          ? null
          : '${s.callsThisMonth} of ${s.limit} calls',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Applications come straight from the Airtable Applications '
              'Tracker: what changed every 30 minutes on weekdays (8 am to '
              '6:30 pm) and hourly on Saturdays (8 am to 6 pm), and '
              'everything every night at 2 am. '
              'Airtable’s free plan allows ${s?.limit ?? 1000} API calls a '
              'month; above ${s?.slowAt ?? 700} it reads once an hour, and '
              'above ${s?.stopAt ?? 850} it waits for next month (the CSV '
              'upload still works).',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (async.isLoading && s == null)
              const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (s == null)
              Text(
                'Can’t check right now — it needs the internet.',
                style: muted,
              )
            else if (!s.enabled)
              Text('The Airtable sync is switched off.', style: muted)
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  key: const ValueKey('airtable-usage'),
                  value: (s.callsThisMonth / s.limit).clamp(0, 1).toDouble(),
                  minHeight: 8,
                  color: s.paused
                      ? theme.colorScheme.error
                      : s.slowedDown
                      ? Colors.orange
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${s.callsThisMonth} of ${s.limit} API calls used this month'
                '${s.paused
                    ? ' — paused until the 1st'
                    : s.slowedDown
                    ? ' — reading once an hour'
                    : ''}.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Text(
                'Last synced: ${_when(s.lastOkAt)} · Last full read: '
                '${_when(s.lastFullAt)}',
                style: muted,
              ),
              if (s.failing) ...[
                const SizedBox(height: 8),
                Text(
                  'Last try (${_when(s.lastErrorAt)}): '
                  '${describeAirtableError(s.lastError!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('airtable-read-all'),
                  onPressed: _busy ? null : _readAll,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined, size: 16),
                  label: const Text('Read everything now'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Also picks up records deleted in Airtable (normally caught '
                'at night). Uses about one call per 100 applications.',
                style: muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
