import 'dart:async';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:just_audio/just_audio.dart';
import '../models/manifest.dart';
import '../models/segment.dart';
import 'audio_handler.dart';

/// Drives one section's combined track through the app-wide [FirebratAudioHandler],
/// exposing the currently-active segment (for highlight sync) and
/// section-complete events (for autoplay). Manual seeks always work
/// regardless of autoplay state — this is what keeps "always free to go
/// back and forth" true.
///
/// The underlying player is NOT owned by this class — it belongs to the
/// singleton [FirebratAudioHandler] so playback (and lock-screen /
/// notification controls) survive this controller being disposed when the
/// reader navigates away or the book changes.
class PlaybackController {
  final FirebratAudioHandler _handler;
  AudioPlayer get _player => _handler.player;

  ManifestSection? _section;
  SegmentsFile? _segmentsFile;

  final _activeSegmentController = StreamController<Segment?>.broadcast();
  final _sectionCompleteController = StreamController<void>.broadcast();

  Stream<Segment?> get activeSegmentStream => _activeSegmentController.stream;
  Stream<void> get sectionCompleteStream => _sectionCompleteController.stream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Duration? get duration => _player.duration;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Segment? _lastActive;

  PlaybackController(this._handler) {
    _posSub = _player.positionStream.listen(_onPosition);
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _sectionCompleteController.add(null);
      }
    });
    _handler.onSkipToNext = seekToNextSegment;
    _handler.onSkipToPrevious = seekToPreviousSegment;
  }

  void _onPosition(Duration pos) {
    if (_segmentsFile == null) return;
    final active = _segmentsFile!.activeAt(pos.inMilliseconds);
    if (active?.segmentId != _lastActive?.segmentId) {
      _lastActive = active;
      _activeSegmentController.add(active);
    }
  }

  /// [mediaItem] seeds the lock-screen/notification display for this
  /// section; its duration is refined once the file is loaded.
  Future<void> loadSection(
    ManifestSection section,
    SegmentsFile segmentsFile,
    String audioFilePath,
    MediaItem mediaItem,
  ) async {
    _section = section;
    _segmentsFile = segmentsFile;
    _lastActive = null;
    _handler.setMediaItem(mediaItem);
    await _player.setFilePath(audioFilePath);
    _handler.setMediaItem(mediaItem.copyWith(duration: _player.duration));
  }

  ManifestSection? get currentSection => _section;
  SegmentsFile? get currentSegments => _segmentsFile;

  Future<void> play() => _handler.play();
  Future<void> pause() => _handler.pause();
  Future<void> stop() => _handler.stop();
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// Seek to an absolute position — used for scrubbing.
  Future<void> seek(Duration position) => _handler.seek(position);

  /// Seek directly to the start of a specific segment (tap-to-jump, or
  /// prev/next segment navigation, including from the lock screen). Works
  /// identically whether autoplay is on or off.
  Future<void> seekToSegment(Segment segment) => _handler.seek(Duration(milliseconds: segment.startMs));

  Future<void> seekToNextSegment() async {
    final segs = _segmentsFile?.segments;
    if (segs == null || segs.isEmpty) return;
    final cur = _lastActive;
    final curIndex = cur == null ? -1 : segs.indexWhere((s) => s.segmentId == cur.segmentId);
    final nextIndex = (curIndex + 1).clamp(0, segs.length - 1);
    await seekToSegment(segs[nextIndex]);
  }

  Future<void> seekToPreviousSegment() async {
    final segs = _segmentsFile?.segments;
    if (segs == null || segs.isEmpty) return;
    final cur = _lastActive;
    final curIndex = cur == null ? 0 : segs.indexWhere((s) => s.segmentId == cur.segmentId);
    final prevIndex = (curIndex - 1).clamp(0, segs.length - 1);
    await seekToSegment(segs[prevIndex]);
  }

  bool get isPlaying => _player.playing;

  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _activeSegmentController.close();
    _sectionCompleteController.close();
    if (identical(_handler.onSkipToNext, seekToNextSegment)) _handler.onSkipToNext = null;
    if (identical(_handler.onSkipToPrevious, seekToPreviousSegment)) _handler.onSkipToPrevious = null;
    // The player itself is NOT disposed here — it's the app-wide singleton
    // owned by FirebratAudioHandler and keeps playing in the background /
    // from the lock screen after this reader session goes away.
  }
}
