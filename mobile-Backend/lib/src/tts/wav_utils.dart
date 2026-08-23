import 'dart:typed_data';

/// Minimal PCM WAV (RIFF/WAVE) reader/writer/concatenator — pure Dart, no
/// native codec dependency. This gives sample-accurate segment timing the
/// same way `backend/firebrat/pipeline/audio_assemble.py`'s
/// `compute_timeline()` does server-side (real durations from real audio,
/// not estimated), without needing ffmpeg on-device.
///
/// Used for `flutter_tts`'s Android output, which is linear-PCM WAV (see
/// `on_device_tts.dart`'s doc comment on platform format differences).
class WavAudio {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final Uint8List pcmData; // raw little-endian PCM samples, no header

  const WavAudio({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.pcmData,
  });

  int get bytesPerSample => bitsPerSample ~/ 8;
  int get frameCount => pcmData.length ~/ (bytesPerSample * channels);
  int get durationMs => (frameCount * 1000) ~/ sampleRate;

  /// Parses a standard RIFF/WAVE file, walking chunks (so it tolerates
  /// extra metadata chunks some encoders insert between 'fmt ' and 'data').
  factory WavAudio.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('not a RIFF/WAVE file');
    }

    int? sampleRate;
    int? channels;
    int? bitsPerSample;
    Uint8List? pcm;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final bodyStart = offset + 8;
      if (bodyStart + chunkSize > bytes.length) break;

      if (chunkId == 'fmt ') {
        channels = data.getUint16(bodyStart + 2, Endian.little);
        sampleRate = data.getUint32(bodyStart + 4, Endian.little);
        bitsPerSample = data.getUint16(bodyStart + 14, Endian.little);
      } else if (chunkId == 'data') {
        pcm = bytes.sublist(bodyStart, bodyStart + chunkSize);
      }

      offset = bodyStart + chunkSize + (chunkSize.isOdd ? 1 : 0); // chunks are word-aligned
    }

    if (sampleRate == null || channels == null || bitsPerSample == null || pcm == null) {
      throw const FormatException('missing fmt or data chunk');
    }
    return WavAudio(sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample, pcmData: pcm);
  }

  Uint8List _silence(int ms) {
    final frames = (sampleRate * ms) ~/ 1000;
    return Uint8List(frames * bytesPerSample * channels); // zeroed = silence
  }

  /// Serializes a standard 44-byte-header PCM WAV file.
  Uint8List toBytes() {
    final dataLen = pcmData.length;
    final buffer = ByteData(44 + dataLen);
    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    buffer.setUint32(4, 36 + dataLen, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format tag
    buffer.setUint16(22, channels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little); // byte rate
    buffer.setUint16(32, channels * bytesPerSample, Endian.little); // block align
    buffer.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    buffer.setUint32(40, dataLen, Endian.little);

    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(44, 44 + dataLen, pcmData);
    return bytes;
  }

  /// Concatenates [clips] with [pauseMs] of silence between each, returning
  /// the combined audio and each clip's (startMs, endMs) — sample-accurate,
  /// derived from each clip's real PCM length, exactly mirroring
  /// `compute_timeline()`'s approach server-side. All clips must share
  /// [sampleRate]/[channels]/[bitsPerSample] (true for same-engine TTS output).
  static ({WavAudio combined, List<({int startMs, int endMs})> timing}) concatenate(
    List<WavAudio> clips, {
    int pauseMs = 260,
  }) {
    if (clips.isEmpty) {
      throw ArgumentError('cannot concatenate zero clips');
    }
    final first = clips.first;
    final parts = <int>[];
    final timing = <({int startMs, int endMs})>[];
    var cursorMs = 0;
    final combinedBytes = BytesBuilder();

    for (var i = 0; i < clips.length; i++) {
      final clip = clips[i];
      if (i > 0) {
        combinedBytes.add(first._silence(pauseMs));
        cursorMs += pauseMs;
      }
      combinedBytes.add(clip.pcmData);
      final startMs = cursorMs;
      final endMs = cursorMs + clip.durationMs;
      timing.add((startMs: startMs, endMs: endMs));
      cursorMs = endMs;
      parts.add(clip.pcmData.length);
    }

    final combined = WavAudio(
      sampleRate: first.sampleRate,
      channels: first.channels,
      bitsPerSample: first.bitsPerSample,
      pcmData: combinedBytes.toBytes(),
    );
    return (combined: combined, timing: timing);
  }
}
