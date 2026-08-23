/// The image or formula currently on screen — drives both the Focus Mode
/// full-screen view and the lock-screen/notification artwork, so both stay
/// in lockstep with the same "what's being talked about right now" state.
enum VisualKind { figure, table, formula }

class VisualItem {
  final String id;
  final VisualKind kind;
  final String imagePath;
  final String caption;
  final String? latex; // set only for VisualKind.formula

  const VisualItem({
    required this.id,
    required this.kind,
    required this.imagePath,
    required this.caption,
    this.latex,
  });
}
