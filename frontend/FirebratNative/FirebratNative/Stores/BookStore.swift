import Combine
import Foundation

/// On-device book storage under Application Support/books/<book_id>/.
/// Mirrors frontend/firebrat_app/lib/services/download_manager.dart +
/// library_repository.dart + import_manager.dart:
///
/// list-local-from-manifest (offline-first) · download→extract→verify ·
/// document-picker import (.zip or .tar.gz) · delete.

@MainActor
public final class BookStore: ObservableObject {
    @Published public private(set) var localBooks: [BookSummary] = []
    /// In-progress download fraction per book_id (0.0–1.0); absent = idle.
    @Published public private(set) var downloadProgress: [String: Double] = [:]
    /// True while a local-file import is being extracted.
    @Published public private(set) var importInProgress: Bool = false
    /// Best-effort remote catalog; nil until fetched. A failed fetch is
    /// normal (server unreachable) and never surfaces as an error.
    @Published public private(set) var catalog: [BookSummary]?
    @Published public private(set) var catalogUnreachable: Bool = false

    public let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Directories

    public func booksDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func bookDirectory(bookId: String) throws -> URL {
        try booksDirectory().appendingPathComponent(bookId, isDirectory: true)
    }

    public func assetURL(bookId: String, relativePath: String) throws -> URL {
        try bookDirectory(bookId: bookId).appendingPathComponent(relativePath)
    }

    // MARK: - Local library (primary source, works offline)

    /// Every book already usable on-device, built from each manifest.json.
    /// Partially-written packages are skipped, never fatal.
    @discardableResult
    public func refreshLocalBooks() async -> [BookSummary] {
        var result: [BookSummary] = []
        do {
            let books = try booksDirectory()
            let ids = (try? FileManager.default.contentsOfDirectory(
                at: books, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in ids {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let manifestURL = dir.appendingPathComponent("manifest.json")
                guard let manifest = try? Manifest.load(from: manifestURL) else { continue }
                let size = directorySize(dir)
                result.append(.fromLocalManifest(manifest, sizeBytes: size))
            }
        } catch {
            // No storage at all yet — empty library, not an error.
        }
        result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        localBooks = result
        return result
    }

    public func loadManifest(bookId: String) throws -> Manifest {
        try Manifest.load(from: bookDirectory(bookId: bookId)
            .appendingPathComponent("manifest.json"))
    }

    public func loadSegments(bookId: String, section: ManifestSection) throws -> SegmentsFile {
        try SegmentsFile.load(from: assetURL(bookId: bookId, relativePath: section.segmentsPath))
    }

    public func isDownloaded(bookId: String) -> Bool {
        (try? bookDirectory(bookId: bookId)
            .appendingPathComponent("manifest.json")).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    // MARK: - Remote catalog (best-effort)

    public func refreshCatalog() async {
        do {
            let books = try await settings.apiClient().listBooks()
            catalog = books
            catalogUnreachable = false
        } catch {
            catalogUnreachable = true
        }
    }

    // MARK: - Download → extract → verify

    public func download(bookId: String) async throws {
        downloadProgress[bookId] = 0
        defer { downloadProgress.removeValue(forKey: bookId) }
        let client = try settings.apiClient()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bookId).zip")
        try await client.downloadBook(bookId: bookId, to: tmp) { [weak self] p in
            Task { @MainActor in self?.downloadProgress[bookId] = p }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ArchiveReader.extract(file: tmp, to: bookDirectory(bookId: bookId))
        await refreshLocalBooks()
    }

    // MARK: - Document-picker import (.zip or .tar.gz)

    public func importPackage(at fileURL: URL) async throws {
        importInProgress = true
        defer { importInProgress = false }
        let needsStop = fileURL.startAccessingSecurityScopedResource()
        defer { if needsStop { fileURL.stopAccessingSecurityScopedResource() } }

        // Extract to a staging dir first, read the manifest for the real id,
        // then move into place — so a weird filename never becomes the book id.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try ArchiveReader.extract(file: fileURL, to: staging)
        let manifest = try Manifest.load(from: staging.appendingPathComponent("manifest.json"))
        let dest = try bookDirectory(bookId: manifest.bookId)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: staging, to: dest)
        await refreshLocalBooks()
    }

    // MARK: - Delete

    public func deleteLocal(bookId: String) async {
        if let dir = try? bookDirectory(bookId: bookId) {
            try? FileManager.default.removeItem(at: dir)
        }
        await refreshLocalBooks()
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> Int {
        var total = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }
}
