import 'dart:convert';
import 'dart:io';
import '../util/ids.dart';
import 'prompt.dart';
import '../models/compiled_models.dart';
import '../models/raw_page.dart';
import 'cloud_compiler.dart';
import 'on_device_compiler.dart';
import 'routing.dart';

/// Chunk-by-chunk router: easy chunks go to the on-device model, chunks
/// the heuristic flags as needing more capability go to the user-configured
/// cloud LLM — see `mobile-Backend/PROPOSAL.md` §5 for why this split
/// exists (on-device math authoring is the pipeline's highest-risk part).
class CompilationRouter {
  final OnDeviceCompiler onDeviceCompiler;
  final CloudCompiler? cloudCompiler;
  final bool allowCloudFallback;
  /// Route every chunk to the cloud LLM, not just the hard ones.
  final bool cloudForAll;
  int _formulaCounter = 1;

  CompilationRouter({required this.onDeviceCompiler, this.cloudCompiler, this.allowCloudFallback = false, this.cloudForAll = false});

  int _nextFormulaNumber() => _formulaCounter++;

  /// Compiles every chunk, calling [onChunkDone] after each one so the
  /// caller can report progress. Returns sections in chunk order — the
  /// pipeline is responsible for section-id/segment-id minting afterward.
  Future<List<CompiledSection>> compileAll(
    List<PageChunk> chunks, {
    void Function(int done, int total, bool usedCloud)? onChunkDone,
    String? checkpointDir,
    String? checkpointModelKey,
  }) async {
    _formulaCounter = 1;
    final allSections = <CompiledSection>[];
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final useCloud = allowCloudFallback && (cloudForAll || needsCloudModel(chunk));
      if (useCloud && cloudCompiler == null) {
        throw StateError('Cloud helper is enabled but not configured');
      }
      final settings = cloudCompiler?.settings;
      final endpoint = Uri.tryParse(settings?.llmBaseUrl ?? '');
      final key = jsonEncode({
        'version': 2,
        'local_generation': {'context': 4096, 'batch': 1536, 'microbatch': 128,
          'threads': 4, 'temperature': 0.2, 'seed': 42, 'max_tokens': 2400,
          'format': onDeviceCompiler.model.promptFormat.name},
        'prompt': buildSystemPrompt(),
        'model': checkpointModelKey ?? onDeviceCompiler.model.id,
        'gpu_layers': onDeviceCompiler.gpuLayers,
        'allow_cloud': allowCloudFallback,
        'cloud_for_all': cloudForAll,
        'uses_cloud': useCloud,
        // Omit credentials and URL query parameters from persisted metadata.
        'cloud_endpoint': endpoint == null ? '' :
          '${endpoint.scheme}://${endpoint.host}:${endpoint.port}${endpoint.path}',
        'cloud_model': settings?.llmModel ?? '',
        'chunk': chunk.chunkIdx,
        'pages': chunk.pages.map((p) => {'index': p.pageIdx, 'text': p.text}).toList(),
      });
      final checkpoint = checkpointDir == null ? null :
          File('$checkpointDir/chunk_${chunk.chunkIdx}.json');
      var output = await _readCheckpoint(checkpoint, key);
      if (output == null) {
        // The compiler's ids are temporary: remint once, in encounter order,
        // below for both fresh and cached outputs so resume cannot collide.
        var localFormulaNumber = 1;
        output = useCloud
            ? await cloudCompiler!.compileChunk(chunk,
                nextFormulaNumber: () => localFormulaNumber++)
            : await onDeviceCompiler.compileChunk(chunk,
                nextFormulaNumber: () => localFormulaNumber++);
        if (output.sections.isEmpty || output.sections.every((s) => s.segments.isEmpty)) {
          throw StateError('Compilation returned no narration for chunk ${chunk.chunkIdx}');
        }
        await _writeCheckpoint(checkpoint, key, output);
      }
      final sourcePages = chunk.pages.map((p) => p.pageIdx).toSet();
      if (output.sections.isEmpty || output.sections.every((s) => s.segments.isEmpty)) {
        throw StateError('Local compilation returned no narration for chunk ${chunk.chunkIdx}');
      }
      for (final section in output.sections) {
        final validPages = section.sourcePages.where(sourcePages.contains).toList();
        allSections.add(CompiledSection(title: section.title,
          sourcePages: validPages.isEmpty ? sourcePages.toList() : validPages,
          segments: section.segments.map((segment) =>
            segment.type == SegmentKind.formulaCallout &&
                segment.latex != null && segment.latex!.trim().isNotEmpty
              ? segment.copyWith(ref: makeFormulaId(_nextFormulaNumber()))
              : segment).toList()));
      }
      onChunkDone?.call(i + 1, chunks.length, useCloud);
    }
    return allSections;
  }

  Future<CompiledChunkOutput?> _readCheckpoint(File? file, String key) async {
    if (file == null || !await file.exists()) return null;
    try {
      final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (saved['key'] != key) return null;
      final output = CompiledChunkOutput.fromJson(saved['output'] as Map<String, dynamic>);
      if (output.sections.isEmpty || output.sections.any((s) => s.segments.isEmpty ||
          s.segments.any((segment) => segment.text.trim().isEmpty))) {
        return null;
      }
      return output;
    } catch (_) {
      // Interrupted writes or obsolete/corrupt data are cache misses.
      return null;
    }
  }

  Future<void> _writeCheckpoint(File? file, String key, CompiledChunkOutput output) async {
    if (file == null) return;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode({
      'key': key,
      'output': {'sections': output.sections.map((section) => {
        'title': section.title, 'source_pages': section.sourcePages,
        'segments': section.segments.map((segment) => {
          'type': segmentKindToString(segment.type), 'text': segment.text,
          'ref': segment.ref, 'latex': segment.latex,
          'visually_essential': segment.visuallyEssential,
        }).toList(),
      }).toList()},
    }), flush: true);
    await temporary.rename(file.path);
  }

}
