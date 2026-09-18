import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  @override
  AsyncValue<List<ConversionJob>> build() {
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
    _load();
    return const AsyncValue.loading();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiClientProvider);
      final jobs = await api.listJobs();
      final newlyDone = jobs.any((j) => j.state == JobState.done && _lastStates[j.jobId] != JobState.done);
      final newlyFailed = jobs
          .where((j) => j.state == JobState.failed && _lastStates[j.jobId] != JobState.failed)
          .toList();
      _lastStates = {for (final j in jobs) j.jobId: j.state};
      if (newlyDone) {
        ref.invalidate(localBooksProvider);
        ref.invalidate(catalogProvider);
      }
      // Finished jobs get a local notification (the server also pushes to
      // topic job-<id> when it has FCM credentials — belt and suspenders:
      // one of the two paths always fires). Best-effort: never fail a poll.
      if (newlyDone) {
        final done = jobs.firstWhere((j) => j.state == JobState.done);
        await _announceJobEnd(done, ok: true);
      }
      for (final j in newlyFailed) {
        await _announceJobEnd(j, ok: false);
      }
      state = AsyncValue.data(jobs);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> _announceJobEnd(ConversionJob j, {required bool ok}) async {
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic('job-${j.jobId}');
    } catch (_) {}
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
