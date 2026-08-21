import 'dart:async';
import 'package:just_audio/just_audio.dart';
import '../models/manifest.dart';
import '../models/segment.dart';

/// Wraps just_audio for one section's combined track, exposing the
/// currently-active segment (for highlight sync) and section-complete
/// events (for autoplay). Manual seeks always work regardless of autoplay
/// state — this is what keeps "always free to go back and forth" true.
class PlaybackController {
  final AudioPlayer _player = AudioPlayer();

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

  PlaybackController() {
    _posSub = _player.positionStream.listen(_onPosition);
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _sectionCompleteController.add(null);
      }
    });
  }

  void _onPosition(Duration pos) {
    if (_segmentsFile == null) return;
    final active = _segmentsFile!.activeAt(pos.inMilliseconds);
    if (active?.segmentId != _lastActive?.segmentId) {
      _lastActive = active;
      _activeSegmentController.add(active);
    }
  }

  Future<void> loadSection(
    ManifestSection section,
    SegmentsFile segmentsFile,
    String audioFilePath,
  ) async {
    _section = section;
    _segmentsFile = segmentsFile;
    _lastActive = null;
    await _player.setFilePath(audioFilePath);
  }

  ManifestSection? get currentSection => _section;
  SegmentsFile? get currentSegments => _segmentsFile;

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// Seek to an absolute position — used for scrubbing.
  Future<void> seek(Duration position) => _player.seek(position);

  /// Seek directly to the start of a specific segment (tap-to-jump, or
  /// prev/next segment navigation). Works identically whether autoplay
  /// is on or off.
  Future<void> seekToSegment(Segment segment) => _player.seek(Duration(milliseconds: segment.startMs));

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
    _player.dispose();
  }
}
