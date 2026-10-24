import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reading_checkpoint.dart';

/// Local-first, account-isolated checkpoints. No book text or files are saved.
/// Local writes are throttled by the reader; cloud writes are at most once
/// per two minutes, or an explicit pause/section change (15-second minimum).
class ReadingProgressStore {
  final String scope;
  final String bookId;
  final Future<ReadingCheckpoint?> Function()? readRemote;
  final Future<bool> Function(ReadingCheckpoint)? writeRemote;
  final Future<bool> Function()? enabled;
  final DateTime Function() now;
  DateTime? _lastAttempt;
  bool _uploading = false;
  bool _forceAfterUpload = false;
  ReadingCheckpoint? _latest;
  ReadingCheckpoint? _uploaded;
  Timer? _pendingFlush;

  ReadingProgressStore({
    required this.scope,
    required this.bookId,
    this.readRemote,
    this.writeRemote,
    this.enabled,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  String get key => 'reader.checkpoint.$scope.$bookId';

  Future<ReadingCheckpoint?> restore(String signature) async {
    final prefs = await SharedPreferences.getInstance();
    ReadingCheckpoint? local;
    try {
      local = ReadingCheckpoint.fromJson(
        jsonDecode(prefs.getString(key) ?? 'null'),
      );
    } catch (_) {
      /* Damaged optional progress must not prevent opening a book. */
    }
    ReadingCheckpoint? remote;
    if (readRemote != null && (await enabled?.call() ?? true)) {
      try {
        remote = await readRemote!().timeout(const Duration(seconds: 3));
      } catch (_) {
        /* Keep offline progress; retry on a later save/open. */
      }
    }
    final selected = newestCheckpoint(local, remote, signature);
    _latest = selected;
    _uploaded = remote;
    if (selected != null) {
      await prefs.setString(key, jsonEncode(selected.toJson()));
    }
    return selected;
  }

  Future<void> save(ReadingCheckpoint checkpoint, {bool force = false}) async {
    _latest = checkpoint;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(checkpoint.toJson()));
    if (writeRemote == null || !(await enabled?.call() ?? true)) return;
    if (_uploading) {
      _forceAfterUpload = _forceAfterUpload || force;
      return;
    }
    final current = _latest!;
    if (_uploaded?.sectionId == current.sectionId &&
        _uploaded?.positionMs == current.positionMs &&
        _uploaded?.signature == current.signature) {
      return;
    }
    final minimum = Duration(seconds: force ? 15 : 120);
    if (_lastAttempt != null && now().difference(_lastAttempt!) < minimum) {
      if (force && _pendingFlush == null) {
        _pendingFlush = Timer(minimum - now().difference(_lastAttempt!), () {
          _pendingFlush = null;
          final latest = _latest;
          if (latest != null) unawaited(save(latest, force: true));
        });
      }
      return;
    }
    _pendingFlush?.cancel();
    _pendingFlush = null;
    _lastAttempt = now();
    _uploading = true;
    // Never block reading on a network write. The local checkpoint is durable.
    unawaited(() async {
      try {
        if (await writeRemote!(current).timeout(const Duration(seconds: 5))) {
          _uploaded = current;
        }
      } catch (_) {
        /* Durable local progress remains available for retry. */
      } finally {
        _uploading = false;
        if (_forceAfterUpload) {
          _forceAfterUpload = false;
          final latest = _latest;
          if (latest != null) unawaited(save(latest, force: true));
        }
      }
    }());
  }
}
