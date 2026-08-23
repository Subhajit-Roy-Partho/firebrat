/// `manifest.json` shape, mirroring `docs/DATA_SCHEMA.md` exactly so a
/// book produced on-device is byte-for-byte structurally compatible with
/// one produced by the server pipeline — the reader app's models
/// (`frontend/firebrat_app/lib/models/manifest.dart`) don't need to know
/// or care which pipeline produced the book they're reading.
library;

class ManifestFormula {
  final String formulaId;
  final String latex;
  final String imagePath; // kept for schema fidelity; unused when no server-side renderer exists on-device
  final String spokenText;
  final bool visuallyEssential;
  final int page;

  const ManifestFormula({
    required this.formulaId,
    required this.latex,
    required this.imagePath,
    required this.spokenText,
    required this.visuallyEssential,
    required this.page,
  });

  Map<String, dynamic> toJson() => {
        'formula_id': formulaId,
        'latex': latex,
        'image_path': imagePath,
        'spoken_text': spokenText,
        'visually_essential': visuallyEssential,
        'page': page,
      };
}

class ManifestFigure {
  final String figureId;
  final String caption;
  final String imagePath;
  final int page;

  const ManifestFigure({required this.figureId, required this.caption, required this.imagePath, required this.page});

  Map<String, dynamic> toJson() => {
        'figure_id': figureId,
        'caption': caption,
        'image_path': imagePath,
        'page': page,
      };
}

class ManifestTable {
  final String tableId;
  final String caption;
  final String imagePath;
  final int page;

  const ManifestTable({required this.tableId, required this.caption, required this.imagePath, required this.page});

  Map<String, dynamic> toJson() => {
        'table_id': tableId,
        'caption': caption,
        'image_path': imagePath,
        'page': page,
      };
}

class ManifestSection {
  final String sectionId;
  final int order;
  final String title;
  final String audioPath;
  final String segmentsPath;
  final int durationMs;
  final List<String> figureRefs;
  final List<String> formulaRefs;
  final List<String> tableRefs;
  final bool needsReview;

  const ManifestSection({
    required this.sectionId,
    required this.order,
    required this.title,
    required this.audioPath,
    required this.segmentsPath,
    required this.durationMs,
    required this.figureRefs,
    required this.formulaRefs,
    required this.tableRefs,
    this.needsReview = false,
  });

  Map<String, dynamic> toJson() => {
        'section_id': sectionId,
        'chapter': null,
        'order': order,
        'title': title,
        'audio_path': audioPath,
        'segments_path': segmentsPath,
        'duration_ms': durationMs,
        'figure_refs': figureRefs,
        'formula_refs': formulaRefs,
        'table_refs': tableRefs,
        'needs_review': needsReview,
      };
}

class Manifest {
  final String bookId;
  final String title;
  final String sourcePdf;
  final String generatedAt;
  final int totalDurationMs;
  final List<ManifestSection> sections;
  final List<ManifestFigure> figures;
  final List<ManifestFormula> formulas;
  final List<ManifestTable> tables;
  final String narratorEngine; // "on_device_tts" for this pipeline's narration, distinguishing it from "chatterbox-tts"

  const Manifest({
    required this.bookId,
    required this.title,
    required this.sourcePdf,
    required this.generatedAt,
    required this.totalDurationMs,
    required this.sections,
    required this.figures,
    required this.formulas,
    required this.tables,
    required this.narratorEngine,
  });

  Map<String, dynamic> toJson() => {
        'schema_version': '1.0',
        'book_id': bookId,
        'title': title,
        'author': '',
        'source_pdf': sourcePdf,
        'generated_at': generatedAt,
        'pipeline_version': 'mobile-0.1.0',
        'narrator_voice': {
          'engine': narratorEngine,
          'model_class': 'DeviceTts',
          'sample_rate': 22050,
        },
        'audio_format': {
          'codec': 'pcm_s16le',
          'container': 'wav',
          'sample_rate': 22050,
          'channels': 1,
          'fallback_codec': null,
        },
        'total_duration_ms': totalDurationMs,
        'sections': sections.map((s) => s.toJson()).toList(),
        'figures': figures.map((f) => f.toJson()).toList(),
        'formulas': formulas.map((f) => f.toJson()).toList(),
        'tables': tables.map((t) => t.toJson()).toList(),
      };
}
