import Foundation

/// One narration segment within a section: a single sentence/utterance, timed
/// against the section's combined audio track. Mirrors
/// frontend/firebrat_app/lib/models/segment.dart (including the binary search).

public enum SegmentType: String, Codable, Equatable, Sendable {
    case heading
    case prose
    case figureCallout = "figure_callout"
    case formulaCallout = "formula_callout"
    case tableCallout = "table_callout"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SegmentType(rawValue: raw) ?? .prose
    }

    /// True for segments that reference an on-screen visual.
    public var isVisual: Bool {
        switch self {
        case .figureCallout, .formulaCallout, .tableCallout: return true
        case .heading, .prose: return false
        }
    }

    /// SF Symbol used for the segment row icon in the reader.
    public var symbolName: String {
        switch self {
        case .heading: return "textformat.size"
        case .prose: return "text.alignleft"
        case .figureCallout: return "photo"
        case .formulaCallout: return "function"
        case .tableCallout: return "tablecells"
        }
    }
}

public struct Segment: Codable, Equatable, Identifiable, Sendable {
    public var segmentId: String
    public var index: Int
    public var type: SegmentType
    public var text: String
    public var ref: String?
    public var startMs: Int
    public var endMs: Int
    public var visuallyEssential: Bool

    public var id: String { segmentId }

    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id", index, type, text, ref
        case startMs = "start_ms", endMs = "end_ms"
        case visuallyEssential = "visually_essential"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentId = try c.decodeIfPresent(String.self, forKey: .segmentId) ?? ""
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        type = try c.decodeIfPresent(SegmentType.self, forKey: .type) ?? .prose
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        startMs = try c.decodeIfPresent(Int.self, forKey: .startMs) ?? 0
        endMs = try c.decodeIfPresent(Int.self, forKey: .endMs) ?? 0
        visuallyEssential = try c.decodeIfPresent(Bool.self, forKey: .visuallyEssential) ?? false
    }

    public func contains(ms: Int) -> Bool {
        ms >= startMs && ms < endMs
    }
}

public struct SegmentsFile: Codable, Equatable, Sendable {
    public var sectionId: String
    public var sampleRate: Int
    public var pauseMsBetweenSegments: Int
    public var segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case sectionId = "section_id", sampleRate = "sample_rate"
        case pauseMsBetweenSegments = "pause_ms_between_segments", segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sectionId = try c.decodeIfPresent(String.self, forKey: .sectionId) ?? ""
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 24000
        pauseMsBetweenSegments = try c.decodeIfPresent(Int.self, forKey: .pauseMsBetweenSegments) ?? 220
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }

    public static func load(from url: URL) throws -> SegmentsFile {
        try JSONDecoder().decode(SegmentsFile.self, from: Data(contentsOf: url))
    }

    /// Binary search for the segment active at `ms`, or nil when before/after
    /// all segments. Same semantics as the Flutter `activeAt`.
    public func activeAt(ms: Int) -> Segment? {
        guard !segments.isEmpty else { return nil }
        var lo = 0
        var hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if ms < s.startMs {
                hi = mid - 1
            } else if ms >= s.endMs {
                lo = mid + 1
            } else {
                return s
            }
        }
        return nil
    }

    /// The first figure/table/formula ref in reading order — shown as soon as
    /// a section loads, before playback reaches its callout.
    public func firstVisualRef() -> String? {
        segments.first { $0.ref != nil && $0.type.isVisual }?.ref
    }
}
