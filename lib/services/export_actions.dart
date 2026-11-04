import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/staff.dart';
import '../state/app_state.dart';
import 'file_delivery.dart';

/// Saves [bytes] as [fileName] (save dialog on desktop, download on the
/// web) and reports the outcome in a snackbar. True when it was saved.
Future<bool> deliverFile(
  BuildContext context, {
  required String dialogTitle,
  required String fileName,
  required String extension,
  required Uint8List bytes,
}) async {
  try {
    final saved = await saveFileBytes(
      dialogTitle: dialogTitle,
      defaultName: fileName,
      extensions: [extension],
      bytes: bytes,
    );
    if (saved == null) return false;
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved $saved')));
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn’t save the file: $error')));
    }
    return false;
  }
}

/// Saves a full backup (.json) and records when, for the backup reminder.
Future<void> backupToFile(BuildContext context, WidgetRef ref) async {
  final result = ref.read(backupServiceProvider).backup();
  final saved = await deliverFile(
    context,
    dialogTitle: 'Back up data',
    fileName: result.suggestedName,
    extension: 'json',
    // UTF-8: codeUnits would silently corrupt non-ASCII staff names.
    bytes: Uint8List.fromList(utf8.encode(result.json)),
  );
  if (saved) ref.read(lastBackupProvider.notifier).markNow();
}

/// Exports one week in the original spreadsheet layout (.xlsx).
Future<void> exportWeekToFile(
  BuildContext context,
  WidgetRef ref,
  Week week,
) async {
  final result = ref
      .read(exportServiceProvider)
      .exportWeek(
        week,
        revenue: ref.read(seesRevenueProvider)
            ? ref
                  .read(revenueRepositoryProvider)
                  .entriesBetween(week.startDate, week.endDate)
            : null,
        currency: ref.read(currencyProvider),
      );
  await deliverFile(
    context,
    dialogTitle: 'Export week to Excel',
    fileName:
        'weekly_clients_${DateFormat('yyyyMMdd').format(week.startDate)}.xlsx',
    extension: 'xlsx',
    bytes: result.bytes,
  );
}
