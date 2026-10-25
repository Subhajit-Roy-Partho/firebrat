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

  factory ManifestFormula.fromJson(Map<String, dynamic> j) => ManifestFormula(
        formulaId: j['formula_id'] as String,
        latex: j['latex'] as String? ?? '',
        imagePath: j['image_path'] as String? ?? '',
        spokenText: j['spoken_text'] as String? ?? '',
        visuallyEssential: j['visually_essential'] as bool? ?? false,
        page: j['page'] as int? ?? 0,
      );

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
  final List<int> sourcePages; // 0-based PDF page indices, from compilation

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
    this.sourcePages = const [],
  });

  factory ManifestSection.fromJson(Map<String, dynamic> j) => ManifestSection(
        sectionId: j['section_id'] as String,
        order: j['order'] as int,
        title: j['title'] as String? ?? '',
        audioPath: j['audio_path'] as String,
        segmentsPath: j['segments_path'] as String,
        durationMs: j['duration_ms'] as int? ?? 0,
        figureRefs: (j['figure_refs'] as List? ?? const []).cast<String>(),
        formulaRefs: (j['formula_refs'] as List? ?? const []).cast<String>(),
        tableRefs: (j['table_refs'] as List? ?? const []).cast<String>(),
        needsReview: j['needs_review'] as bool? ?? false,
        sourcePages: (j['source_pages'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
      );

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
        'source_pages': sourcePages,
      };
}

class Manifest {
  final String bookId;
  final String title;
  final String sourcePdf;
  final String generatedAt;
  final int totalDurationMs;
  final int sampleRate;
  final List<ManifestSection> sections;
  final List<ManifestFigure> figures;
  final List<ManifestFormula> formulas;
  final List<ManifestTable> tables;
  final String narratorEngine; // "on_device_tts" for this pipeline's narration, distinguishing it from "chatterbox-tts"
  final String? sourcePdfPath; // relative path of the shipped source PDF (e.g. "source.pdf"), null for old packages
  /// True while the book is still being narrated: [sections] holds only the
  /// sections finished so far, out of [sectionsPlanned]. Absent (false) in a
  /// finished book, so complete packages keep their original shape.
  final bool partial;
  final int? sectionsPlanned;

  const Manifest({
    required this.bookId,
    required this.title,
    required this.sourcePdf,
    required this.generatedAt,
    required this.totalDurationMs,
    this.sampleRate = 22050,
    required this.sections,
    required this.figures,
    required this.formulas,
    required this.tables,
    required this.narratorEngine,
    this.sourcePdfPath,
    this.partial = false,
    this.sectionsPlanned,
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
          'model_class': narratorEngine == 'kokoro_onnx' ? 'Kokoro82M' : 'DeviceTts',
          'sample_rate': sampleRate,
        },
        'audio_format': {
          'codec': 'pcm_s16le',
          'container': 'wav',
          'sample_rate': sampleRate,
          'channels': 1,
          'fallback_codec': null,
        },
        'total_duration_ms': totalDurationMs,
        'source_pdf_path': sourcePdfPath,
        'sections': sections.map((s) => s.toJson()).toList(),
        'figures': figures.map((f) => f.toJson()).toList(),
        'formulas': formulas.map((f) => f.toJson()).toList(),
        'tables': tables.map((t) => t.toJson()).toList(),
        if (partial) 'partial': true,
        if (partial && sectionsPlanned != null) 'sections_planned': sectionsPlanned,
      };
}
