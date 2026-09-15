import Foundation

/// Talks to the Firebrat FastAPI backend: health, the catalog listing, and the
/// one-time bulk download (the reader itself never calls the network again
/// once a book is on-device — offline-first). Mirrors
/// frontend/firebrat_app/lib/services/api_client.dart ( Dio → URLSession ).
///
/// Base URL comes from Settings; the iOS simulator default is
/// http://localhost:8000 (same host as the server, unlike Android's 10.0.2.2).

public enum APIError: LocalizedError, Equatable {
    case badStatus(Int)
    case badURL(String)
    case decodeFailed(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Server returned HTTP \(code)"
        case .badURL(let u): return "Bad URL: \(u)"
        case .decodeFailed(let what): return "Could not decode \(what)"
        case .notFound(let what): return "\(what) not found on server"
        }
    }
}

/// URLSessionDownloadDelegate that forwards byte progress and bridges
/// completion back into async/await via a continuation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Double) -> Void)?
    var continuation: CheckedContinuation<URL, Error>?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move out of the transient location before the session invalidates it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".download")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

public struct APIClient: Sendable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public init(baseURLString: String) throws {
        guard let url = URL(string: baseURLString) else {
            throw APIError.badURL(baseURLString)
        }
        self.baseURL = url
    }

    // MARK: - Health

    /// True when the server is reachable and responding — used to validate a
    /// server URL as soon as the user enters one.
    public func checkHealth() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(
                from: baseURL.appendingPathComponent("health"))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Catalog

    public func listBooks() async throws -> [BookSummary] {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("books"))
        try check(response: response, what: "book list")
        do {
            return try JSONDecoder().decode([BookSummary].self, from: data)
        } catch {
            throw APIError.decodeFailed("book list")
        }
    }

    public func fetchManifest(bookId: String) async throws -> Manifest {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("books/\(bookId)/manifest"))
        try check(response: response, what: "manifest for \(bookId)")
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw APIError.decodeFailed("manifest for \(bookId)")
        }
    }

    /// Permanently deletes a book from the server. Irreversible.
    public func deleteBook(bookId: String) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("books/\(bookId)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response: response, what: "delete \(bookId)")
    }

    // MARK: - Bulk download

    /// Streams the book's zip package (`GET /books/{id}/download`) to
    /// `destination`, reporting 0.0–1.0 progress. This is the only large
    /// transfer the app ever makes per book.
    public func downloadBook(bookId: String, to destination: URL,
                             onProgress: ((Double) -> Void)? = nil) async throws {
        let url = baseURL.appendingPathComponent("books/\(bookId)/download")
        let delegate = DownloadDelegate()
        delegate.onProgress = onProgress
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let tmp: URL = try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
        onProgress?(1.0)
    }

    // MARK: - Helpers

    private func check(response: URLResponse, what: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1)
        }
        switch http.statusCode {
        case 200..<300: return
        case 404: throw APIError.notFound(what)
        default: throw APIError.badStatus(http.statusCode)
        }
    }
}
