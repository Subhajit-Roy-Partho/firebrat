import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import '../services/cover_art_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/manifest.dart';
import '../models/segment.dart';
import '../models/visual_item.dart';
import '../models/reading_checkpoint.dart';
import '../services/reading_progress_store.dart';
import '../services/audio_handler.dart';
import '../services/library_repository.dart';
import '../services/playback_controller.dart';
import 'on_device_pipeline_run_provider.dart';
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

  /// A book still being converted whose last ready section has finished
  /// playing: playback carries on by itself as the next one lands.
  final bool waitingForNext;

  const ReaderState({
    required this.manifest,
    required this.sectionIndex,
    required this.activeSegment,
    required this.loadingSection,
    this.assetPaths = const {},
    this.currentVisualId,
    this.error,
    this.waitingForNext = false,
  });

  ManifestSection get section => manifest.sections[sectionIndex];

  /// Figures/tables linked to the section as a whole (e.g. relinked by caption)
  /// are not tied to a narrated segment, so no `figure_callout` ever selects
  /// them. When the narration has not reached a visual, Focus Mode and the
  /// lock-screen art fall back to the section's first linked picture instead
  /// of showing text only.
  String? get _sectionFallbackVisualId {
    for (final id in [...section.figureRefs, ...section.tableRefs]) {
      if (assetPaths.containsKey(id)) return id;
    }
    return null;
  }

  /// The image/formula that should be on screen right now (Focus Mode,
  /// lock-screen art), or null if the section hasn't reached one yet.
  VisualItem? get currentVisual {
    final id = currentVisualId ?? _sectionFallbackVisualId;
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
    Manifest? manifest,
    bool? waitingForNext,
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
        manifest: manifest ?? this.manifest,
        waitingForNext: waitingForNext ?? this.waitingForNext,
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
  Uri? _coverUri;
  Timer? _partialTimer;
  bool _refreshing = false;
  String get _bookId => bookId;

  @override
  ReaderState? build() {
    player = PlaybackController(ref.read(audioHandlerProvider));
    ref.onDispose(() {
      _partialTimer?.cancel();
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
    _signature = _signatureFor(manifest);
    _progressStore = ref.read(firestoreSyncServiceProvider).progressStore(bookId);
    var restored = await _progressStore!.restore(_signature);
    // A book that was listened to while still converting saved its place under
    // the "partial" signature: carry it over once the book is finished.
    if (restored == null && !manifest.partial) {
      restored = await _progressStore!.restore(_partialSignature);
    }
    if (!ref.mounted) return;
    final found = restored;
    final restoredIndex = found == null ? -1 :
        manifest.sections.indexWhere((s) => s.sectionId == found.sectionId);
    final index = restoredIndex < 0 ? 0 : restoredIndex;
    _lastCheckpoint = restoredIndex < 0 ? null : found;
    state = ReaderState(manifest: manifest, sectionIndex: index, activeSegment: null, loadingSection: true);
    _coverUri = await CoverArtService(ref.read(downloadManagerProvider)).coverUri(
        bookId: bookId, title: manifest.title, author: manifest.author);
    if (!ref.mounted) return;
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
    if (manifest.partial) {
      _partialTimer = Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_refreshManifest()));
    }
  }

  static const _partialSignature = 'partial';

  /// A growing book keeps one stable signature, so the place being listened to
  /// survives new sections arriving; a finished book hashes its section list.
  String _signatureFor(Manifest manifest) => manifest.partial
      ? _partialSignature
      : sha256.convert(utf8.encode(jsonEncode([
          for (final s in manifest.sections) [s.sectionId, s.durationMs],
        ]))).toString();

  bool _conversionRunning() {
    final run = ref.read(onDeviceRunProvider);
    return run != null && !run.done && run.error == null;
  }

  /// Picks up sections that finished since the book was opened. When playback
  /// had caught up with the conversion, continues with the next one.
  Future<void> _refreshManifest() async {
    if (_refreshing || !ref.mounted) return;
    _refreshing = true;
    try {
      final Manifest fresh;
      try {
        fresh = await ref.read(libraryRepositoryProvider).loadLocalManifest(bookId);
      } catch (_) {
        return; // mid-write or briefly unreadable: the next tick tries again
      }
      final current = state;
      if (current == null || !ref.mounted) return;
      final grew = fresh.sections.length > current.manifest.sections.length;
      if (grew || (current.manifest.partial && !fresh.partial)) {
        state = current.copyWith(manifest: fresh);
        if (!fresh.partial) {
          _partialTimer?.cancel();
          _signature = _signatureFor(fresh);
        }
      }
      final s = state;
      if (s == null) return;
      if (s.waitingForNext) {
        if (s.sectionIndex < s.manifest.sections.length - 1) {
          state = s.copyWith(waitingForNext: false);
          await nextSection();
          await player.play();
        } else if (!s.manifest.partial || !_conversionRunning()) {
          state = s.copyWith(waitingForNext: false); // finished, or paused/stopped: nothing more is coming
          await player.pause();
        }
      }
    } finally {
      _refreshing = false;
    }
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
        artist: s.manifest.author.isEmpty ? null : s.manifest.author,
        title: section.title,
        // A figure when the section opens on one, otherwise the book cover,
        // so text-only books (novels) still get artwork on the lock screen.
        artUri: initialVisualId != null && assetPaths[initialVisualId] != null
            ? Uri.file(assetPaths[initialVisualId]!)
            : _coverUri,
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
    if (s == null) return;
    final visual = s.currentVisual;
    final handler = ref.read(audioHandlerProvider);
    final current = handler.mediaItem.valueOrNull;
    if (current == null) return;
    final wanted = visual != null ? Uri.file(visual.imagePath) : _coverUri;
    if (wanted == null || current.artUri == wanted) return;
    handler.setMediaItem(current.copyWith(artUri: wanted));
  }

  Future<void> goToSection(int index) async {
    final s = state;
    if (s == null || index < 0 || index >= s.manifest.sections.length) return;
    final wasPlaying = player.isPlaying;
    await _saveCheckpoint(force: true);
    await _loadSection(index);
    await _saveCheckpoint(force: true);
    if (wasPlaying) await player.play();
  }

  Future<void> nextSection() => goToSection((state?.sectionIndex ?? 0) + 1);
  Future<void> previousSection() => goToSection((state?.sectionIndex ?? 0) - 1);

  Future<void> _onSectionComplete() async {
    await _saveCheckpoint(force: true);
    final settings = ref.read(readerSettingsProvider);
    if (state?.manifest.partial == true) await _refreshManifest();
    final s = state;
    if (s == null) return;
    final atEnd = s.sectionIndex >= s.manifest.sections.length - 1;
    if (atEnd && s.manifest.partial && settings.autoplayEnabled && _conversionRunning()) {
      // Caught up with the narration: wait for the next section instead of stopping.
      state = s.copyWith(waitingForNext: true);
      return;
    }
    if (!settings.autoplayEnabled || atEnd) {
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
    if (!ref.mounted) return;
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
