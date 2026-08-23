import 'dart:convert';
import 'dart:io';
import '../compilation/chunker.dart';
import '../compilation/cloud_compiler.dart';
import '../compilation/compilation_router.dart';
import '../compilation/on_device_compiler.dart';
import '../extraction/pdf_text_extractor.dart';
import '../models/compiled_models.dart';
import '../models/conversion_settings.dart';
import '../models/manifest_models.dart';
import '../tts/on_device_tts.dart';
import '../util/ids.dart';

/// Progress reported as the pipeline runs, mirroring the stage names in
/// `firebrat.pipeline.status` server-side (`extracting`, `compiling`,
/// `synthesizing`, `done`) so a host UI's progress display can look the
/// same regardless of which pipeline produced it.
class MobileConversionProgress {
  final String stage;
  final String detail;
  final double? fraction;
  const MobileConversionProgress({required this.stage, required this.detail, this.fraction});
}

typedef ProgressCallback = void Function(MobileConversionProgress progress);

/// Runs the whole PDF -> book-package conversion on-device: text-layer
/// extraction, chunk-routed compilation (on-device model for easy chunks,
/// user-configured cloud LLM for hard ones), and on-device TTS narration —
/// writing the result in exactly the directory layout
/// `frontend/firebrat_app`'s `LibraryRepository`/`DownloadManager` already
/// expect (see `docs/DATA_SCHEMA.md`), so a book converted here is
/// indistinguishable to the reader from one downloaded from a server.
///
/// See package README "Known limitations" — no figure/table extraction in
/// this v1 (empty catalog), and TTS is a fixed on-device voice, not the
/// cloud pipeline's cloned narrator voice.
class MobileConversionPipeline {
  final OnDeviceModeSettings settings;
  final ProgressCallback? onProgress;

  MobileConversionPipeline({required this.settings, this.onProgress});

  void _report(String stage, String detail, [double? fraction]) {
    onProgress?.call(MobileConversionProgress(stage: stage, detail: detail, fraction: fraction));
  }

  /// [pdfPath] is the source PDF; [booksRootDir] is the app's local
  /// library root (each book lives at `$booksRootDir/$bookId/`) — pass the
  /// same directory `DownloadManager.booksDir()` uses in the host app so
  /// the result shows up in the existing library listing with zero glue
  /// code beyond calling this pipeline instead of the network download path.
  Future<String> convert({
    required String pdfPath,
    required String booksRootDir,
    String? titleOverride,
  }) async {
    final fileName = pdfPath.split(Platform.pathSeparator).last;
    final bookId = sanitizeBookId(fileName);
    final title = titleOverride ?? bookId.replaceAll('-', ' ');
    final bookDir = '$booksRootDir/$bookId';
    await Directory(bookDir).create(recursive: true);

    _report('extracting', 'reading PDF text layer', 0.0);
    final extraction = await MobilePdfTextExtractor.extractPages(pdfPath);
    if (extraction.ocrCandidatePageIndices.isNotEmpty) {
      // See ocr_fallback.dart — OCR is wired up but page rasterization
      // (image-of-a-page -> bitmap) isn't implemented in this v1, so
      // these pages are narrated from whatever sparse text they have
      // rather than silently dropped.
      _report(
        'extracting',
        '${extraction.ocrCandidatePageIndices.length} page(s) look scanned (little/no text layer) — OCR fallback not yet implemented, see README',
        0.5,
      );
    }

    final chunks = chunkPages(extraction.pages, chunkPages: 10);
    _report('compiling', '0/${chunks.length} chunks', 0.0);

    final onDeviceCompiler = OnDeviceCompiler(modelSlug: settings.onDeviceModelSlug ?? 'qwen3-0.6');
    await onDeviceCompiler.ensureReady(
      onProgress: (progress, status) => _report('compiling', 'downloading on-device model: $status', progress),
    );
    final cloudCompiler = CloudCompiler(settings);
    final router = CompilationRouter(onDeviceCompiler: onDeviceCompiler, cloudCompiler: cloudCompiler);

    final List<CompiledSection> compiledSections;
    try {
      compiledSections = await router.compileAll(
        chunks,
        onChunkDone: (done, total, usedCloud) =>
            _report('compiling', '$done/$total chunks (${usedCloud ? "cloud" : "on-device"})', done / total),
      );
    } finally {
      onDeviceCompiler.dispose();
    }

    _report('synthesizing', '0/${compiledSections.length} sections', 0.0);
    final tts = OnDeviceTts();
    final manifestSections = <ManifestSection>[];
    final manifestFormulas = <ManifestFormula>[];
    var totalDurationMs = 0;

    try {
      for (var i = 0; i < compiledSections.length; i++) {
        final section = compiledSections[i];
        final sectionId = makeSectionId(i + 1);
        final sectionDir = '$bookDir/sections/$sectionId';

        final result = await tts.narrateSection(
          sectionId: sectionId,
          segments: section.segments,
          sectionDir: sectionDir,
        );

        final segmentsPath = '$sectionDir/segments.json';
        await File(segmentsPath).writeAsString(jsonEncode(result.segmentsFile.toJson()));

        final formulaRefs = <String>[];
        for (final seg in section.segments) {
          if (seg.type == SegmentKind.formulaCallout && seg.ref != null) {
            formulaRefs.add(seg.ref!);
            manifestFormulas.add(ManifestFormula(
              formulaId: seg.ref!,
              latex: seg.latex ?? '',
              imagePath: '', // no server-side PNG renderer on-device — flutter_math_fork renders the LaTeX directly, see formula_view.dart
              spokenText: seg.text,
              visuallyEssential: seg.visuallyEssential,
              page: section.sourcePages.isNotEmpty ? section.sourcePages.first : 0,
            ));
          }
        }

        final durationMs = result.segmentsFile.segments.isEmpty ? 0 : result.segmentsFile.segments.last.endMs;
        totalDurationMs += durationMs;

        manifestSections.add(ManifestSection(
          sectionId: sectionId,
          order: i + 1,
          title: section.title,
          audioPath: 'sections/$sectionId/audio.wav',
          segmentsPath: 'sections/$sectionId/segments.json',
          durationMs: durationMs,
          figureRefs: const [],
          formulaRefs: formulaRefs,
          tableRefs: const [],
        ));

        _report('synthesizing', '${i + 1}/${compiledSections.length} sections', (i + 1) / compiledSections.length);
      }
    } finally {
      tts.dispose();
    }

    final manifest = Manifest(
      bookId: bookId,
      title: title,
      sourcePdf: fileName,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      totalDurationMs: totalDurationMs,
      sections: manifestSections,
      figures: const [],
      formulas: manifestFormulas,
      tables: const [],
      narratorEngine: 'on_device_tts',
    );
    await File('$bookDir/manifest.json').writeAsString(jsonEncode(manifest.toJson()));

    _report('done', '${manifestSections.length} sections, ${manifestFormulas.length} formulas', 1.0);
    return bookId;
  }
}
