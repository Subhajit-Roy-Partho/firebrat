import Foundation

/// Mirror of backend/firebrat/pipeline/schema.py manifest models, with the same
/// tolerant defaults as frontend/firebrat_app/lib/models/manifest.dart:
/// missing optional fields fall back to "" / 0 / [] instead of failing the
/// whole manifest decode.

// MARK: - Assets

public struct ManifestFigure: Codable, Equatable, Sendable {
    public var figureId: String
    public var caption: String
    public var imagePath: String
    public var page: Int
    public var width: Int?
    public var height: Int?

    enum CodingKeys: String, CodingKey {
        case figureId = "figure_id", caption, imagePath = "image_path"
        case page, width, height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        figureId = try c.decodeIfPresent(String.self, forKey: .figureId) ?? ""
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
    }
}

public struct ManifestFormula: Codable, Equatable, Sendable {
    public var formulaId: String
    public var latex: String
    public var imagePath: String
    public var spokenText: String
    public var visuallyEssential: Bool
    public var page: Int

    enum CodingKeys: String, CodingKey {
        case formulaId = "formula_id", latex, imagePath = "image_path"
        case spokenText = "spoken_text", visuallyEssential = "visually_essential", page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formulaId = try c.decodeIfPresent(String.self, forKey: .formulaId) ?? ""
        latex = try c.decodeIfPresent(String.self, forKey: .latex) ?? ""
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        spokenText = try c.decodeIfPresent(String.self, forKey: .spokenText) ?? ""
        visuallyEssential = try c.decodeIfPresent(Bool.self, forKey: .visuallyEssential) ?? false
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
    }
}

public struct ManifestTable: Codable, Equatable, Sendable {
    public var tableId: String
    public var caption: String
    public var imagePath: String
    public var page: Int

    enum CodingKeys: String, CodingKey {
        case tableId = "table_id", caption, imagePath = "image_path", page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tableId = try c.decodeIfPresent(String.self, forKey: .tableId) ?? ""
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
    }
}

// MARK: - Sections

public struct ManifestSection: Codable, Equatable, Sendable {
    public var sectionId: String
    public var chapter: Int?
    public var order: Int
    public var title: String
    public var audioPath: String
    public var segmentsPath: String
    public var durationMs: Int
    public var figureRefs: [String]
    public var formulaRefs: [String]
    public var tableRefs: [String]
    public var needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case sectionId = "section_id", chapter, order, title
        case audioPath = "audio_path", segmentsPath = "segments_path"
        case durationMs = "duration_ms"
        case figureRefs = "figure_refs", formulaRefs = "formula_refs", tableRefs = "table_refs"
        case needsReview = "needs_review"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sectionId = try c.decodeIfPresent(String.self, forKey: .sectionId) ?? ""
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath) ?? ""
        segmentsPath = try c.decodeIfPresent(String.self, forKey: .segmentsPath) ?? ""
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        figureRefs = try c.decodeIfPresent([String].self, forKey: .figureRefs) ?? []
        formulaRefs = try c.decodeIfPresent([String].self, forKey: .formulaRefs) ?? []
        tableRefs = try c.decodeIfPresent([String].self, forKey: .tableRefs) ?? []
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
    }
}

// MARK: - Manifest

public struct Manifest: Codable, Equatable, Sendable {
    public var bookId: String
    public var title: String
    public var author: String
    public var sourcePdf: String
    public var generatedAt: String
    public var totalDurationMs: Int
    public var sections: [ManifestSection]
    public var figures: [ManifestFigure]
    public var formulas: [ManifestFormula]
    public var tables: [ManifestTable]

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id", title, author, sourcePdf = "source_pdf"
        case generatedAt = "generated_at", totalDurationMs = "total_duration_ms"
        case sections, figures, formulas, tables
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try c.decodeIfPresent(String.self, forKey: .bookId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        sourcePdf = try c.decodeIfPresent(String.self, forKey: .sourcePdf) ?? ""
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        totalDurationMs = try c.decodeIfPresent(Int.self, forKey: .totalDurationMs) ?? 0
        sections = try c.decodeIfPresent([ManifestSection].self, forKey: .sections) ?? []
        figures = try c.decodeIfPresent([ManifestFigure].self, forKey: .figures) ?? []
        formulas = try c.decodeIfPresent([ManifestFormula].self, forKey: .formulas) ?? []
        tables = try c.decodeIfPresent([ManifestTable].self, forKey: .tables) ?? []
    }

    public static func load(from url: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    public func figure(id: String) -> ManifestFigure? {
        figures.first { $0.figureId == id }
    }

    public func formula(id: String) -> ManifestFormula? {
        formulas.first { $0.formulaId == id }
    }

    public func table(id: String) -> ManifestTable? {
        tables.first { $0.tableId == id }
    }
}
