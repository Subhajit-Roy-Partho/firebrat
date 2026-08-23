import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/job.dart';
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
      _lastStates = {for (final j in jobs) j.jobId: j.state};
      if (newlyDone) {
        ref.invalidate(localBooksProvider);
        ref.invalidate(catalogProvider);
      }
      state = AsyncValue.data(jobs);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
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
