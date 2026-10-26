import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:mobile_backend_pipeline/src/background/progress_throttle.dart';

void main() {
  test('a download reporting hundreds of times a second is cut to a few updates', () {
    var t = DateTime(2026, 1, 1);
    final throttle = ProgressThrottle(now: () => t);
    var emitted = 0;
    for (var i = 0; i < 2000; i++) {
      t = t.add(const Duration(milliseconds: 1)); // 1000 reports per second
      if (throttle.shouldEmit(stage: 'synthesizing', detail: 'Downloading model...', fraction: i / 2000)) emitted++;
    }
    expect(emitted, lessThanOrEqualTo(5)); // 2 s of reports -> about one per half second
    expect(emitted, greaterThanOrEqualTo(2));
  });

  test('stage changes and completion are never dropped', () {
    var t = DateTime(2026, 1, 1);
    final throttle = ProgressThrottle(now: () => t);
    expect(throttle.shouldEmit(stage: 'extracting', detail: 'a', fraction: .1), isTrue);
    expect(throttle.shouldEmit(stage: 'extracting', detail: 'b', fraction: .2), isFalse); // too soon
    expect(throttle.shouldEmit(stage: 'compiling', detail: 'b', fraction: .2), isTrue); // new stage
    expect(throttle.shouldEmit(stage: 'compiling', detail: 'b', fraction: 1.0), isTrue); // finished
    t = t.add(const Duration(seconds: 1));
    expect(throttle.shouldEmit(stage: 'compiling', detail: 'b', fraction: 1.0), isFalse); // nothing changed
  });

  test('repeated per-file completion does not flood notifications', () {
    var t = DateTime(2026, 1, 1);
    final throttle = ProgressThrottle(now: () => t);
    var emitted = 0;
    for (var i = 0; i < 1000; i++) {
      t = t.add(const Duration(milliseconds: 1));
      if (throttle.shouldEmit(stage: 'extracting', detail: 'page $i',
          fraction: i.isEven ? 0 : 1)) {
        emitted++;
      }
    }
    expect(emitted, lessThanOrEqualTo(4));
    expect(throttle.shouldEmit(stage: 'synthesizing', detail: 'ready',
        fraction: 0), isTrue);
    expect(throttle.shouldEmit(stage: 'done', detail: 'complete',
        fraction: 1), isTrue);
  });

  test('a request knows which book folder it writes into', () {
    const a = ConversionRequest(pdfPath: '/x/My Novel.pdf', booksRootDir: 'b', modelsDir: 'm', llmBaseUrl: '', llmApiKey: '', llmModel: '');
    expect(a.bookId, 'my-novel');
    const b = ConversionRequest(pdfPath: '/x/a.epub', titleOverride: 'Zip Book', booksRootDir: 'b', modelsDir: 'm', llmBaseUrl: '', llmApiKey: '', llmModel: '');
    expect(b.bookId, 'zip-book');
  });
}
