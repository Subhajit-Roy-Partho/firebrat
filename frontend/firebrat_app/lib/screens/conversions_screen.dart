import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/job.dart';
import '../state/conversions_providers.dart';
import '../state/library_providers.dart';

/// Upload a PDF for conversion, and watch every job — queued, converting,
/// done, or failed — with live stage/progress and a retry action for
/// anything that needs another pass. This is the whole "manage the
/// conversion pipeline from the app" surface; the library screen only ever
/// shows books once they're fully done.
class ConversionsScreen extends ConsumerWidget {
  const ConversionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsProvider);
    final uploadProgress = ref.watch(uploadProgressProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Conversions')),
      body: RefreshIndicator(
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
                          'No conversions yet. Tap "Upload a PDF" to send a book to the server.',
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
      ),
      floatingActionButton: uploadProgress != null
          ? FloatingActionButton.extended(
              onPressed: null,
              icon: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, value: uploadProgress > 0 ? uploadProgress : null),
              ),
              label: Text('Uploading ${(uploadProgress * 100).round()}%'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _uploadPdf(context, ref),
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Upload a PDF'),
            ),
    );
  }

  Future<void> _uploadPdf(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: false);
    final path = result?.files.single.path;
    if (path == null) return; // user cancelled

    final progressNotifier = ref.read(uploadProgressProvider.notifier);
    progressNotifier.set(0.0);
    try {
      final api = ref.read(apiClientProvider);
      await api.uploadBook(path, onProgress: progressNotifier.set);
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
              Text(
                _stageLabel(job),
                style: Theme.of(context).textTheme.bodySmall,
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
      await ref.read(jobsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Retry failed: $e')));
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
