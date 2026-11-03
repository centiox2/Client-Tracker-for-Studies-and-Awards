import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../repositories/auth_repository.dart';
import '../repositories/client_count_repository.dart';
import '../repositories/notes_settings_repository.dart';
import '../repositories/report_repository.dart';
import '../repositories/staff_repository.dart';
import '../repositories/time_off_repository.dart';
import '../repositories/week_repository.dart';
import '../services/backup_service.dart';
import '../services/export_service.dart';
import '../services/statistics_service.dart';

/// Initializes the database once at startup. Overridable in tests.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('Override in main() with the real database.');
});

final staffRepositoryProvider = Provider<StaffRepository>(
  (ref) => StaffRepository(ref.watch(databaseProvider)),
);

final weekRepositoryProvider = Provider<WeekRepository>(
  (ref) => WeekRepository(ref.watch(databaseProvider)),
);

final clientCountRepositoryProvider = Provider<ClientCountRepository>(
  (ref) => ClientCountRepository(ref.watch(databaseProvider)),
);

final timeOffRepositoryProvider = Provider<TimeOffRepository>(
  (ref) => TimeOffRepository(ref.watch(databaseProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(databaseProvider)),
);

final dayNotesRepositoryProvider = Provider<DayNotesRepository>(
  (ref) => DayNotesRepository(ref.watch(databaseProvider)),
);

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>(
  (ref) => AppSettingsRepository(ref.watch(databaseProvider)),
);

final reportRepositoryProvider = Provider<ReportRepository>(
  (ref) => ReportRepository(ref.watch(databaseProvider)),
);

final statisticsServiceProvider = Provider<StatisticsService>(
  (ref) => StatisticsService(ref.watch(clientCountRepositoryProvider)),
);

final exportServiceProvider = Provider<ExportService>((ref) {
  final counts = ref.watch(clientCountRepositoryProvider);
  return ExportService(counts.getWeekWithDays);
});

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(databaseProvider)),
);

// ---- Count-edit undo ----------------------------------------------------
///
/// An ordered undo buffer for count edits. Every [remember] push records the
/// *previous* value of one count cell before it is overwritten, so [pop] can
/// restore the most recent edit (global Ctrl+Z) or a specific cell (Clear on
/// that field). Kept short to bound memory.
final undoProvider = NotifierProvider<UndoBufferNotifier, UndoBuffer>(
  UndoBufferNotifier.new,
);

class UndoBufferNotifier extends Notifier<UndoBuffer> {
  @override
  UndoBuffer build() => UndoBuffer();

  /// Records that [key]'s value is about to change from [previous] to
  /// something new. Calling this again for the same [key] replaces the
  /// in-flight entry so the buffer always reflects the most recent edit for
  /// that cell.
  void remember(String key, int previous) {
    // Remove any earlier entry for the same cell so a second edit to the
    // same field replaces, rather than stacks, the undo candidate.
    state._removeKey(key);
    state._push(key, previous);
  }

  /// The most recent remembered edit (used by global Ctrl+Z). Removes it.
  (String key, int value)? popMostRecent() => state._pop();

  /// The previously committed value for [key], if one is buffered.
  int? pop(String key) {
    final idx = state._indexOfKey(key);
    if (idx == null) return null;
    final value = state._entries[idx].value;
    state._removeAt(idx);
    return value;
  }
}

class UndoBuffer {
  UndoBuffer();

  final List<_Entry> _entries = [];
  static const int _max = 32;

  void _push(String key, int value) {
    if (_entries.length == _max) {
      _entries.removeAt(0);
    }
    _entries.add(_Entry(key, value));
  }

  void _removeKey(String key) {
    final idx = _indexOfKey(key);
    if (idx != null) _removeAt(idx);
  }

  int? _indexOfKey(String key) {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].key == key) return i;
    }
    return null;
  }

  void _removeAt(int idx) => _entries.removeAt(idx);

  (String, int)? _pop() {
    if (_entries.isEmpty) return null;
    final e = _entries.removeLast();
    return (e.key, e.value);
  }
}

class _Entry {
  const _Entry(this.key, this.value);
  final String key;
  final int value;
}
