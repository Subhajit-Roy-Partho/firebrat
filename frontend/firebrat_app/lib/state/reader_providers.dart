import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/manifest.dart';
import '../models/segment.dart';
import '../models/visual_item.dart';
import '../services/audio_handler.dart';
import '../services/library_repository.dart';
import '../services/playback_controller.dart';
import 'library_providers.dart';
import 'settings_providers.dart';

bool _isVisualType(SegmentType type) =>
    type == SegmentType.figureCallout || type == SegmentType.formulaCallout || type == SegmentType.tableCallout;

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

  const ReaderState({
    required this.manifest,
    required this.sectionIndex,
    required this.activeSegment,
    required this.loadingSection,
    this.assetPaths = const {},
    this.currentVisualId,
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
  }) =>
      ReaderState(
        manifest: manifest,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        activeSegment: clearActiveSegment ? null : (activeSegment ?? this.activeSegment),
        loadingSection: loadingSection ?? this.loadingSection,
        assetPaths: assetPaths ?? this.assetPaths,
        currentVisualId: clearCurrentVisual ? null : (currentVisualId ?? this.currentVisualId),
      );
}

class ReaderController extends Notifier<ReaderState?> {
  final String bookId;
  ReaderController(this.bookId);

  late PlaybackController player;
  StreamSubscription? _activeSub;
  StreamSubscription? _completeSub;
  String get _bookId => bookId;

  @override
  ReaderState? build() {
    player = PlaybackController(ref.read(audioHandlerProvider));
    ref.onDispose(() {
      _activeSub?.cancel();
      _completeSub?.cancel();
      player.dispose();
    });
    _init(bookId);
    return null;
  }

  Future<void> _init(String bookId) async {
    final repo = ref.read(libraryRepositoryProvider);
    final manifest = await repo.loadLocalManifest(bookId);
    state = ReaderState(manifest: manifest, sectionIndex: 0, activeSegment: null, loadingSection: true);
    await _loadSection(0);

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
    state = s.copyWith(sectionIndex: index, loadingSection: true, clearActiveSegment: true, clearCurrentVisual: true);
    final repo = ref.read(libraryRepositoryProvider);
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
    final settings = ref.read(readerSettingsProvider);
    await player.setSpeed(settings.playbackSpeed);
    state = state?.copyWith(loadingSection: false, assetPaths: assetPaths, currentVisualId: initialVisualId);
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
    await _loadSection(index);
    if (wasPlaying) await player.play();
  }

  Future<void> nextSection() => goToSection((state?.sectionIndex ?? 0) + 1);
  Future<void> previousSection() => goToSection((state?.sectionIndex ?? 0) - 1);

  Future<void> _onSectionComplete() async {
    final settings = ref.read(readerSettingsProvider);
    if (!settings.autoplayEnabled) return;
    final s = state;
    if (s == null || s.sectionIndex >= s.manifest.sections.length - 1) return;
    if (settings.autoplayDelaySeconds > 0) {
      await Future.delayed(Duration(seconds: settings.autoplayDelaySeconds));
    }
    // Only continue if the user hasn't manually navigated away in the meantime.
    if (state?.sectionIndex == s.sectionIndex) {
      await nextSection();
      await player.play();
    }
  }
}

final readerControllerProvider = NotifierProvider.family<ReaderController, ReaderState?, String>(
  (bookId) => ReaderController(bookId),
);
