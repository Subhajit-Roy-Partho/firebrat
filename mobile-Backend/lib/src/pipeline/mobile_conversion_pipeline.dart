import 'dart:convert';
import 'dart:io';
import '../compilation/chunker.dart';
import '../compilation/cloud_compiler.dart';
import '../compilation/compilation_router.dart';
import '../compilation/model_catalog.dart';
import '../compilation/on_device_compiler.dart';
import '../extraction/pdf_text_extractor.dart';
import '../extraction/page_visuals.dart';
import '../extraction/ocr_fallback.dart';
import '../novel/novel_analyzer.dart';
import '../models/compiled_models.dart';
import '../models/conversion_settings.dart';
import '../models/manifest_models.dart';
import '../tts/kokoro_tts_engine.dart';
import '../tts/narration_engine.dart';
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
/// extraction, local compilation (with an optional cloud helper), and
/// offline TTS narration —
/// writing the result in exactly the directory layout
/// `frontend/firebrat_app`'s `LibraryRepository`/`DownloadManager` already
/// expect (see `docs/DATA_SCHEMA.md`), so a book converted here is
/// indistinguishable to the reader from one downloaded from a server.
///
/// Original page visuals preserve pictures without individual figure detection.
/// Both on-device voice options (stock TTS or
/// Kokoro-82M, see `models/conversion_settings.dart`'s `OnDeviceVoiceEngine`)
/// are fixed-preset voices, not the cloud pipeline's cloned narrator voice.
class MobileConversionPipeline {
  final OnDeviceModeSettings settings;
  final ProgressCallback? onProgress;

  MobileConversionPipeline({required this.settings, this.onProgress});

  void _report(String stage, String detail, [double? fraction]) {
    onProgress?.call(MobileConversionProgress(stage: stage, detail: detail, fraction: fraction));
  }

  /// [pdfPaths] is one source PDF, or several (a zipped book's chapters
  /// in reading order — the host app unzips first and passes the sorted
  /// PDF list). Multiple PDFs are merged at the text layer (page indices
  /// offset per file, see `mergeExtractions`): this is exactly equivalent
  /// to converting one pre-merged PDF, because extraction only reads each
  /// file's text layer — no binary PDF merge library exists for pure-Dart
  /// on-device use, and none is needed. [booksRootDir] is the app's local
  /// library root (each book lives at `$booksRootDir/$bookId/`) — pass the
  /// same directory `DownloadManager.booksDir()` uses in the host app so
  /// the result shows up in the existing library listing with zero glue
  /// code beyond calling this pipeline instead of the network download path.
  /// [modelsDir] is where downloaded on-device model weights (LLM GGUF,
  /// Kokoro's ONNX model) are cached across conversions — pass a stable
  /// app-storage directory (e.g. application-support, not a temp dir) so
  /// a multi-GB model isn't re-downloaded on every book.
  Future<String> convert({
    required List<String> pdfPaths,
    required String booksRootDir,
    required String modelsDir,
    String? titleOverride,
  }) async {
    if (pdfPaths.isEmpty) {
      throw ArgumentError('convert needs at least one source PDF');
    }
    final displayName = titleOverride ??
        pdfPaths.first.split(Platform.pathSeparator).last;
    final bookId = sanitizeBookId(
        titleOverride != null ? '$titleOverride.pdf' : pdfPaths.first.split(Platform.pathSeparator).last);
    final title = titleOverride ?? bookId.replaceAll('-', ' ');
    final bookDir = '$booksRootDir/$bookId';
    await Directory(bookDir).create(recursive: true);

    // Ship the source PDF inside the package so the reader can offer a
    // "view source page" feature (mirrors the server pipeline's
    // source.pdf handling — same relative path, same manifest fields).
    // Only possible for a single PDF: a chapter list has no one file to
    // ship, so multi-PDF books simply hide the "Source page" button
    // (same old-package path as a book converted before this existed).
    const sourcePdfPath = 'source.pdf';
    String? shippedSourcePdf;
    if (pdfPaths.length == 1) {
      try {
        await File(pdfPaths.first).copy('$bookDir/$sourcePdfPath');
        shippedSourcePdf = sourcePdfPath;
      } catch (_) {
        // A book without its source PDF is still fully readable — the
        // reader simply hides the "Source page" button (old-package path).
        shippedSourcePdf = null;
      }
    }

    _report('extracting', 'reading PDF text layer (1/${pdfPaths.length} files)', 0.0);
    final parts = <ExtractionResult>[];
    for (var i = 0; i < pdfPaths.length; i++) {
      var part = await MobilePdfTextExtractor.extractPages(pdfPaths[i]);
      if (part.ocrCandidatePageIndices.isNotEmpty && Platform.isAndroid) {
        final ocr = OcrFallback();
        try {
          final replacements = await ocr.reExtractPages(pdfPaths[i], part.ocrCandidatePageIndices, '$bookDir/ocr');
          final byIndex = {for (final p in replacements) p.pageIdx: p};
          part = ExtractionResult(pages: [for (final p in part.pages) byIndex[p.pageIdx] ?? p], ocrCandidatePageIndices: []);
        } finally { ocr.dispose(); }
      }
      parts.add(part);
      _report('extracting',
          'reading PDF text layer (${i + 1}/${pdfPaths.length} files)', (i + 1) / pdfPaths.length * 0.5);
    }
    final extraction = mergeExtractions(parts);
    if (extraction.pages.isEmpty || extraction.pages.every((p) => p.text.trim().isEmpty)) {
      throw StateError('No readable text was found in this document.');
    }
    final isNovel = settings.contentMode == BookContentMode.novel;
    final novelPlan = isNovel ? NovelBookPlan.analyze(extraction.pages, voiceOverrides: settings.characterVoices) : null;
    if (novelPlan != null) {
      await File('$bookDir/character_roster.json').writeAsString(jsonEncode({...novelPlan.toJson(),
        'voice_engine': settings.voiceEngine.name,
        if (settings.voiceEngine == OnDeviceVoiceEngine.kokoroOnnx)
          'assigned_voices': {for (final character in novelPlan.characters)
            character.name: resolveKokoroCharacterVoice(character, narrator: settings.kokoroVoice, male: settings.maleVoice, female: settings.femaleVoice)},
      }));
      _report('extracting', 'scanned ${novelPlan.scannedPages} pages; ${novelPlan.characters.length} explicitly attributed characters', 0.75);
    }
    _report('extracting', 'preserving original page visuals', 0.8);
    final pageVisuals = isNovel ? <ManifestFigure>[] : await PageVisuals.render(pdfPaths: pdfPaths, bookDir: bookDir, pages: extraction.pages);

    final chunks = settings.allowCloudFallback
        ? chunkPages(extraction.pages, chunkPages: 10)
        : chunkLocalPages(extraction.pages);
    _report('compiling', '0/${chunks.length} chunks', 0.0);

    final List<CompiledSection> compiledSections;
    if (isNovel) {
      // A novel is read verbatim. Educational paraphrasing destroys dialogue
      // attribution and is neither required nor safe for narrative fiction.
      compiledSections = [for (final chunk in chunkLocalPages(extraction.pages))
        CompiledSection(title: 'Page ${chunk.startPage + 1}', sourcePages: [chunk.startPage],
          segments: [CompiledSegment(type: SegmentKind.prose, text: chunk.pages.single.text)])];
      _report('compiling', 'preserved novel text and full-book voice roster', 1.0);
    } else {
    final onDeviceCompiler = OnDeviceCompiler(
      model: findOnDeviceLlmModel(settings.onDeviceLlmModelId),
      gpuLayers: settings.onDeviceGpuLayers,
    );
    try {
    await onDeviceCompiler.ensureReady(
      modelsDir: '$modelsDir/llm',
      onProgress: (progress, status) => _report('compiling', status, progress),
    );
    final cloudCompiler = settings.allowCloudFallback ? CloudCompiler(settings) : null;
    final router = CompilationRouter(onDeviceCompiler: onDeviceCompiler, cloudCompiler: cloudCompiler, allowCloudFallback: settings.allowCloudFallback);

      compiledSections = await router.compileAll(
        chunks,
        checkpointDir: '$bookDir/checkpoints/compilation',
        onChunkDone: (done, total, usedCloud) =>
            _report('compiling', '$done/$total chunks (${usedCloud ? "cloud" : "on-device"})', done / total),
      );
    } finally {
      await onDeviceCompiler.dispose();
    }

    }

    _report('synthesizing', '0/${compiledSections.length} sections', 0.0);
    final NarrationEngine tts;
    final String narratorEngineName;
    if (settings.voiceEngine == OnDeviceVoiceEngine.kokoroOnnx) {
      final kokoro = KokoroTtsEngine(voice: settings.kokoroVoice, maleVoice: settings.maleVoice, femaleVoice: settings.femaleVoice, novelPlan: novelPlan);
      await kokoro.ensureReady(
        onProgress: (progress, status) => _report('synthesizing', status, progress),
      );
      tts = kokoro;
      narratorEngineName = 'kokoro_onnx';
    } else {
      tts = OnDeviceTts(novelPlan: novelPlan);
      narratorEngineName = 'on_device_tts';
    }
    final manifestSections = <ManifestSection>[];
    final manifestFormulas = <ManifestFormula>[];
    var totalDurationMs = 0;
    int? audioSampleRate;

    try {
      for (var i = 0; i < compiledSections.length; i++) {
        final original = compiledSections[i];
        final visuals = pageVisuals.where((f) => original.sourcePages.contains(f.page)).toList();
        final segments = [...original.segments];
        // Attach each original page at a spoken segment without inventing
        // a figure description. Full-page views retain all vector/table layout.
        for (var v = 0; v < visuals.length && segments.isNotEmpty; v++) {
          final index = segments.indexWhere((s) => s.type == SegmentKind.prose && s.ref == null);
          if (index < 0) break;
          final old = segments[index];
          segments[index] = CompiledSegment(type: SegmentKind.figureCallout,
            text: old.text, ref: visuals[v].figureId, visuallyEssential: true);
        }
        final section = CompiledSection(title: original.title, sourcePages: original.sourcePages, segments: segments);
        final sectionId = makeSectionId(i + 1);
        final sectionDir = '$bookDir/sections/$sectionId';

        final result = await tts.narrateSection(
          sectionId: sectionId,
          segments: section.segments,
          sectionDir: sectionDir,
        );

        if (audioSampleRate != null && audioSampleRate != result.segmentsFile.sampleRate) {
          throw StateError('Narration sample rate changed between sections');
        }
        audioSampleRate = result.segmentsFile.sampleRate;
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
          figureRefs: visuals.map((f) => f.figureId).toList(),
          formulaRefs: formulaRefs,
          tableRefs: const [],
          sourcePages: section.sourcePages,
        ));

        _report('synthesizing', '${i + 1}/${compiledSections.length} sections', (i + 1) / compiledSections.length);
      }
    } finally {
      tts.dispose();
    }

    final manifest = Manifest(
      bookId: bookId,
      title: title,
      sourcePdf: displayName,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      totalDurationMs: totalDurationMs,
      sampleRate: audioSampleRate ?? 22050,
      sections: manifestSections,
      figures: pageVisuals,
      formulas: manifestFormulas,
      tables: const [],
      narratorEngine: narratorEngineName,
      sourcePdfPath: shippedSourcePdf,
    );
    await File('$bookDir/manifest.json').writeAsString(jsonEncode(manifest.toJson()));

    _report('done', '${manifestSections.length} sections, ${manifestFormulas.length} formulas', 1.0);
    return bookId;
  }
}
