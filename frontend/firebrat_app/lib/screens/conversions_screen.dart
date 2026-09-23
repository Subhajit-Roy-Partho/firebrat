import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/job.dart';
import '../state/conversions_providers.dart';
import '../state/library_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/on_device_pipeline_run_provider.dart';
import 'conversion_settings_screen.dart';

/// Upload a PDF (or a ZIP of PDFs, merged server-side) for conversion,
/// and watch every job — queued, converting,
/// done, or failed — with live stage/progress and a retry action for
/// anything that needs another pass. This is the whole "manage the
/// conversion pipeline from the app" surface; the library screen only ever
/// shows books once they're fully done.
class ConversionsScreen extends ConsumerWidget {
  const ConversionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploadProgress = ref.watch(uploadProgressProvider);
    final conversionMode = ref.watch(conversionModeProvider);
    final onDeviceRun = ref.watch(onDeviceRunProvider);
    final busy = uploadProgress != null || (onDeviceRun != null && !onDeviceRun.done);
    final isOnDevice = conversionMode.mode == ConversionModePref.onDevice;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Conversion settings (cloud vs on-device)',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConversionSettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (onDeviceRun != null && !onDeviceRun.done) _OnDeviceRunBanner(state: onDeviceRun),
          if (onDeviceRun?.error != null) _OnDeviceErrorBanner(message: onDeviceRun!.error!),
          // Server job queue is meaningless in on-device mode (nothing is
          // uploaded anywhere) — polling it here is what made the screen
          // "still look for the server". On-device runs surface above.
          Expanded(
            child: isOnDevice
                ? const _OnDeviceJobsPlaceholder()
                : const _ServerJobsList(),
          ),
        ],
      ),
      floatingActionButton: busy
          ? FloatingActionButton.extended(
              onPressed: null,
              icon: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: uploadProgress != null && uploadProgress > 0 ? uploadProgress : null,
                ),
              ),
              label: Text(uploadProgress != null ? 'Uploading ${(uploadProgress * 100).round()}%' : 'Converting…'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _pickAndConvert(context, ref, conversionMode.mode),
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Convert a PDF or ZIP'),
            ),
    );
  }

  Future<void> _pickAndConvert(BuildContext context, WidgetRef ref, ConversionModePref mode) async {
    // file_picker 12 returns the picked files directly (empty = cancelled).
    // Both modes accept a .zip of chapter PDFs: cloud uploads merge
    // server-side, on-device unzips locally and merges at the text layer.
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'zip']);
    if (files.isEmpty) return; // user cancelled
    final path = files.single.path;
    if (path == null) return;

    if (!context.mounted) return;
    if (mode == ConversionModePref.onDevice) {
      await _convertOnDevice(context, ref, path);
    } else {
      await _uploadFile(context, ref, path);
    }
  }

  Future<void> _convertOnDevice(BuildContext context, WidgetRef ref, String path) async {
    try {
      if (path.toLowerCase().endsWith('.zip')) {
        final chapters = await unpackZipChapters(path);
        final zipStem = path.split('/').last.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
        await runOnDeviceConversion(ref, chapters, titleOverride: zipStem);
      } else {
        await runOnDeviceConversion(ref, [path]);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Converted — check your library.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('On-device conversion failed: $e')));
      }
    }
  }

  Future<void> _uploadFile(BuildContext context, WidgetRef ref, String path) async {
    final progressNotifier = ref.read(uploadProgressProvider.notifier);
    progressNotifier.set(0.0);
    try {
      final api = ref.read(apiClientProvider);
      final job = await api.uploadBook(path, onProgress: progressNotifier.set);
      // Follow this job's FCM topic so the server's done/failed push finds
      // the device even with this screen closed.
      await JobsNotifier.trackJob(job.jobId);
      await ref.read(jobsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      progressNotifier.set(null);
    }
  }
}

/// Shown instead of the server queue when conversion mode is on-device:
/// there is no server involved, so polling GET /jobs would only produce a
/// connection error. On-device runs surface as banners above.
class _OnDeviceJobsPlaceholder extends StatelessWidget {
  const _OnDeviceJobsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 120),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'On-device mode: conversions run on this phone and finished '
              'books appear in your library.\n\nTap "Convert a PDF or ZIP" to start one — a ZIP of chapter PDFs is merged automatically.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}

/// The server job queue — only ever built in cloud mode, so it never fires
/// a request (or shows an error) when the user converts on-device.
class _ServerJobsList extends ConsumerWidget {
  const _ServerJobsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.read(jobsProvider.notifier).refresh(),
      child: jobsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => _ErrorView(message: 'Could not reach the server.\n$err'),
        data: (jobs) {
          if (jobs.isEmpty) {
            return LayoutBuilder(
              builder: (context, _) => ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'No conversions yet. Tap "Convert a PDF or ZIP" to convert a book.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: jobs.length,
            itemBuilder: (context, i) => _JobCard(job: jobs[i]),
          );
        },
      ),
    );
  }
}

class _OnDeviceRunBanner extends StatelessWidget {  final OnDeviceRunState state;
  const _OnDeviceRunBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.phone_android_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(state.stage ?? 'Converting on this device…', style: Theme.of(context).textTheme.titleSmall)),
            ],
          ),
          if (state.detail != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(state.detail!)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: state.fraction),
        ],
      ),
    );
  }
}

class _OnDeviceErrorBanner extends StatelessWidget {
  final String message;
  const _OnDeviceErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}

class _JobCard extends ConsumerWidget {
  final ConversionJob job;
  const _JobCard({required this.job});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (chipColor, chipLabel, icon) = switch (job.state) {
      JobState.queued => (scheme.outline, 'Queued', Icons.hourglass_empty_rounded),
      JobState.running => (scheme.primary, 'Converting', Icons.autorenew_rounded),
      JobState.done => (Colors.green, 'Done', Icons.check_circle_rounded),
      JobState.failed => (scheme.error, 'Failed', Icons.error_rounded),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: chipColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(job.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Chip(
                  label: Text(chipLabel),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: chipColor.withValues(alpha: 0.15),
                  side: BorderSide.none,
                  labelStyle: TextStyle(color: chipColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(job.filename, style: Theme.of(context).textTheme.bodySmall),
            if (job.isActive) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: job.progress),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: Text(_stageLabel(job), style: Theme.of(context).textTheme.bodySmall)),
                  TextButton(
                    onPressed: () => _resume(context, ref),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    child: const Text('Looks stuck? Resume', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
            if (job.state == JobState.done) ...[
              const SizedBox(height: 8),
              Text(job.detail ?? 'Conversion complete.', style: Theme.of(context).textTheme.bodySmall),
              if (job.needsReviewCount > 0) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.flag_rounded, size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${job.needsReviewCount} section${job.needsReviewCount == 1 ? '' : 's'} need review — narration is a plain fallback there.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
            if (job.state == JobState.failed) ...[
              const SizedBox(height: 8),
              Text(
                job.error ?? 'Unknown error.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (job.isRetryable && (job.state == JobState.failed || job.needsReviewCount > 0)) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _retry(context, ref),
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: Text(job.state == JobState.failed ? 'Retry' : 'Retry needs-review sections'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _stageLabel(ConversionJob job) {
    final stage = switch (job.stage) {
      'extracting' => 'Extracting pages',
      'compiling' => 'Writing narration',
      'rendering_formulas' => 'Rendering formulas',
      'synthesizing' => 'Recording narration',
      'packaging' => 'Packaging',
      _ => job.state == JobState.queued ? 'Waiting for a conversion slot' : 'Starting',
    };
    return job.detail != null ? '$stage — ${job.detail}' : stage;
  }

  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).retryJob(job.jobId);
      await JobsNotifier.trackJob(job.jobId);
      await ref.read(jobsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Retry failed: $e')));
      }
    }
  }

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).resumeJob(job.jobId);
      await JobsNotifier.trackJob(job.jobId);
      await ref.read(jobsProvider.notifier).refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Put back on the queue.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Resume failed: $e')));
      }
    }
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
