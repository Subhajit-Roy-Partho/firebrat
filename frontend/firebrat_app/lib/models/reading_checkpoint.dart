/// Small metadata only. A signature prevents seeking into another conversion.
class ReadingCheckpoint {
  final String sectionId;
  final int positionMs;
  final int updatedAtMs;
  final String signature;
  const ReadingCheckpoint({
    required this.sectionId,
    required this.positionMs,
    required this.updatedAtMs,
    required this.signature,
  });

  Map<String, dynamic> toJson() => {
    'sectionId': sectionId,
    'positionMs': positionMs,
    'updatedAtMs': updatedAtMs,
    'signature': signature,
  };

  static ReadingCheckpoint? fromJson(Map<String, dynamic>? json) {
    if (json == null ||
        json['sectionId'] is! String ||
        json['signature'] is! String ||
        json['positionMs'] is! int ||
        json['updatedAtMs'] is! int ||
        (json['positionMs'] as int) < 0 ||
        (json['updatedAtMs'] as int) < 0) {
      return null;
    }
    return ReadingCheckpoint(
      sectionId: json['sectionId'],
      positionMs: json['positionMs'],
      updatedAtMs: json['updatedAtMs'],
      signature: json['signature'],
    );
  }
}

ReadingCheckpoint? newestCheckpoint(
  ReadingCheckpoint? local,
  ReadingCheckpoint? remote,
  String signature,
) {
  if (local?.signature != signature) local = null;
  if (remote?.signature != signature) remote = null;
  if (local == null) return remote;
  if (remote == null) return local;
  return remote.updatedAtMs > local.updatedAtMs ? remote : local;
}
