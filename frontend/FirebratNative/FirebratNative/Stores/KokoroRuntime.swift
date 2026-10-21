import Foundation
import CryptoKit
import SherpaOnnx

/// Pinned official Sherpa/Kokoro assets. Downloads once, verifies SHA-256,
/// extracts with bounded buffers, then works without network access.
actor KokoroRuntime {
    static let female = ["Default", "Bella", "Nicole", "Sarah"]
    static let male = ["Adam", "Michael"]
    static let ids = ["Default": 0, "Bella": 1, "Nicole": 2, "Sarah": 3, "Adam": 5, "Michael": 6]
    static let archiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-en-v0_19.tar.bz2")!
    static let checksum = "c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd"
    private let engine: SherpaOnnxOfflineTtsWrapper
    init(directory: URL) throws {
        let fm = FileManager.default
        let model = ["model.int8.onnx", "model.onnx"].map { directory.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        guard let model else { throw CocoaError(.fileNoSuchFile) }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(model: model.path, voices: directory.appendingPathComponent("voices.bin").path, tokens: directory.appendingPathComponent("tokens.txt").path, dataDir: directory.appendingPathComponent("espeak-ng-data").path)
        let config = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2, debug: 0, provider: "cpu")
        var options = sherpaOnnxOfflineTtsConfig(model: config)
        engine = SherpaOnnxOfflineTtsWrapper(config: &options)
        guard engine.tts != nil, engine.sampleRate == 24000, engine.numSpeakers >= 7 else {
            throw NSError(domain: "FirebratKokoro", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kokoro model could not be loaded."])
        }
    }
    static func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws -> KokoroRuntime {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("models")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent("kokoro-int8-en-v0_19")
        let marker = dest.appendingPathComponent(".ready")
        if (try? String(contentsOf: marker, encoding: .utf8)) != checksum {
            let file = try await AssetDownload.fetch(archiveURL, progress: progress)
            defer { try? fm.removeItem(at: file) }
            let stage = root.appendingPathComponent("kokoro-download-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            try await Task.detached(priority: .userInitiated) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 131072), !data.isEmpty { hash.update(data: data) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else { throw ArchiveError.corrupt("Kokoro download checksum mismatch") }
                try BzipArchive.extract(file, to: stage)
            }.value
            let candidates = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
            guard let unpacked = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("voices.bin").path) }) else { throw ArchiveError.corrupt("Kokoro model files missing") }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: unpacked, to: dest)
            try checksum.write(to: marker, atomically: true, encoding: .utf8)
        }
        return try await Task.detached(priority: .userInitiated) { try KokoroRuntime(directory: dest) }.value
    }
    func synthesize(_ text: String, preset: String, to url: URL) throws {
        try Task.checkCancellation()
        guard let sid = Self.ids[preset] else { throw ArchiveError.corrupt("Unknown Kokoro voice preset") }
        let audio = engine.generate(text: text, sid: sid, speed: 1)
        guard audio.audio != nil, audio.n > 0, audio.samples.contains(where: { $0.isFinite && abs($0) > 0.001 }), audio.save(filename: url.path) == 1 else {
            throw NSError(domain: "FirebratKokoro", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kokoro did not produce narration. No stock voice was substituted."])
        }
    }
}

/// Native libbz2 is present in Apple's SDK; no shell or external executable.
enum BzipArchive {
    static func extract(_ source: URL, to target: URL) throws {
        let fm = FileManager.default, tar = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar")
        defer { try? fm.removeItem(at: tar) }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        fm.createFile(atPath: tar.path, contents: nil)
        let output = try FileHandle(forWritingTo: tar); defer { try? output.close() }
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw ArchiveError.corrupt("Bzip initialization failed") }
        defer { BZ2_bzDecompressEnd(&stream) }
        var status = BZ_OK, buffer = [UInt8](repeating: 0, count: 131072), written = 0
        while status != BZ_STREAM_END {
            guard let chunk = try input.read(upToCount: 131072), !chunk.isEmpty else { throw ArchiveError.corrupt("Truncated Kokoro archive") }
            try chunk.withUnsafeBytes { bytes in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: CChar.self).baseAddress!); stream.avail_in = UInt32(chunk.count)
                repeat {
                    try buffer.withUnsafeMutableBytes { bytes in
                        stream.next_out = bytes.bindMemory(to: CChar.self).baseAddress!; stream.avail_out = UInt32(bytes.count)
                        status = BZ2_bzDecompress(&stream)
                        guard status == BZ_OK || status == BZ_STREAM_END else { throw ArchiveError.corrupt("Kokoro archive checksum failure") }
                        let count = bytes.count - Int(stream.avail_out); written += count
                        guard written < 1024 * 1024 * 1024 else { throw ArchiveError.corrupt("Kokoro archive exceeds expected size") }
                        if count > 0 { try output.write(contentsOf: Data(bytes: bytes.baseAddress!, count: count)) }
                    }
                } while status != BZ_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
            }
        }
        try output.synchronize()
        try StreamingArchive.extractTarFile(tar, to: target)
    }
}
