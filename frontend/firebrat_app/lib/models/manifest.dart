class ManifestFigure {
  final String figureId;
  final String caption;
  final String imagePath;
  final int page;
  final int? width;
  final int? height;

  const ManifestFigure({
    required this.figureId,
    required this.caption,
    required this.imagePath,
    required this.page,
    this.width,
    this.height,
  });

  factory ManifestFigure.fromJson(Map<String, dynamic> json) => ManifestFigure(
        figureId: json['figure_id'] as String,
        caption: json['caption'] as String? ?? '',
        imagePath: json['image_path'] as String,
        page: json['page'] as int? ?? 0,
        width: json['width'] as int?,
        height: json['height'] as int?,
      );
}

class ManifestFormula {
  final String formulaId;
  final String latex;
  final String imagePath;
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

  factory ManifestFormula.fromJson(Map<String, dynamic> json) => ManifestFormula(
        formulaId: json['formula_id'] as String,
        latex: json['latex'] as String? ?? '',
        imagePath: json['image_path'] as String,
        spokenText: json['spoken_text'] as String? ?? '',
        visuallyEssential: json['visually_essential'] as bool? ?? false,
        page: json['page'] as int? ?? 0,
      );
}

class ManifestTable {
  final String tableId;
  final String caption;
  final String imagePath;
  final int page;

  const ManifestTable({
    required this.tableId,
    required this.caption,
    required this.imagePath,
    required this.page,
  });

  factory ManifestTable.fromJson(Map<String, dynamic> json) => ManifestTable(
        tableId: json['table_id'] as String,
        caption: json['caption'] as String? ?? '',
        imagePath: json['image_path'] as String,
        page: json['page'] as int? ?? 0,
      );
}

class ManifestSection {
  final String sectionId;
  final int? chapter;
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
    this.chapter,
    required this.order,
    required this.title,
    required this.audioPath,
    required this.segmentsPath,
    required this.durationMs,
    required this.figureRefs,
    required this.formulaRefs,
    required this.tableRefs,
    required this.needsReview,
  });

  factory ManifestSection.fromJson(Map<String, dynamic> json) => ManifestSection(
        sectionId: json['section_id'] as String,
        chapter: json['chapter'] as int?,
        order: json['order'] as int,
        title: json['title'] as String,
        audioPath: json['audio_path'] as String,
        segmentsPath: json['segments_path'] as String,
        durationMs: json['duration_ms'] as int? ?? 0,
        figureRefs: (json['figure_refs'] as List? ?? []).cast<String>(),
        formulaRefs: (json['formula_refs'] as List? ?? []).cast<String>(),
        tableRefs: (json['table_refs'] as List? ?? []).cast<String>(),
        needsReview: json['needs_review'] as bool? ?? false,
      );
}

class Manifest {
  final String bookId;
  final String title;
  final String author;
  final String sourcePdf;
  final String generatedAt;
  final int totalDurationMs;
  final List<ManifestSection> sections;
  final List<ManifestFigure> figures;
  final List<ManifestFormula> formulas;
  final List<ManifestTable> tables;

  const Manifest({
    required this.bookId,
    required this.title,
    required this.author,
    required this.sourcePdf,
    required this.generatedAt,
    required this.totalDurationMs,
    required this.sections,
    required this.figures,
    required this.formulas,
    required this.tables,
  });

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
        bookId: json['book_id'] as String,
        title: json['title'] as String,
        author: json['author'] as String? ?? '',
        sourcePdf: json['source_pdf'] as String? ?? '',
        generatedAt: json['generated_at'] as String? ?? '',
        totalDurationMs: json['total_duration_ms'] as int? ?? 0,
        sections: (json['sections'] as List? ?? [])
            .map((e) => ManifestSection.fromJson(e as Map<String, dynamic>))
            .toList(),
        figures: (json['figures'] as List? ?? [])
            .map((e) => ManifestFigure.fromJson(e as Map<String, dynamic>))
            .toList(),
        formulas: (json['formulas'] as List? ?? [])
            .map((e) => ManifestFormula.fromJson(e as Map<String, dynamic>))
            .toList(),
        tables: (json['tables'] as List? ?? [])
            .map((e) => ManifestTable.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  ManifestFigure? figureById(String id) {
    for (final f in figures) {
      if (f.figureId == id) return f;
    }
    return null;
  }

  ManifestFormula? formulaById(String id) {
    for (final f in formulas) {
      if (f.formulaId == id) return f;
    }
    return null;
  }

  ManifestTable? tableById(String id) {
    for (final t in tables) {
      if (t.tableId == id) return t;
    }
    return null;
  }
}
