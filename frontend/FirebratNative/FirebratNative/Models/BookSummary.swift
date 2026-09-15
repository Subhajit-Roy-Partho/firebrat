import Foundation

/// Lightweight catalog entry returned by GET /books — used for the library
/// before a book's full manifest is downloaded. Also built locally from each
/// on-device manifest.json (offline-first). Mirrors
/// frontend/firebrat_app/lib/models/book.dart.

public struct BookSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bookId: String
    public var title: String
    public var author: String
    public var totalDurationMs: Int
    public var sectionCount: Int
    public var sizeBytes: Int
    public var updatedAt: String

    public var id: String { bookId }

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id", title, author
        case totalDurationMs = "total_duration_ms"
        case sectionCount = "section_count"
        case sizeBytes = "size_bytes"
        case updatedAt = "updated_at"
    }

    public init(bookId: String, title: String, author: String = "",
                totalDurationMs: Int = 0, sectionCount: Int = 0,
                sizeBytes: Int = 0, updatedAt: String = "") {
        self.bookId = bookId
        self.title = title
        self.author = author
        self.totalDurationMs = totalDurationMs
        self.sectionCount = sectionCount
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try c.decodeIfPresent(String.self, forKey: .bookId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        totalDurationMs = try c.decodeIfPresent(Int.self, forKey: .totalDurationMs) ?? 0
        sectionCount = try c.decodeIfPresent(Int.self, forKey: .sectionCount) ?? 0
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    /// Built from an on-device manifest + measured directory size, so the
    /// library works with zero server ever reachable.
    public static func fromLocalManifest(_ manifest: Manifest, sizeBytes: Int) -> BookSummary {
        BookSummary(
            bookId: manifest.bookId,
            title: manifest.title,
            author: manifest.author,
            totalDurationMs: manifest.totalDurationMs,
            sectionCount: manifest.sections.count,
            sizeBytes: sizeBytes,
            updatedAt: manifest.generatedAt
        )
    }
}
