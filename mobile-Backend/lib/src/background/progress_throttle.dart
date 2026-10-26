/// Decides which progress reports are worth forwarding to the UI and the
/// foreground-service notification.
///
/// The pipeline reports progress from inside tight loops (a model download
/// reports once per network chunk, hundreds of times a second on a fast link).
/// Forwarding every report floods Android's notification manager (it starts
/// discarding updates) and janks the UI. This forwards a report when the stage
/// changed, when the work finished, or when at least [minInterval] has passed
/// and something visible actually changed.
class ProgressThrottle {
  final Duration minInterval;
  final DateTime Function() _now;
  String? _stage;
  String? _detail;
  double? _fraction;
  DateTime? _lastEmit;
  final Set<String> _completedStages = {};

  ProgressThrottle({this.minInterval = const Duration(milliseconds: 500), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  bool shouldEmit({required String stage, required String detail, required double fraction}) {
    final now = _now();
    final stageChanged = stage != _stage;
    // Downloads/pages may reset their local fraction repeatedly within the
    // same stage. Each 0 -> 1 must not bypass the notification rate limit.
    final finished = fraction >= 1.0 && !_completedStages.contains(stage);
    final changed = detail != _detail || (fraction - (_fraction ?? -1)).abs() >= 0.005;
    final due = _lastEmit == null || now.difference(_lastEmit!) >= minInterval;
    if (stageChanged || finished || (due && changed)) {
      _stage = stage;
      _detail = detail;
      _fraction = fraction;
      _lastEmit = now;
      if (fraction >= 1.0) _completedStages.add(stage);
      return true;
    }
    return false;
  }
}
