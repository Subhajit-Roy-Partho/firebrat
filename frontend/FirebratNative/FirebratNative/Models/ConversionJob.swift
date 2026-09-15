import Foundation

/// One upload's conversion job, as returned by the server's job endpoints
/// (POST /books/upload, GET /jobs, GET /jobs/{id}). Mirrors
/// frontend/firebrat_app/lib/models/job.dart.
///
/// The conversions queue UI itself is deferred (see README) — this model ships
/// now so the queue can be built without touching the schema later.

public enum JobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case done
    case failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobState(rawValue: raw) ?? .queued
    }
}

public struct ConversionJob: Codable, Equatable, Identifiable, Sendable {
    public var jobId: String
    public var bookId: String
    public var filename: String
    public var title: String
    public var state: JobState
    public var stage: String?
    public var detail: String?
    public var progress: Double?
    public var needsReviewCount: Int
    public var error: String?
    public var retryCount: Int
    public var createdAt: String
    public var updatedAt: String

    public var id: String { jobId }
    public var isActive: Bool { state == .queued || state == .running }
    public var isRetryable: Bool { state == .failed || state == .done }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id", bookId = "book_id", filename, title, state
        case stage, detail, progress
        case needsReviewCount = "needs_review_count", error
        case retryCount = "retry_count", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId) ?? ""
        bookId = try c.decodeIfPresent(String.self, forKey: .bookId) ?? ""
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try c.decodeIfPresent(JobState.self, forKey: .state) ?? .queued
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        needsReviewCount = try c.decodeIfPresent(Int.self, forKey: .needsReviewCount) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}
