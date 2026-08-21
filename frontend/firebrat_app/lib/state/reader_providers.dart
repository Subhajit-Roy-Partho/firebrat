import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/manifest.dart';
import '../models/segment.dart';
import '../services/playback_controller.dart';
import 'library_providers.dart';
import 'settings_providers.dart';

/// One reader session: a book_id's manifest, the current section index,
/// the live PlaybackController, and the currently-active segment.
/// Recreated per book (family keyed by bookId) so navigating between books
/// in the library never leaks a previous session's audio player.
class ReaderState {
  final Manifest manifest;
  final int sectionIndex;
  final Segment? activeSegment;
  final bool loadingSection;

  const ReaderState({
    required this.manifest,
    required this.sectionIndex,
    required this.activeSegment,
    required this.loadingSection,
  });

  ManifestSection get section => manifest.sections[sectionIndex];

  ReaderState copyWith({int? sectionIndex, Segment? activeSegment, bool clearActiveSegment = false, bool? loadingSection}) =>
      ReaderState(
        manifest: manifest,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        activeSegment: clearActiveSegment ? null : (activeSegment ?? this.activeSegment),
        loadingSection: loadingSection ?? this.loadingSection,
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
    player = PlaybackController();
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
      if (state != null) state = state!.copyWith(activeSegment: seg, clearActiveSegment: seg == null);
    });
    _completeSub = player.sectionCompleteStream.listen((_) => _onSectionComplete());
  }

  Future<void> _loadSection(int index) async {
    final s = state;
    if (s == null) return;
    state = s.copyWith(sectionIndex: index, loadingSection: true, clearActiveSegment: true);
    final repo = ref.read(libraryRepositoryProvider);
    final section = s.manifest.sections[index];
    final segPath = await repo.bookAssetPath(_bookId, section.segmentsPath);
    final audioPath = await repo.bookAssetPath(_bookId, section.audioPath);
    final segJson = jsonDecode(await File(segPath).readAsString()) as Map<String, dynamic>;
    final segmentsFile = SegmentsFile.fromJson(segJson);
    await player.loadSection(section, segmentsFile, audioPath);
    final settings = ref.read(readerSettingsProvider);
    await player.setSpeed(settings.playbackSpeed);
    state = state?.copyWith(loadingSection: false);
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
