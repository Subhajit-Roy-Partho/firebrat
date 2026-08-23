import 'dart:typed_data';
import 'wav_utils.dart';

/// Minimal CAF (Core Audio Format) reader — parses just enough to pull out
/// linear-PCM audio into the same [WavAudio] representation the WAV path
/// uses, so `on_device_tts.dart`'s assembly logic (concatenation, timing)
/// is shared across platforms instead of duplicated. This is what
/// `flutter_tts.synthesizeToFile` produces on iOS/macOS (see its README:
/// `"tts.caf"` for those platforms, `"tts.wav"` for Android).
///
/// **Unverified**: written directly from the CAF spec (Apple TN2091), not
/// tested against real device output — this sandbox has no macOS/Xcode at
/// all, so there is no way to even attempt that here. Treat this as the
/// honest best-effort version of the iOS half of the pipeline; verifying
/// it against a real `AVSpeechSynthesizer`-produced .caf file is the first
/// thing to do on an actual Mac before trusting it. If it's wrong, the
/// WAV path (Android) is unaffected — they don't share parsing code.
class CafAudio {
  static WavAudio parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 8 || String.fromCharCodes(bytes.sublist(0, 4)) != 'caff') {
      throw const FormatException('not a CAF file (missing "caff" magic)');
    }
    // File header: 'caff' (4) + mFileVersion (2, big-endian) + mFileFlags (2, big-endian)
    var offset = 8;

    double? sampleRate;
    int? channels;
    int? bitsPerChannel;
    String? formatId;
    Uint8List? pcm;

    while (offset + 12 <= bytes.length) {
      // Chunk header: mChunkType (4 ascii) + mChunkSize (Int64, big-endian; -1 = "until EOF")
      final chunkType = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSizeRaw = data.getInt64(offset + 4, Endian.big);
      final bodyStart = offset + 12;
      final chunkSize = chunkSizeRaw < 0 ? bytes.length - bodyStart : chunkSizeRaw;
      if (bodyStart + chunkSize > bytes.length) break;

      if (chunkType == 'desc') {
        // AudioStreamBasicDescription, all big-endian:
        // Float64 sampleRate; 4-char formatID; UInt32 formatFlags;
        // UInt32 bytesPerPacket; UInt32 framesPerPacket; UInt32 bytesPerFrame;
        // UInt32 channelsPerFrame; UInt32 bitsPerChannel
        sampleRate = data.getFloat64(bodyStart, Endian.big);
        formatId = String.fromCharCodes(bytes.sublist(bodyStart + 8, bodyStart + 12));
        channels = data.getUint32(bodyStart + 28, Endian.big);
        bitsPerChannel = data.getUint32(bodyStart + 32, Endian.big);
      } else if (chunkType == 'data') {
        // 'data' chunk body starts with a 4-byte "edit count", then raw PCM.
        pcm = bytes.sublist(bodyStart + 4, bodyStart + chunkSize);
      }

      offset = bodyStart + chunkSize;
    }

    if (sampleRate == null || channels == null || bitsPerChannel == null || pcm == null) {
      throw const FormatException('missing desc or data chunk');
    }
    if (formatId != 'lpcm') {
      throw FormatException('unsupported CAF audio format "$formatId" — only linear PCM (lpcm) is handled');
    }
    // Not checked: formatFlags' big/little-endian bit. WAV (and this
    // parser's [WavAudio] output contract) is always little-endian; if a
    // real device emits big-endian lpcm here, samples need byte-swapping
    // before this is correct. Flagged rather than guessed at — see the
    // class doc comment on why this is unverified.

    return WavAudio(
      sampleRate: sampleRate.round(),
      channels: channels,
      bitsPerSample: bitsPerChannel,
      pcmData: pcm,
    );
  }
}
