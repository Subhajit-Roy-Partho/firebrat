import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/job.dart';
import '../services/notification_service.dart';
import 'library_providers.dart' show apiClientProvider, localBooksProvider, catalogProvider;

/// Polls GET /jobs every couple of seconds while something is watching it
/// (autoDispose — the poll stops the moment the Conversions screen is
/// closed) so upload progress, stage, and errors stay live without the user
/// having to pull-to-refresh. Whenever a job newly reaches "done", the
/// local library listing is invalidated so the finished book shows up on
/// the library screen without a manual refresh there either.
class JobsNotifier extends Notifier<AsyncValue<List<ConversionJob>>> {
  Timer? _timer;
  Map<String, JobState> _lastStates = {};

  /// Job ids already announced as finished/failed, mirrored in
  /// SharedPreferences so a provider remount (autoDispose wipes this
  /// instance's [_lastStates]) never re-announces the same job.
  Set<String> _notifiedDone = {};
  Set<String> _notifiedFailed = {};
  bool _prefsLoaded = false;

  /// First poll after (re)mount only establishes a baseline — a job that
  /// is *already* done when the screen opens is never announced. Only a
  /// transition observed live (queued/running → done/failed) announces.
  bool _hasBaseline = false;
  bool _inFlight = false;

  /// Test-only seam: when set, [_announceJobEnd] records through here
  /// instead of showing a real local notification.
  @visibleForTesting
  static Future<void> Function(String title, String body)? announceHook;

  /// SharedPreferences keys for the announced-job dedup sets.
  @visibleForTesting
  static const notifiedDoneKey = 'notified_done_job_ids';
  @visibleForTesting
  static const notifiedFailedKey = 'notified_failed_job_ids';

  @override
  AsyncValue<List<ConversionJob>> build() {
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
    _load();
    return const AsyncValue.loading();
  }

  Future<void> _load() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      await _ensureNotifiedPrefs();
      final api = ref.read(apiClientProvider);
      final jobs = await api.listJobs();
      // A true transition needs a previously *seen* non-terminal state.
      // Unknown ids (first poll after mount) only seed the baseline.
      final newlyDone = _hasBaseline
          ? jobs
              .where((j) =>
                  j.state == JobState.done &&
                  (_lastStates[j.jobId] == JobState.queued ||
                      _lastStates[j.jobId] == JobState.running) &&
                  !_notifiedDone.contains(j.jobId))
              .toList()
          : const <ConversionJob>[];
      final newlyFailed = _hasBaseline
          ? jobs
              .where((j) =>
                  j.state == JobState.failed &&
                  (_lastStates[j.jobId] == JobState.queued ||
                      _lastStates[j.jobId] == JobState.running) &&
                  !_notifiedFailed.contains(j.jobId))
              .toList()
          : const <ConversionJob>[];
      _lastStates = {for (final j in jobs) j.jobId: j.state};
      _hasBaseline = true;
      if (newlyDone.isNotEmpty) {
        ref.invalidate(localBooksProvider);
        ref.invalidate(catalogProvider);
      }
      // Finished jobs get a local notification (the server also pushes to
      // topic job-<id> when it has FCM credentials — belt and suspenders:
      // one of the two paths always fires). Best-effort: never fail a poll.
      // Each job id is announced at most once ever (persisted set below).
      for (final j in newlyDone) {
        await _announceJobEnd(j, ok: true);
        _notifiedDone.add(j.jobId);
      }
      for (final j in newlyFailed) {
        await _announceJobEnd(j, ok: false);
        _notifiedFailed.add(j.jobId);
      }
      if (newlyDone.isNotEmpty) await _persistNotifiedPrefs();
      if (newlyFailed.isNotEmpty) await _persistNotifiedPrefs();
      state = AsyncValue.data(jobs);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    } finally {
      _inFlight = false;
    }
  }

  /// Merges the persisted announced-ids with this mount's in-memory view,
  /// so autoDispose remounts stay quiet about already-announced jobs.
  Future<void> _ensureNotifiedPrefs() async {
    if (_prefsLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _notifiedDone = (prefs.getStringList(notifiedDoneKey) ?? const []).toSet();
      _notifiedFailed = (prefs.getStringList(notifiedFailedKey) ?? const []).toSet();
    } catch (_) {}
    _prefsLoaded = true;
  }

  Future<void> _persistNotifiedPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(notifiedDoneKey, _notifiedDone.toList());
      await prefs.setStringList(notifiedFailedKey, _notifiedFailed.toList());
    } catch (_) {}
  }

  Future<void> _announceJobEnd(ConversionJob j, {required bool ok}) async {
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic('job-${j.jobId}');
    } catch (_) {}
    final hook = announceHook;
    if (hook != null) {
      try {
        await hook(
          ok ? 'Conversion finished' : 'Conversion failed',
          ok ? '${j.title} is ready to download.' : '${j.title} failed — open Jobs to retry.',
        );
      } catch (_) {}
      return;
    }
    try {
      await NotificationService.showLocal(
        ok ? 'Conversion finished' : 'Conversion failed',
        ok ? '${j.title} is ready to download.' : '${j.title} failed — open Jobs to retry.',
      );
    } catch (_) {}
  }

  /// Call right after creating/uploading: subscribes this device to the
  /// job's FCM topic so the server's done/failed push finds it even with
  /// the Jobs screen closed. Safe to call repeatedly (idempotent).
  static Future<void> trackJob(String jobId) async {
    try {
      await FirebaseMessaging.instance.subscribeToTopic('job-$jobId');
    } catch (_) {}
  }

  Future<void> refresh() => _load();
}

final jobsProvider =
    NotifierProvider.autoDispose<JobsNotifier, AsyncValue<List<ConversionJob>>>(JobsNotifier.new);

/// Tracks upload progress (0.0-1.0) for an in-flight upload, separate from
/// the job list since it only applies before the job even exists server-side.
class UploadProgressNotifier extends Notifier<double?> {
  @override
  double? build() => null;
  void set(double? p) => state = p;
}

final uploadProgressProvider = NotifierProvider<UploadProgressNotifier, double?>(UploadProgressNotifier.new);
