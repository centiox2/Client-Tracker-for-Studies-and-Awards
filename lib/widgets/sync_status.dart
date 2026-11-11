import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_theme.dart';
import '../state/cloud_sync.dart';
import 'clarity.dart';

/// "Synced 10:42" / "Offline" / "3 waiting" — the online sync at a glance,
/// in the top bar. Hidden when sync is off.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key, this.compact = false});

  /// Icon only (phones).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(cloudSyncProvider);
    if (s.phase == SyncPhase.off) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final (icon, color, label, tip) = describeSync(s, theme);
    final tone = switch (s.phase) {
      SyncPhase.live when s.pending > 0 && !s.adminLinked => PillTone.warning,
      SyncPhase.live when s.pending == 0 => PillTone.positive,
      SyncPhase.error => PillTone.negative,
      _ => PillTone.neutral,
    };
    return Tooltip(
      message: tip,
      child: InkWell(
        key: const ValueKey('sync-status'),
        borderRadius: BorderRadius.circular(Dt.rPill),
        onTap: () => ref.read(cloudSyncProvider.notifier).syncNow(),
        child: compact
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(icon, size: 18, color: color ?? muted),
              )
            : StatusChip(label: label, icon: icon, tone: tone),
      ),
    );
  }
}

/// Icon, colour (null = muted), short label and explanation for [s].
(IconData, Color?, String, String) describeSync(
  CloudSyncState s,
  ThemeData theme,
) {
  final time = s.lastSynced == null
      ? ''
      : DateFormat('HH:mm').format(s.lastSynced!);
  final waiting = s.pending == 1 ? '1 change' : '${s.pending} changes';
  return switch (s.phase) {
    SyncPhase.off => (Icons.cloud_off_outlined, null, 'Not synced', ''),
    SyncPhase.connecting => (
      Icons.cloud_sync_outlined,
      null,
      'Connecting…',
      'Connecting to the online database',
    ),
    SyncPhase.live when s.pending > 0 && s.adminLinked => (
      Icons.cloud_upload_outlined,
      null,
      'Sending…',
      'Sending $waiting',
    ),
    SyncPhase.live when s.pending > 0 => (
      Icons.cloud_upload_outlined,
      theme.colorScheme.error,
      '$waiting waiting',
      'Sign in as admin to send $waiting online',
    ),
    SyncPhase.live => (
      Icons.cloud_done_outlined,
      Dt.statusGreen(theme.brightness),
      time.isEmpty ? 'Synced' : 'Synced $time',
      'Up to date with the online database. Click to check again.',
    ),
    SyncPhase.offline => (
      Icons.cloud_off_outlined,
      null,
      s.pending > 0 ? 'Offline · $waiting' : 'Offline',
      'No connection. Everything keeps working here and catches up when '
          'the connection is back.',
    ),
    SyncPhase.error => (
      Icons.error_outline,
      theme.colorScheme.error,
      'Sync problem',
      s.message ?? 'Something went wrong syncing. See Settings.',
    ),
  };
}
