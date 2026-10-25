import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart' show CharacterTraits, isEbookPath;
import '../models/job.dart';
import '../state/conversions_providers.dart';
import '../state/library_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/on_device_pipeline_run_provider.dart';
import '../state/on_device_queue_provider.dart';
import '../widgets/battery_notice.dart';
import '../state/guest_access_provider.dart';
import '../services/auth_service.dart';
import '../services/integrity_service.dart';
import 'conversion_detail_screen.dart';
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
    final isOnDevice = conversionMode.mode == ConversionModePref.onDevice;
    // Server uploads are one at a time; on-device conversions queue, so adding
    // another book is always possible there.
    final busy = uploadProgress != null;
    final queue = ref.watch(onDeviceQueueProvider);
    final queueActive = queue.any((i) => i.status == QueueStatus.queued || i.status == QueueStatus.running);
    final isOffline = conversionMode.mode == ConversionModePref.offline;
    final needsServerSignIn = !isOffline && !isOnDevice &&
        AuthService.instance.currentUser == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Conversion settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConversionSettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (isOnDevice && (queueActive || onDeviceRun != null && !onDeviceRun.done)) const BatteryNotice(),
          if (isOnDevice && onDeviceRun != null && !onDeviceRun.done) _OnDeviceRunBanner(state: onDeviceRun),
          // Server job queue is meaningless in on-device mode (nothing is
          // uploaded anywhere) — polling it here is what made the screen
          // "still look for the server". On-device runs surface above.
          Expanded(
            child: isOffline
                ? const Center(child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Offline mode: import finished book files from your library. '
                        'Choose Server or On-device in settings to convert new books.',
                        textAlign: TextAlign.center),
                  ))
                : isOnDevice
                ? const _OnDeviceQueue()
                : needsServerSignIn
                ? Center(child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Server conversion requires sign-in. Guest mode can read, '
                          'import, download public server books and convert on this device.',
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: () {
                        ref.read(guestAccessProvider.notifier).setGuest(false);
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      }, child: const Text('Sign in for server conversion')),
                      TextButton(onPressed: () {
                        ref.read(conversionModeProvider.notifier).setMode(ConversionModePref.onDevice);
                      }, child: const Text('Use on-device conversion')),
                    ]),
                  ))
                : const _ServerJobsList(),
          ),
        ],
      ),
      floatingActionButton: isOffline || needsServerSignIn ? null : (busy && !isOnDevice)
          ? FloatingActionButton.extended(
              onPressed: null,
              icon: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: uploadProgress > 0 ? uploadProgress : null,
                ),
              ),
              label: Text('Uploading ${(uploadProgress * 100).round()}%'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _pickAndConvert(context, ref, conversionMode.mode),
              icon: Icon(isOnDevice && queueActive ? Icons.playlist_add_rounded : Icons.upload_file_rounded),
              label: Text(isOnDevice && queueActive ? 'Add to queue' : 'Convert a book'),
            ),
    );
  }

  Future<void> _pickAndConvert(BuildContext context, WidgetRef ref, ConversionModePref mode) async {
    if (mode == ConversionModePref.offline) return;
    // file_picker 12 returns the picked files directly (empty = cancelled).
    // Both modes accept a PDF, a .zip of chapter PDFs (cloud uploads merge
    // server-side, on-device unzips locally and merges at the text layer),
    // or a DRM-free EPUB / MOBI / AZW / AZW3 book (text only, no pictures).
    // FileType.any, then check the extension ourselves: Android's picker has no
    // MIME type for .azw/.azw3 (and sometimes .mobi), so a custom-extension
    // filter would hide Kindle files entirely.
    // On-device conversions queue, so several books can be picked at once.
    final onDevice = mode == ConversionModePref.onDevice;
    final List<PlatformFile> files;
    if (onDevice) {
      files = await FilePicker.pickFiles(type: FileType.any);
    } else {
      final one = await FilePicker.pickFile(type: FileType.any);
      files = one == null ? const [] : [one];
    }
    if (files.isEmpty) return; // user cancelled
    bool supported(String p) {
      final lower = p.toLowerCase();
      return lower.endsWith('.pdf') || lower.endsWith('.zip') || isEbookPath(lower);
    }

    final paths = [for (final f in files) if (f.path != null) f.path!];
    final good = paths.where(supported).toList();
    if (!context.mounted) return;
    if (good.length < paths.length) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(good.isEmpty
            ? 'Choose a PDF, a ZIP of PDFs, or an EPUB, MOBI, AZW or AZW3 book.'
            : 'Skipped ${paths.length - good.length} file(s) that are not a PDF, ZIP or ebook.'),
      ));
    }
    if (good.isEmpty) return;
    if (onDevice) {
      // Tell the user once, before the first book starts, how to keep it running.
      await explainBatteryIfNeeded(context, ref);
      ref.read(onDeviceQueueProvider.notifier).enqueue(good);
      if (good.length > 1 && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${good.length} books to the queue.')));
      }
    } else {
      await _uploadFile(context, ref, good.first);
    }
  }

  Future<void> _uploadFile(BuildContext context, WidgetRef ref, String path) async {
    final progressNotifier = ref.read(uploadProgressProvider.notifier);
    progressNotifier.set(0.0);
    try {
      // Tokens are optional until server verification is configured. Normal
      // Firebase/server authorization still applies to every upload.
      final integrity = ref.read(integrityServiceProvider);
      final fileName = path.split('/').last;
      final mint = await integrity.mintForRemote(
        requestHash: IntegrityService.requestHashForString(
          'upload:$fileName:${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      if (!integrity.allowsRemote(mint)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(IntegrityService.userMessageFor(mint))));
        }
        return;
      }
      final api = ref.read(apiClientProvider);
      final mode = ref.read(conversionModeProvider);
      final job = await api.uploadBook(path,
        contentMode: mode.contentMode,
        provider: mode.mode == ConversionModePref.cloud ? mode.serverProvider : null,
        model: mode.mode == ConversionModePref.cloud ? mode.serverLlmModel : null,
        integrityToken: mint.token,
        researchCharacters: mode.mode == ConversionModePref.cloud && mode.researchCharacters,
        characterTraits: _traitLines(mode.characterVoices),
        onProgress: progressNotifier.set);
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
/// The on-device queue: the book converting now, the ones waiting, and what
/// just finished. Books are converted one at a time, in order.
class _OnDeviceQueue extends ConsumerWidget {
  const _OnDeviceQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(onDeviceQueueProvider);
    final run = ref.watch(onDeviceRunProvider);
    final notifier = ref.read(onDeviceQueueProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'On-device mode: conversions run on this phone, one after another, and finished '
                'books appear in your library.\n\nTap "Convert a book" to start. You can pick several at once, '
                'and add more while one is converting. Choose a PDF, a ZIP of chapter PDFs (merged automatically), '
                'or a DRM-free EPUB, MOBI, AZW or AZW3 ebook.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    }
    final finished = items.where((i) => i.status != QueueStatus.queued && i.status != QueueStatus.running).length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final item in items)
          ListTile(
            key: ValueKey('queue-${item.id}'),
            leading: switch (item.status) {
              QueueStatus.running => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
              QueueStatus.queued => Icon(Icons.schedule_rounded, color: scheme.onSurfaceVariant),
              QueueStatus.done => const Icon(Icons.check_circle_rounded, color: Colors.green),
              QueueStatus.failed => Icon(Icons.error_rounded, color: scheme.error),
              QueueStatus.cancelled => Icon(Icons.stop_circle_outlined, color: scheme.onSurfaceVariant),
            },
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ConversionDetailScreen(itemId: item.id)),
            ),
            title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(switch (item.status) {
              QueueStatus.running => run?.detail ?? run?.stage ?? 'Converting…',
              QueueStatus.queued => 'Waiting',
              QueueStatus.done => 'Done. It is in your library.',
              QueueStatus.failed => 'Failed: ${item.error ?? 'unknown error'}',
              QueueStatus.cancelled => 'Stopped',
            }, maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: switch (item.status) {
              QueueStatus.running => IconButton(
                  tooltip: 'Stop this conversion',
                  icon: const Icon(Icons.stop_rounded),
                  onPressed: () => notifier.stopCurrent(),
                ),
              QueueStatus.queued => IconButton(
                  tooltip: 'Remove from the queue',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => notifier.remove(item.id),
                ),
              _ => IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => notifier.remove(item.id),
                ),
            },
          ),
        if (finished > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: notifier.clearFinished,
              icon: const Icon(Icons.clear_all_rounded),
              label: const Text('Clear finished'),
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
                        'No conversions yet. Tap "Convert a book" to convert a book.',
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

class _OnDeviceRunBanner extends ConsumerWidget {
  final OnDeviceRunState state;
  const _OnDeviceRunBanner({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
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
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: () => ref.read(onDeviceQueueProvider.notifier).stopCurrent(),
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Stop'),
          ),
        ],
      ),
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
              LinearProgressIndicator(value: job.progress ?? 0),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: Text(_stageLabel(job), style: Theme.of(context).textTheme.bodySmall)),
                  if (job.progress != null)
                    Text('${(job.progress! * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
                  if (job.state == JobState.queued)
                    TextButton(
                      onPressed: () => _convertNow(context, ref),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      child: const Text('Convert this now', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _confirmCancel(context, ref),
                  icon: Icon(
                    job.state == JobState.queued ? Icons.delete_outline_rounded : Icons.stop_circle_outlined,
                    size: 18,
                  ),
                  label: Text(job.state == JobState.queued ? 'Delete' : 'Stop'),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
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
      _ => job.state == JobState.queued ? 'Queued for LLM compilation' : 'Starting',
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

  Future<void> _convertNow(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).convertNow(job.jobId);
      await JobsNotifier.trackJob(job.jobId);
      await ref.read(jobsProvider.notifier).refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Jumped to the front — converting next.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Convert now failed: $e')));
      }
    }
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final isQueued = job.state == JobState.queued;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isQueued ? 'Delete this conversion?' : 'Stop this conversion?'),
        content: Text(isQueued
            ? '"${job.title}" is still waiting in the queue and has not started. Delete it so it never runs?'
            : '"${job.title}" is converting right now. Stopping discards whatever is done so far.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isQueued ? 'Delete' : 'Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).cancelJob(job.jobId);
      await ref.read(jobsProvider.notifier).refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isQueued ? 'Removed from the queue.' : 'Conversion stopped.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isQueued ? 'Delete failed: $e' : 'Stop failed: $e')),
        );
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


/// "Name=elder gruff" lines for the server, from the voice-override entries.
/// Voice preset names mean nothing to the server's reference-clip voices, so
/// only the trait words (age, temperament, gender) are sent.
String _traitLines(Map<String, String> overrides) {
  final lines = <String>[];
  overrides.forEach((name, value) {
    final words = value
        .split(RegExp(r'[,\s]+'))
        .where((w) => w.isNotEmpty && CharacterTraits.parseWords([w]) != null)
        .toList();
    if (words.isNotEmpty) lines.add('$name=${words.join(' ')}');
  });
  return lines.join('\n');
}
