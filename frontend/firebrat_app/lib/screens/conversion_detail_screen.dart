import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../state/library_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/reader_providers.dart';
import 'reader_screen.dart';
import '../state/on_device_pipeline_run_provider.dart';
import '../state/on_device_queue_provider.dart';

/// Opens a book that is still being converted, so the sections already
/// narrated can be played while the rest is made.
void openPartialBook(BuildContext context, WidgetRef ref, String bookId) {
  ref.invalidate(readerControllerProvider(bookId));
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(bookId: bookId)));
}

/// The stages of an on-device conversion, in order, as the pipeline reports them.
typedef ConversionStep = ({String key, String title, String hint});

List<ConversionStep> conversionSteps({required bool novel}) => [
      (
        key: 'extracting',
        title: 'Reading the book',
        hint: novel
            ? 'Reads the text (OCR for scanned pages), finds who speaks, researches the characters online and casts their voices.'
            : 'Reads the text of every page and keeps a picture of each page.',
      ),
      (
        key: 'compiling',
        title: novel ? 'Preparing the text' : 'Writing the narration',
        hint: novel
            ? 'Keeps the original wording and splits it into sections by speaker.'
            : 'Turns the pages into narration, section by section.',
      ),
      (
        key: 'synthesizing',
        title: 'Recording the narration',
        hint: 'Speaks every section with the chosen voice. This is the longest step for a full book.',
      ),
      (
        key: 'done',
        title: 'Finishing up',
        hint: 'Saves the book into your library.',
      ),
    ];

/// How far a conversion has got: -1 before the first stage, else the step index.
int stepIndexFor(String? stage, List<ConversionStep> steps) => steps.indexWhere((s) => s.key == stage);

String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

/// Everything about one queued book: where it is in the queue, which steps are
/// finished, which is running now and which are still to come, with timing and
/// the activity log.
class ConversionDetailScreen extends ConsumerStatefulWidget {
  final String itemId;
  const ConversionDetailScreen({super.key, required this.itemId});

  @override
  ConsumerState<ConversionDetailScreen> createState() => _ConversionDetailScreenState();
}

class _ConversionDetailScreenState extends ConsumerState<ConversionDetailScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-draw once a second so elapsed time and the estimate keep moving.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(onDeviceQueueProvider);
    final item = queue.where((i) => i.id == widget.itemId).firstOrNull;
    final run = ref.watch(onDeviceRunProvider);
    final novel = ref.watch(conversionModeProvider).contentMode == 'novel';
    final steps = conversionSteps(novel: novel);
    final theme = Theme.of(context);
    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Conversion')),
        body: const Center(child: Text('This book is no longer in the queue.')),
      );
    }
    final running = item.status == QueueStatus.running;
    final events = running ? (run?.events ?? const <RunEvent>[]) : item.events;
    final stage = running ? run?.stage : item.reachedStage;
    final reached = item.status == QueueStatus.done ? steps.length : stepIndexFor(stage, steps);
    final ahead = queue.where((i) => i.status == QueueStatus.queued).toList().indexWhere((i) => i.id == item.id);
    final start = item.startedAt;
    final end = item.finishedAt ?? DateTime.now();
    final partial = ref.watch(localBooksProvider).value?.where((b) => b.bookId == item.bookId && b.partial).firstOrNull;

    String? eta;
    if (running && run?.fraction != null && stage != null) {
      final stageStart = events.where((e) => e.stage == stage).map((e) => e.at).firstOrNull;
      final f = run!.fraction!;
      if (stageStart != null && f > 0.03 && f < 0.995) {
        final remaining = DateTime.now().difference(stageStart) * ((1 - f) / f);
        eta = 'about ${formatDuration(remaining)} left in this step';
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: ListTile(
              leading: switch (item.status) {
                QueueStatus.running => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                QueueStatus.queued => const Icon(Icons.schedule_rounded),
                QueueStatus.paused => const Icon(Icons.pause_circle_outline_rounded),
                QueueStatus.done => const Icon(Icons.check_circle_rounded, color: Colors.green),
                QueueStatus.failed => Icon(Icons.error_rounded, color: theme.colorScheme.error),
                QueueStatus.cancelled => const Icon(Icons.stop_circle_outlined),
              },
              title: Text(switch (item.status) {
                QueueStatus.running => 'Converting now',
                QueueStatus.queued => ahead <= 0 ? 'Next in the queue' : '$ahead ${ahead == 1 ? 'book' : 'books'} ahead of this one',
                QueueStatus.paused => 'Paused. Your progress is saved.',
                QueueStatus.done => 'Finished. It is in your library.',
                QueueStatus.failed => 'Failed',
                QueueStatus.cancelled => 'Stopped',
              }),
              subtitle: Text([
                if (start != null) item.finishedAt == null ? 'Running for ${formatDuration(end.difference(start))}' : 'Took ${formatDuration(end.difference(start))}',
                ?eta,
              ].join(' · ')),
            ),
          ),
          _Actions(item: item, partial: partial),
          if (item.status == QueueStatus.failed && item.error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(item.error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          const SizedBox(height: 8),
          Text('Steps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          for (var i = 0; i < steps.length; i++)
            _StepTile(
              step: steps[i],
              state: _stateOf(i, reached, item.status),
              detail: i == reached && running ? run?.detail : null,
              fraction: i == reached && running ? run?.fraction : null,
            ),
          const SizedBox(height: 16),
          Text('Activity', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          if (events.isEmpty)
            Text(item.status == QueueStatus.queued ? 'Nothing yet: this book has not started.' : 'No activity was recorded.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          else
            for (final e in events.reversed.take(40))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}:${e.at.second.toString().padLeft(2, '0')}  ${e.detail}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          const SizedBox(height: 16),
          Text('File', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          SelectableText(item.path, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  _StepState _stateOf(int index, int reached, QueueStatus status) {
    if (status == QueueStatus.done) return _StepState.done;
    if (status == QueueStatus.queued) return _StepState.pending;
    if (index < reached) return _StepState.done;
    if (index == reached) {
      return switch (status) {
        QueueStatus.failed => _StepState.failed,
        QueueStatus.cancelled || QueueStatus.paused => _StepState.stopped,
        _ => _StepState.current,
      };
    }
    return _StepState.pending;
  }
}

/// Pause / resume and "listen to what is ready" for one book.
class _Actions extends ConsumerWidget {
  final QueueItem item;
  final BookSummary? partial;
  const _Actions({required this.item, required this.partial});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.read(onDeviceQueueProvider.notifier);
    final ready = partial;
    final canResume = item.status == QueueStatus.paused ||
        item.status == QueueStatus.cancelled ||
        item.status == QueueStatus.failed;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (ready != null)
            FilledButton.icon(
              key: const Key('listen-ready'),
              onPressed: () => openPartialBook(context, ref, item.bookId),
              icon: const Icon(Icons.headphones_rounded),
              label: Text(ready.sectionsPlanned == null
                  ? 'Listen to what is ready'
                  : 'Listen to what is ready (${ready.sectionCount} of ${ready.sectionsPlanned})'),
            ),
          if (item.status == QueueStatus.running)
            OutlinedButton.icon(
              key: const Key('pause-conversion'),
              onPressed: queue.pauseCurrent,
              icon: const Icon(Icons.pause_rounded),
              label: const Text('Pause'),
            ),
          if (canResume)
            FilledButton.tonalIcon(
              key: const Key('resume-conversion'),
              onPressed: () => queue.resume(item.id),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
        ],
      ),
    );
  }
}

enum _StepState { done, current, pending, failed, stopped }

class _StepTile extends StatelessWidget {
  final ConversionStep step;
  final _StepState state;
  final String? detail;
  final double? fraction;
  const _StepTile({required this.step, required this.state, this.detail, this.fraction});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (state) {
      _StepState.done => const Icon(Icons.check_circle_rounded, color: Colors.green),
      _StepState.current => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
      _StepState.failed => Icon(Icons.error_rounded, color: scheme.error),
      _StepState.stopped => Icon(Icons.stop_circle_outlined, color: scheme.onSurfaceVariant),
      _StepState.pending => Icon(Icons.radio_button_unchecked_rounded, color: scheme.outline),
    };
    final label = switch (state) {
      _StepState.done => 'Done',
      _StepState.current => 'Running now',
      _StepState.failed => 'Stopped here with an error',
      _StepState.stopped => 'Stopped here',
      _StepState.pending => 'Still to do',
    };
    return ListTile(
      key: ValueKey('step-${step.key}'),
      contentPadding: EdgeInsets.zero,
      leading: icon,
      title: Text('${step.title} · $label'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.hint),
          if (state == _StepState.current && detail != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(detail!, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (state == _StepState.current && fraction != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: fraction!.clamp(0.0, 1.0)),
            ),
        ],
      ),
    );
  }
}
