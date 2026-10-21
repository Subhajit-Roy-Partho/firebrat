import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/models/manifest_models.dart';

void main() {
  test('manifest records the narration engine sample rate in both metadata fields', () {
    final json = Manifest(bookId: 'book', title: 'Book', sourcePdf: 'book.pdf',
      generatedAt: '2026-10-20T00:00:00Z', totalDurationMs: 1000,
      sections: [], figures: [], formulas: [], tables: [],
      narratorEngine: 'on_device_tts', sampleRate: 24000).toJson();
    expect((json['audio_format'] as Map)['sample_rate'], 24000);
    expect((json['narrator_voice'] as Map)['sample_rate'], 24000);
  });
}
