import 'dart:convert';
import 'dart:io';
import '../compilation/chunker.dart';
import '../compilation/cloud_compiler.dart';
import '../compilation/compilation_router.dart';
import '../compilation/model_catalog.dart';
import '../compilation/on_device_compiler.dart';
import '../compilation/prose_fidelity.dart';
import '../extraction/ebook_text_extractor.dart';
import '../extraction/pdf_text_extractor.dart';
import '../extraction/page_visuals.dart';
import '../extraction/ocr_fallback.dart';
import '../llm/llm_endpoint.dart';
import '../novel/character_research.dart';
import '../novel/local_character_research.dart';
import '../novel/character_traits.dart';
import '../novel/novel_analyzer.dart';
import '../models/compiled_models.dart';
import '../models/conversion_settings.dart';
import '../models/device_capabilities.dart';
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
    var title = titleOverride ?? bookId.replaceAll('-', ' ');
    final hasEbook = pdfPaths.any(isEbookPath);
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
    // An ebook (EPUB/MOBI/AZW) has no PDF pages to link to.
    if (pdfPaths.length == 1 && !hasEbook) {
      try {
        await File(pdfPaths.first).copy('$bookDir/$sourcePdfPath');
        shippedSourcePdf = sourcePdfPath;
      } catch (_) {
        // A book without its source PDF is still fully readable — the
        // reader simply hides the "Source page" button (old-package path).
        shippedSourcePdf = null;
      }
    }

    _report('extracting', hasEbook ? 'reading ebook text' : 'reading PDF text layer (1/${pdfPaths.length} files)', 0.0);
    final parts = <ExtractionResult>[];
    String? ebookTitle;
    for (var i = 0; i < pdfPaths.length; i++) {
      late ExtractionResult part;
      if (isEbookPath(pdfPaths[i])) {
        final content = await EbookTextExtractor.read(pdfPaths[i]);
        ebookTitle ??= content.title;
        // The book's own front cover, if it has one: the app shows cover.* at the package root.
        final cover = content.cover;
        if (cover != null) {
          for (final old in ['.jpg', '.png', '.webp']) {
            final stale = File('$bookDir/cover$old');
            if (await stale.exists()) await stale.delete();
          }
          await File('$bookDir/cover${cover.ext}').writeAsBytes(cover.bytes);
        }
        part = ExtractionResult(
            pages: EbookTextExtractor.chaptersToPages(content.chapters), ocrCandidatePageIndices: const []);
      } else {
        part = await MobilePdfTextExtractor.extractPages(pdfPaths[i]);
      }
      if (part.ocrCandidatePageIndices.isNotEmpty && Platform.isAndroid) {
        final ocr = OcrFallback();
        try {
          final replacements = await ocr.reExtractPages(pdfPaths[i], part.ocrCandidatePageIndices, '$bookDir/ocr');
          final byIndex = {for (final p in replacements) p.pageIdx: p};
          part = ExtractionResult(pages: [for (final p in part.pages) byIndex[p.pageIdx] ?? p], ocrCandidatePageIndices: []);
          final blank = replacements.where((p) => p.text.isEmpty).length;
          if (blank > 0) {
            _report('extracting', '$blank of ${replacements.length} scanned pages had no readable text (blank or picture-only)', 0.4);
          }
        } finally { ocr.dispose(); }
      }
      parts.add(part);
      _report('extracting',
          'reading PDF text layer (${i + 1}/${pdfPaths.length} files)', (i + 1) / pdfPaths.length * 0.5);
    }
    if (titleOverride == null && ebookTitle != null && ebookTitle.isNotEmpty) title = ebookTitle;
    final extraction = mergeExtractions(parts);
    // A single PDF whose first page looks like a cover (little text): use it as the book cover.
    if (!hasEbook && pdfPaths.length == 1 && extraction.pages.isNotEmpty &&
        PageVisuals.looksLikeCover(extraction.pages.first.text)) {
      await PageVisuals.renderCover(pdfPath: pdfPaths.first, bookDir: bookDir);
    }
    if (extraction.pages.isEmpty || extraction.pages.every((p) => p.text.trim().isEmpty)) {
      throw StateError('No readable text was found in this document.');
    }
    final isNovel = settings.contentMode == BookContentMode.novel;
    var novelPlan = isNovel ? NovelBookPlan.analyze(extraction.pages, voiceOverrides: settings.characterVoices) : null;
    Map<String, dynamic>? researchReport;
    // Automatic character research: needs only an LLM URL, key and model (not the
    // "cloud helper"), and sends just the title and character names.
    // A book being resumed keeps the cast it was already narrated with, so a
    // second web lookup can never change a voice halfway through.
    final resuming = await File('$bookDir/$_checkpointName').exists();
    final researchCache = File('$bookDir/${settings.localCharacterResearch ? 'local_research_cache.json' : 'research_cache.json'}');
    CharacterResearchResult? cachedResearch;
    if (resuming && await researchCache.exists()) {
      try {
        final j = jsonDecode(await researchCache.readAsString()) as Map<String, dynamic>;
        cachedResearch = CharacterResearchResult({
          for (final e in (j['traits'] as Map).entries)
            e.key as String: CharacterTraits.fromJson(e.value as Map, source: settings.localCharacterResearch ? 'local_book' : 'web'),
        }, sources: (j['sources'] as List).cast<String>(), missing: (j['missing'] as List).cast<String>(), source: (j['source'] as String?) ?? 'Wikipedia');
      } catch (_) {
        cachedResearch = null;
      }
    }
    if (novelPlan != null && cachedResearch != null && cachedResearch.traits.isNotEmpty) {
      researchReport = cachedResearch.toJson();
      novelPlan = novelPlan.withResearch(cachedResearch.traits);
      _report('extracting', 'reusing the cast from the earlier run (${cachedResearch.traits.length} characters)', 0.76);
    } else if (novelPlan != null && settings.localCharacterResearch) {
      final local = OnDeviceCompiler(model: findOnDeviceLlmModel(settings.onDeviceLlmModelId),
          gpuLayers: settings.onDeviceGpuLayers);
      try {
        await local.ensureReady(modelsDir: '$modelsDir/llm', allowDownload: false,
            onProgress: (_, status) => _report('extracting', status, 0.72));
        final result = await LocalCharacterResearcher(generate: (system, prompt) =>
            local.generateText(systemPrompt: system, userMessage: prompt,
                maxTokens: 700, label: 'local character research')).research(
          pages: extraction.pages, names: [for (final c in novelPlan.characters) c.name],
          onProgress: (status) => _report('extracting', status, 0.73));
        researchReport = result.toJson();
        if (result.traits.isNotEmpty) {
          novelPlan = novelPlan.withResearch(result.traits);
          await researchCache.writeAsString(jsonEncode({
            'traits': {for (final e in result.traits.entries) e.key: e.value.toJson()},
            'source': result.source, 'sources': result.sources, 'missing': result.missing,
          }));
        }
        _report('extracting', 'local evidence described ${result.traits.length} characters; '
            '${result.missing.length} keep unknown traits', 0.76);
      } catch (e) {
        _report('extracting', 'local character research skipped: $e', 0.76);
      } finally {
        // Never retain the LLM/GPU allocation while Kokoro starts.
        await local.dispose();
      }
    } else if (novelPlan != null && settings.researchCharacters) {
      if (settings.llmBaseUrl.trim().isEmpty || settings.llmApiKey.trim().isEmpty || settings.llmModel.trim().isEmpty) {
        _report('extracting', 'character research skipped: add an LLM URL, key and model in Conversion settings', 0.72);
      } else {
        _report('extracting', 'researching characters online (only the title and names are sent)', 0.72);
        final result = await CharacterResearcher(
          llm: LlmEndpoint(baseUrl: settings.llmBaseUrl, apiKey: settings.llmApiKey),
          model: settings.llmModel,
        ).research(
          title: title,
          names: [for (final c in novelPlan.characters) c.name],
          onProgress: (status) => _report('extracting', status, 0.73),
        );
        researchReport = result.toJson();
        if (result.traits.isNotEmpty) {
          await researchCache.writeAsString(jsonEncode({
            'traits': {for (final e in result.traits.entries) e.key: e.value.toJson()},
            'sources': result.sources,
            'source': result.source,
            'missing': result.missing,
          }));
          novelPlan = novelPlan.withResearch(result.traits);
          final extra = result.missing.isEmpty ? '' : '; ${result.missing.length} not described';
          _report('extracting', 'cast ${result.traits.length} characters from ${result.sourceTitle}$extra', 0.76);
        } else {
          _report('extracting', 'character research skipped: ${result.skipped}', 0.76);
        }
      }
    }
    if (novelPlan != null && novelPlan.unmatchedOverrides.isNotEmpty) {
      _report('extracting', 'no speaker found for override: ${novelPlan.unmatchedOverrides.join(', ')}', 0.7);
    }
    if (novelPlan != null) {
      await File('$bookDir/character_roster.json').writeAsString(jsonEncode({...novelPlan.toJson(),
        'research': ?researchReport,
        'voice_engine': settings.voiceEngine.name,
        if (settings.voiceEngine == OnDeviceVoiceEngine.kokoroOnnx)
          'assigned_voices': {for (final character in novelPlan.characters)
            character.name: resolveKokoroCharacterVoice(character, narrator: settings.kokoroVoice, male: settings.maleVoice, female: settings.femaleVoice)},
      }));
      final pct = novelPlan.dialogueTotal == 0 ? 0 : (100 * novelPlan.dialogueAttributed / novelPlan.dialogueTotal).round();
      _report('extracting',
          'scanned ${novelPlan.scannedPages} pages; ${novelPlan.characters.length} speakers found; '
          '$pct% of ${novelPlan.dialogueTotal} dialogue lines attributed (the rest are read by the narrator)', 0.75);
    }
    _report('extracting', 'preserving original page visuals', 0.8);
    final pageVisuals = (isNovel || hasEbook) ? <ManifestFigure>[] : await PageVisuals.render(pdfPaths: pdfPaths, bookDir: bookDir, pages: extraction.pages);

    final chunks = settings.allowCloudFallback
        ? chunkPages(extraction.pages, chunkPages: 10)
        : chunkLocalPages(extraction.pages);
    _report('compiling', '0/${chunks.length} chunks', 0.0);

    List<CompiledSection> compiledSections;
    if (isNovel) {
      // A novel is read verbatim. Educational paraphrasing destroys dialogue
      // attribution and is neither required nor safe for narrative fiction.
      compiledSections = [for (final chunk in chunkLocalPages(extraction.pages))
        CompiledSection(title: chunk.pages.single.title ?? 'Page ${chunk.startPage + 1}', sourcePages: [chunk.startPage],
          segments: [CompiledSegment(type: SegmentKind.prose, text: chunk.pages.single.text)])];
      _report('compiling', 'preserved novel text and full-book voice roster', 1.0);
    } else {
    final onDeviceCompiler = OnDeviceCompiler(
      model: findOnDeviceLlmModel(settings.onDeviceLlmModelId),
      gpuLayers: settings.onDeviceGpuLayers,
    );
    try {
    final cloudForAll = settings.allowCloudFallback && settings.cloudForAll;
    // Cloud-for-all never touches the local model, so skip its (large)
    // download and load entirely.
    if (!cloudForAll) {
      await onDeviceCompiler.ensureReady(
        modelsDir: '$modelsDir/llm',
        onProgress: (progress, status) => _report('compiling', status, progress),
      );
    }
    final cloudCompiler = settings.allowCloudFallback ? CloudCompiler(settings) : null;
    final router = CompilationRouter(onDeviceCompiler: onDeviceCompiler, cloudCompiler: cloudCompiler, allowCloudFallback: settings.allowCloudFallback, cloudForAll: cloudForAll);

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

    if (!isNovel && !settings.allowCloudFallback) {
      final fidelity = preserveOrdinaryProse(compiledSections, extraction.pages);
      compiledSections = fidelity.sections;
      await File('$bookDir/conversion_quality.json').writeAsString(jsonEncode({
        'source_wording_preserved_pages': fidelity.sourceFallbackPages,
        'mathematical_rewrites_require_review': true,
      }));
      if (fidelity.sourceFallbackPages.isNotEmpty) {
        _report('compiling', 'preserved original wording on ${fidelity.sourceFallbackPages.length} pages', 1.0);
      }
    }
    _report('synthesizing', '0/${compiledSections.length} sections', 0.0);
    final NarrationEngine tts;
    final String narratorEngineName;
    if (settings.voiceEngine == OnDeviceVoiceEngine.kokoroOnnx) {
      final kokoro = KokoroTtsEngine(voice: settings.kokoroVoice, acceleration: settings.kokoroAcceleration, cpuThreads: settings.kokoroCpuThreads, modelId: settings.ttsModelId, device: DeviceCapabilities(totalRamMb: settings.deviceRamMb, androidSdk: settings.androidSdk), maleVoice: settings.maleVoice, femaleVoice: settings.femaleVoice, novelPlan: novelPlan);
      await kokoro.ensureReady(
        onProgress: (progress, status) => _report('synthesizing', status, progress),
      );
      if (kokoro.modelNote != null) _report('synthesizing', kokoro.modelNote!, 0.0);
      _report('synthesizing', 'Narration running on: ${kokoro.accelerationStatus}', 0.0);
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

    // Publish the book after every finished section so it can be opened and
    // played while the rest is still being narrated. Re-converting a book that
    // is already complete keeps its old manifest until the new one is ready.
    final checkpointFile = File('$bookDir/$_checkpointName');
    final fingerprint = _fingerprint(compiledSections);
    var startIndex = 0;
    try {
      if (await checkpointFile.exists()) {
        final j = jsonDecode(await checkpointFile.readAsString()) as Map<String, dynamic>;
        final done = [for (final m in j['sections'] as List) ManifestSection.fromJson(m as Map<String, dynamic>)];
        var intact = j['fingerprint'] == fingerprint && done.length <= compiledSections.length;
        for (final d in done) {
          if (!intact) break;
          intact = await File('$bookDir/${d.audioPath}').exists() && await File('$bookDir/${d.segmentsPath}').exists();
        }
        if (intact && done.isNotEmpty) {
          manifestSections.addAll(done);
          manifestFormulas.addAll([for (final f in j['formulas'] as List) ManifestFormula.fromJson(f as Map<String, dynamic>)]);
          totalDurationMs = j['total_duration_ms'] as int;
          audioSampleRate = j['sample_rate'] as int?;
          startIndex = done.length;
          _report('synthesizing', 'resuming after section $startIndex of ${compiledSections.length}',
              startIndex / compiledSections.length);
        }
      }
    } catch (_) {
      startIndex = 0; // an unreadable checkpoint just means starting the narration over
      manifestSections.clear();
      manifestFormulas.clear();
      totalDurationMs = 0;
      audioSampleRate = null;
    }
    final manifestFile = File('$bookDir/manifest.json');
    final publishProgress = !await _hasCompleteManifest(manifestFile);
    Future<void> writeManifest({required bool partial}) async {
      final manifest = Manifest(
        bookId: bookId,
        title: title,
        sourcePdf: displayName,
        generatedAt: DateTime.now().toUtc().toIso8601String(),
        totalDurationMs: totalDurationMs,
        sampleRate: audioSampleRate ?? 22050,
        sections: List.of(manifestSections),
        figures: pageVisuals,
        formulas: List.of(manifestFormulas),
        tables: const [],
        narratorEngine: narratorEngineName,
        sourcePdfPath: shippedSourcePdf,
        partial: partial,
        sectionsPlanned: compiledSections.length,
      );
      // Write beside, then rename: a reader never sees a half-written file.
      final staged = File('$bookDir/manifest.json.tmp');
      await staged.writeAsString(jsonEncode(manifest.toJson()), flush: true);
      await staged.rename(manifestFile.path);
    }

    try {
      for (var i = startIndex; i < compiledSections.length; i++) {
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

        await checkpointFile.writeAsString(jsonEncode({
          'fingerprint': fingerprint,
          'sections': [for (final m in manifestSections) m.toJson()],
          'formulas': [for (final f in manifestFormulas) f.toJson()],
          'total_duration_ms': totalDurationMs,
          'sample_rate': audioSampleRate,
        }), flush: true);
        if (publishProgress && i + 1 < compiledSections.length) await writeManifest(partial: true);
        _report('synthesizing', '${i + 1}/${compiledSections.length} sections', (i + 1) / compiledSections.length);
      }
    } finally {
      tts.dispose();
    }

    await writeManifest(partial: false);
    // Finished: nothing left to resume.
    for (final name in [_checkpointName, 'research_cache.json', 'local_research_cache.json']) {
      try {
        await File('$bookDir/$name').delete();
      } catch (_) {}
    }
    try {
      await Directory('$bookDir/ocr').delete(recursive: true); // cached scan text
    } catch (_) {}

    _report('done', '${manifestSections.length} sections, ${manifestFormulas.length} formulas', 1.0);
    return bookId;
  }

  /// True when [file] is a finished book's manifest (not a partial one).
  static Future<bool> _hasCompleteManifest(File file) async {
    try {
      if (!await file.exists()) return false;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['partial'] != true;
    } catch (_) {
      return false;
    }
  }

  static const _checkpointName = 'synthesis_checkpoint.json';

  /// A cheap fingerprint of the text about to be narrated, so a resume only
  /// reuses finished sections when the book it was made from is unchanged.
  static String _fingerprint(List<CompiledSection> sections) {
    var h = 0x811c9dc5;
    void mix(String text) {
      for (final unit in text.codeUnits) {
        h = ((h ^ unit) * 0x01000193) & 0xffffffff;
      }
    }

    for (final section in sections) {
      mix(section.title);
      for (final segment in section.segments) {
        mix(segment.text);
      }
    }
    return '${sections.length}:${h.toRadixString(16)}';
  }
}
