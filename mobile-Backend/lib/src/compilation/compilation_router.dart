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
  final CloudCompiler cloudCompiler;
  int _formulaCounter = 1;

  CompilationRouter({required this.onDeviceCompiler, required this.cloudCompiler});

  int _nextFormulaNumber() => _formulaCounter++;

  /// Compiles every chunk, calling [onChunkDone] after each one so the
  /// caller can report progress. Returns sections in chunk order — the
  /// pipeline is responsible for section-id/segment-id minting afterward.
  Future<List<CompiledSection>> compileAll(
    List<PageChunk> chunks, {
    void Function(int done, int total, bool usedCloud)? onChunkDone,
  }) async {
    final allSections = <CompiledSection>[];
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final useCloud = needsCloudModel(chunk);
      final output = useCloud
          ? await cloudCompiler.compileChunk(chunk, nextFormulaNumber: _nextFormulaNumber)
          : await onDeviceCompiler.compileChunk(chunk, nextFormulaNumber: _nextFormulaNumber);
      allSections.addAll(output.sections);
      onChunkDone?.call(i + 1, chunks.length, useCloud);
    }
    return allSections;
  }
}
