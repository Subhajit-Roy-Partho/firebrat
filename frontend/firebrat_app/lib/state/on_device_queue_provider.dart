import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart' show BackgroundConversionRunner, sanitizeBookId;
import 'package:shared_preferences/shared_preferences.dart';
import 'on_device_pipeline_run_provider.dart';

enum QueueStatus { queued, running, paused, done, failed, cancelled }

/// One book waiting for, undergoing, or finished with an on-device conversion.
class QueueItem {
  final String id;
  final String path; // a PDF, a ZIP of chapter PDFs, or an EPUB / MOBI / AZW / AZW3
  final String title;
  final QueueStatus status;
  final String? error;

  /// For the detail screen: when it started and ended, the last step reached
  /// and the activity log (captured when the conversion ends).
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? reachedStage;
  final List<RunEvent> events;

  const QueueItem({
    required this.id,
    required this.path,
    required this.title,
    this.status = QueueStatus.queued,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.reachedStage,
    this.events = const [],
  });

  QueueItem copyWith({
    QueueStatus? status,
    String? error,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? reachedStage,
    List<RunEvent>? events,
  }) =>
      QueueItem(
        id: id,
        path: path,
        title: title,
        status: status ?? this.status,
        error: error,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        reachedStage: reachedStage ?? this.reachedStage,
        events: events ?? this.events,
      );

  /// The library folder this conversion writes to (the pipeline derives it from the title).
  String get bookId => sanitizeBookId('$title.pdf');

  Map<String, dynamic> toJson() => {'id': id, 'path': path, 'title': title, 'paused': status == QueueStatus.paused};
}

/// Runs one conversion. Overridable so the queue can be tested without a phone.
typedef ConversionRunner = Future<String> Function(ProviderContainer container, List<String> paths, {String? titleOverride});
typedef ConversionCanceller = Future<void> Function(ProviderContainer container, {bool keepProgress});

final conversionRunnerProvider = Provider<ConversionRunner>((ref) => runOnDeviceConversionIn);
final conversionCancellerProvider = Provider<ConversionCanceller>((ref) => cancelOnDeviceConversion);
final unzipChaptersProvider = Provider<Future<List<String>> Function(String)>((ref) => unpackZipChapters);

/// Books waiting for on-device conversion, converted one at a time, in order.
/// A failed or stopped book never blocks the ones behind it. Waiting and paused
/// books survive the app being closed or updated; the one that was mid-conversion
/// carries on from the last section it finished.
class OnDeviceQueueNotifier extends Notifier<List<QueueItem>> {
  static const _kPending = 'onDeviceQueue.pending';
  bool _pumping = false;
  int _seq = 0;

  @override
  List<QueueItem> build() {
    unawaited(_restore());
    return const [];
  }

  Future<void> _restore() async {
    final raw = (await SharedPreferences.getInstance()).getString(_kPending);
    if (raw == null) return;
    try {
      final restored = [
        for (final m in jsonDecode(raw) as List)
          QueueItem(
            id: m['id'] as String,
            path: m['path'] as String,
            title: m['title'] as String,
            status: m['paused'] == true ? QueueStatus.paused : QueueStatus.queued,
          ),
      ];
      if (restored.isEmpty || state.any((i) => i.status == QueueStatus.queued || i.status == QueueStatus.running)) return;
      state = [...restored, ...state];
      // A conversion service that survived an app restart is still working on
      // its own book; starting another would restart it. Wait for the user then.
      var serviceRunning = false;
      try {
        serviceRunning = await BackgroundConversionRunner.isRunning;
      } catch (_) {} // can't tell (no platform channel): treat as idle
      if (!serviceRunning) unawaited(_pump());
    } catch (_) {}
  }

  Future<void> _save() async {
    final pending = [
      for (final i in state)
        if (i.status == QueueStatus.queued || i.status == QueueStatus.running || i.status == QueueStatus.paused) i
    ];
    final prefs = await SharedPreferences.getInstance();
    if (pending.isEmpty) {
      await prefs.remove(_kPending);
    } else {
      await prefs.setString(_kPending, jsonEncode([for (final i in pending) i.toJson()]));
    }
  }

  static String titleFor(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.(pdf|zip|epub|mobi|azw3?)$', caseSensitive: false), '');
  }

  /// Adds books to the end of the queue and starts converting if idle.
  void enqueue(List<String> paths) {
    final items = [
      for (final p in paths)
        QueueItem(id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}', path: p, title: titleFor(p)),
    ];
    if (items.isEmpty) return;
    state = [...state, ...items];
    unawaited(_save());
    unawaited(_pump());
  }

  /// Removes a waiting book, or dismisses a finished one. The running book
  /// is stopped with [stopCurrent] instead.
  void remove(String id) {
    state = [for (final i in state) if (i.id != id || i.status == QueueStatus.running) i];
    unawaited(_save());
  }

  /// Forgets finished entries (done, failed, stopped).
  void clearFinished() {
    state = [
      for (final i in state)
        if (i.status == QueueStatus.queued || i.status == QueueStatus.running || i.status == QueueStatus.paused) i
    ];
  }

  /// Stops the book being converted now. The queue carries on with the next one.
  Future<void> stopCurrent() async {
    final running = state.where((i) => i.status == QueueStatus.running).firstOrNull;
    if (running == null) return;
    _update(running.id, QueueStatus.cancelled);
    await ref.read(conversionCancellerProvider)(ref.container);
  }

  /// Pauses the book being converted now, and the queue behind it, keeping
  /// everything finished so far. [resume] carries on from there.
  Future<void> pauseCurrent() async {
    final running = state.where((i) => i.status == QueueStatus.running).firstOrNull;
    if (running == null) return;
    _update(running.id, QueueStatus.paused);
    await ref.read(conversionCancellerProvider)(ref.container, keepProgress: true);
  }

  /// Carries a paused, stopped or failed book on from the last section it
  /// finished, and lets the queue run again.
  void resume(String id) {
    final item = state.where((i) => i.id == id).firstOrNull;
    if (item == null || item.status == QueueStatus.running || item.status == QueueStatus.queued || item.status == QueueStatus.done) {
      return;
    }
    state = [
      for (final i in state)
        if (i.id == id) i.copyWith(status: QueueStatus.queued) else i,
    ];
    unawaited(_save());
    unawaited(_pump());
  }

  void _update(String id, QueueStatus status, {String? error}) {
    final finished = status != QueueStatus.queued && status != QueueStatus.running && status != QueueStatus.paused;
    final run = ref.read(onDeviceRunProvider);
    state = [
      for (final i in state)
        if (i.id != id)
          i
        else
          i.copyWith(
            status: status,
            error: error,
            startedAt: status == QueueStatus.running ? DateTime.now() : null,
            finishedAt: finished ? DateTime.now() : null,
            // Keep what the run reported, so a finished book can still show its steps.
            reachedStage: finished ? run?.stage : null,
            events: finished ? (run?.events ?? const []) : null,
          ),
    ];
    unawaited(_save());
  }

  QueueStatus? _statusOf(String id) => state.where((i) => i.id == id).firstOrNull?.status;

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        // A paused queue stays paused until the user resumes it.
        if (state.any((i) => i.status == QueueStatus.paused)) break;
        final next = state.where((i) => i.status == QueueStatus.queued).firstOrNull;
        if (next == null) break;
        _update(next.id, QueueStatus.running);
        try {
          final paths = next.path.toLowerCase().endsWith('.zip')
              ? await ref.read(unzipChaptersProvider)(next.path)
              : [next.path];
          await ref.read(conversionRunnerProvider)(ref.container, paths, titleOverride: next.title);
          _update(next.id, QueueStatus.done);
        } on ConversionCancelled {
          if (_statusOf(next.id) != QueueStatus.paused) _update(next.id, QueueStatus.cancelled);
        } catch (e) {
          // A stop or pause that raced the runner is not a failure.
          final current = _statusOf(next.id);
          final stopped = current == QueueStatus.cancelled || current == QueueStatus.paused;
          if (current != QueueStatus.paused) {
            _update(next.id, stopped ? QueueStatus.cancelled : QueueStatus.failed, error: stopped ? null : e.toString());
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }
}

final onDeviceQueueProvider = NotifierProvider<OnDeviceQueueNotifier, List<QueueItem>>(OnDeviceQueueNotifier.new);
