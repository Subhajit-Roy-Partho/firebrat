import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/manifest.dart';
import '../models/segment.dart';
import '../models/visual_item.dart';
import '../models/reading_checkpoint.dart';
import '../services/reading_progress_store.dart';
import '../services/audio_handler.dart';
import '../services/library_repository.dart';
import '../services/playback_controller.dart';
import 'library_providers.dart';
import 'settings_providers.dart';

bool _isVisualType(SegmentType type) =>
    type == SegmentType.figureCallout || type == SegmentType.formulaCallout || type == SegmentType.tableCallout;

/// Load failure for one book's reader session (bad manifest — see
/// ReaderController._init). Separate from ReaderState because the state
/// itself is null while the manifest hasn't loaded.
class _ReaderErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final readerErrorProvider =
    NotifierProvider.family<_ReaderErrorNotifier, String?, String>((_) => _ReaderErrorNotifier());

/// One reader session: a book_id's manifest, the current section index,
/// the live PlaybackController, and the currently-active segment.
/// Recreated per book (family keyed by bookId) so navigating between books
/// in the library never leaks a previous session's audio player.
class ReaderState {
  final Manifest manifest;
  final int sectionIndex;
  final Segment? activeSegment;
  final bool loadingSection;
  final Map<String, String> assetPaths; // ref id -> absolute local file path, current section only
  final String? currentVisualId; // last figure/table/formula ref spoken about — sticky across prose segments
  /// Set when the book/section failed to load (missing files, corrupt
  /// package) — the reader shows this instead of spinning forever.
  final String? error;

  const ReaderState({
    required this.manifest,
    required this.sectionIndex,
    required this.activeSegment,
    required this.loadingSection,
    this.assetPaths = const {},
    this.currentVisualId,
    this.error,
  });

  ManifestSection get section => manifest.sections[sectionIndex];

  /// The image/formula that should be on screen right now (Focus Mode,
  /// lock-screen art), or null if the section hasn't reached one yet.
  VisualItem? get currentVisual {
    final id = currentVisualId;
    if (id == null) return null;
    final path = assetPaths[id];
    if (path == null) return null;
    final fig = manifest.figureById(id);
    if (fig != null) return VisualItem(id: id, kind: VisualKind.figure, imagePath: path, caption: fig.caption);
    final tbl = manifest.tableById(id);
    if (tbl != null) return VisualItem(id: id, kind: VisualKind.table, imagePath: path, caption: tbl.caption);
    final fo = manifest.formulaById(id);
    if (fo != null) {
      return VisualItem(id: id, kind: VisualKind.formula, imagePath: path, caption: fo.spokenText, latex: fo.latex);
    }
    return null;
  }

  ReaderState copyWith({
    int? sectionIndex,
    Segment? activeSegment,
    bool clearActiveSegment = false,
    bool? loadingSection,
    Map<String, String>? assetPaths,
    String? currentVisualId,
    bool clearCurrentVisual = false,
    String? error,
    bool clearError = false,
  }) =>
      ReaderState(
        manifest: manifest,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        activeSegment: clearActiveSegment ? null : (activeSegment ?? this.activeSegment),
        loadingSection: loadingSection ?? this.loadingSection,
        assetPaths: assetPaths ?? this.assetPaths,
        currentVisualId: clearCurrentVisual ? null : (currentVisualId ?? this.currentVisualId),
        error: clearError ? null : (error ?? this.error),
      );
}

class ReaderController extends Notifier<ReaderState?> {
  final String bookId;
  ReaderController(this.bookId);

  late PlaybackController player;
  StreamSubscription? _activeSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _progressSub;
  StreamSubscription? _playStateSub;
  ReadingProgressStore? _progressStore;
  ReadingCheckpoint? _lastCheckpoint;
  DateTime? _lastLocalSave;
  String _signature = '';
  String? _currentAudioPath;
  String get _bookId => bookId;

  @override
  ReaderState? build() {
    player = PlaybackController(ref.read(audioHandlerProvider));
    ref.onDispose(() {
      _activeSub?.cancel();
      _completeSub?.cancel();
      _progressSub?.cancel();
      _playStateSub?.cancel();
      final checkpoint = _lastCheckpoint;
      if (checkpoint != null) {
        unawaited(_progressStore?.save(checkpoint, force: true));
      }
      player.dispose();
    });
    _init(bookId);
    return null;
  }

  Future<void> _init(String bookId) async {
    final repo = ref.read(libraryRepositoryProvider);
    late final Manifest manifest;
    try {
      manifest = await repo.loadLocalManifest(bookId);
    } catch (e) {
      // A corrupt/missing manifest used to leave state null forever — the
      // reader spun on an infinite loader ("freezes on open"). Surface it
      // through readerErrorProvider instead (see ReaderScreen).
      ref.read(readerErrorProvider(bookId).notifier).set(
          'Could not open this book — its files look incomplete or corrupt. '
          'Try deleting it (long-press the card) and downloading again.\n$e');
      return;
    }
    ref.read(readerErrorProvider(bookId).notifier).set(null);
    _signature = sha256.convert(utf8.encode(jsonEncode([
      for (final s in manifest.sections) [s.sectionId, s.durationMs],
    ]))).toString();
    _progressStore = ref.read(firestoreSyncServiceProvider).progressStore(bookId);
    final restored = await _progressStore!.restore(_signature);
    if (!ref.mounted) return;
    final restoredIndex = restored == null ? -1 :
        manifest.sections.indexWhere((s) => s.sectionId == restored.sectionId);
    final index = restoredIndex < 0 ? 0 : restoredIndex;
    _lastCheckpoint = restoredIndex < 0 ? null : restored;
    state = ReaderState(manifest: manifest, sectionIndex: index, activeSegment: null, loadingSection: true);
    await _loadSection(index);
    if (!ref.mounted) return;
    if (restored != null && restoredIndex >= 0) {
      final maximum = player.duration?.inMilliseconds ?? manifest.sections[index].durationMs;
      await player.seek(Duration(milliseconds: restored.positionMs.clamp(0, maximum)));
    }
    _progressSub = player.positionStream.listen((_) => unawaited(_saveCheckpoint()));
    _playStateSub = player.playerStateStream.listen((s) {
      if (!s.playing) unawaited(_saveCheckpoint(force: true));
    });

    _activeSub = player.activeSegmentStream.listen((seg) {
      if (state == null) return;
      state = state!.copyWith(activeSegment: seg, clearActiveSegment: seg == null);
      if (seg != null && seg.ref != null && _isVisualType(seg.type)) {
        state = state!.copyWith(currentVisualId: seg.ref);
        _syncLockScreenArt();
      }
    });
    _completeSub = player.sectionCompleteStream.listen((_) => _onSectionComplete());
  }

  Future<void> _loadSection(int index) async {
    final s = state;
    if (s == null) return;
    state = s.copyWith(sectionIndex: index, loadingSection: true, clearActiveSegment: true, clearCurrentVisual: true, clearError: true);
    final repo = ref.read(libraryRepositoryProvider);
    try {
      final section = s.manifest.sections[index];
    final segPath = await repo.bookAssetPath(_bookId, section.segmentsPath);
    final audioPath = await repo.bookAssetPath(_bookId, section.audioPath);
    final segJson = jsonDecode(await File(segPath).readAsString()) as Map<String, dynamic>;
    final segmentsFile = SegmentsFile.fromJson(segJson);
    final assetPaths = await _resolveAssetPaths(repo, section, s.manifest);
    final initialVisualId = _firstVisualRef(segmentsFile);

    await player.loadSection(
      section,
      segmentsFile,
      audioPath,
      MediaItem(
        id: audioPath,
        album: s.manifest.title,
        title: section.title,
        artUri: initialVisualId != null && assetPaths[initialVisualId] != null
            ? Uri.file(assetPaths[initialVisualId]!)
            : null,
      ),
    );
    _currentAudioPath = audioPath;
    final settings = ref.read(readerSettingsProvider);
    await player.setSpeed(settings.playbackSpeed);
    state = state?.copyWith(loadingSection: false, assetPaths: assetPaths, currentVisualId: initialVisualId);
    } catch (e) {
      // Missing/corrupt section files (e.g. an interrupted download left a
      // manifest but no audio) used to wedge loadingSection on forever.
      // Surface it — ReaderScreen renders the error with a way back.
      state = state?.copyWith(
        loadingSection: false,
        error: 'Could not load this section — files look incomplete. '
            'Try deleting the book (long-press its card) and downloading again.\n$e',
      );
    }
  }

  Future<Map<String, String>> _resolveAssetPaths(
    LibraryRepository repo,
    ManifestSection section,
    Manifest manifest,
  ) async {
    final paths = <String, String>{};
    for (final id in section.figureRefs) {
      final f = manifest.figureById(id);
      if (f != null) paths[id] = await repo.bookAssetPath(_bookId, f.imagePath);
    }
    for (final id in section.tableRefs) {
      final t = manifest.tableById(id);
      if (t != null) paths[id] = await repo.bookAssetPath(_bookId, t.imagePath);
    }
    for (final id in section.formulaRefs) {
      final fo = manifest.formulaById(id);
      if (fo != null) paths[id] = await repo.bookAssetPath(_bookId, fo.imagePath);
    }
    return paths;
  }

  /// The first figure/table/formula referenced in reading order, shown as
  /// soon as a section loads (before playback reaches its callout).
  String? _firstVisualRef(SegmentsFile segmentsFile) {
    for (final seg in segmentsFile.segments) {
      if (seg.ref != null && _isVisualType(seg.type)) return seg.ref;
    }
    return null;
  }

  void _syncLockScreenArt() {
    final s = state;
    final visual = s?.currentVisual;
    if (s == null || visual == null) return;
    final handler = ref.read(audioHandlerProvider);
    final current = handler.mediaItem.valueOrNull;
    if (current == null || current.artUri == Uri.file(visual.imagePath)) return;
    handler.setMediaItem(current.copyWith(artUri: Uri.file(visual.imagePath)));
  }

  Future<void> goToSection(int index) async {
    final s = state;
    if (s == null || index < 0 || index >= s.manifest.sections.length) return;
    final wasPlaying = player.isPlaying;
    await _saveCheckpoint(force: true);
    await _loadSection(index);
    if (wasPlaying) await player.play();
  }

  Future<void> nextSection() => goToSection((state?.sectionIndex ?? 0) + 1);
  Future<void> previousSection() => goToSection((state?.sectionIndex ?? 0) - 1);

  Future<void> _onSectionComplete() async {
    await _saveCheckpoint(force: true);
    final settings = ref.read(readerSettingsProvider);
    final s = state;
    if (s == null) return;
    if (!settings.autoplayEnabled || s.sectionIndex >= s.manifest.sections.length - 1) {
      await player.pause();
      return;
    }
    if (settings.autoplayDelaySeconds > 0) {
      await Future.delayed(Duration(seconds: settings.autoplayDelaySeconds));
    }
    // Only continue if the user hasn't manually navigated away in the meantime.
    if (state?.sectionIndex == s.sectionIndex) {
      await nextSection();
      await player.play();
    }
  }

  Future<void> _saveCheckpoint({bool force = false}) async {
    final s = state;
    if (s == null || s.loadingSection || _progressStore == null ||
        ref.read(audioHandlerProvider).mediaItem.valueOrNull?.id != _currentAudioPath) {
      return;
    }
    final now = DateTime.now();
    if (!force && _lastLocalSave != null &&
        now.difference(_lastLocalSave!) < const Duration(seconds: 5)) {
      return;
    }
    final position = player.position.inMilliseconds;
    if (_lastCheckpoint?.sectionId == s.section.sectionId &&
        _lastCheckpoint?.positionMs == position) {
      if (force) await _progressStore!.save(_lastCheckpoint!, force: true);
      return;
    }
    _lastLocalSave = now;
    final previous = _lastCheckpoint?.updatedAtMs ?? 0;
    _lastCheckpoint = ReadingCheckpoint(sectionId: s.section.sectionId,
      positionMs: position, updatedAtMs: now.millisecondsSinceEpoch > previous
          ? now.millisecondsSinceEpoch : previous + 1, signature: _signature);
    try { await _progressStore!.save(_lastCheckpoint!, force: force); }
    catch (_) { /* A checkpoint failure must not interrupt narration. */ }
  }
}

final readerControllerProvider = NotifierProvider.family<ReaderController, ReaderState?, String>(
  (bookId) => ReaderController(bookId),
);
