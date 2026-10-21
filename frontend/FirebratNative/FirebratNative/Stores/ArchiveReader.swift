import Foundation
import zlib

/// Archive extraction without third-party dependencies.
///
/// - `.zip` (what `GET /books/{id}/download` serves): parsed directly —
///   end-of-central-directory → central directory → per-entry stored/deflate
///   payloads inflated via the Compression framework. This plays the role
///   ZIPFoundation would play; swapping in ZIPFoundation via SPM later is a
///   drop-in change behind `ArchiveReader.extract`.
/// - `.tar.gz` (document-picker import of pipeline archives): gzip container
///   stripped by hand (10-byte header + raw deflate + 8-byte trailer) and the
///   same inflate path reused, then a minimal TAR reader (512-byte headers,
///   octal sizes, `./` prefixes, GNU longnames, PAX-header skips).
///
/// Path traversal is rejected: absolute paths and `..` components are skipped.

public enum ArchiveError: LocalizedError, Equatable {
    case unknownFormat(String)
    case corrupt(String)
    case missingManifest
    case traversalBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let n): return "Unsupported archive: \(n) (expected .zip or .tar.gz)"
        case .corrupt(let why): return "Archive is corrupt: \(why)"
        case .missingManifest: return "Package is missing manifest.json"
        case .traversalBlocked(let p): return "Blocked unsafe path in archive: \(p)"
        }
    }
}

public enum ArchiveReader {
    /// Extract `file` into `target` (replacing anything there) and verify the
    /// result contains `manifest.json` — so download and import produce
    /// identically-laid-out book directories.
    public static func extract(file: URL, to target: URL) throws {
        let name = file.lastPathComponent.lowercased()
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        if name.hasSuffix(".zip") {
            try ZipReader.extract(file: file, to: target)
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            try StreamingArchive.extractGzip(file, to: target)
        } else {
            // Sniff content when the extension lies (picked files often do).
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4) ?? Data()
            if data.starts(with: [0x50, 0x4B]) {
                try ZipReader.extract(file: file, to: target)
            } else if data.starts(with: [0x1F, 0x8B]) {
                try StreamingArchive.extractGzip(file, to: target)
            } else {
                throw ArchiveError.unknownFormat(file.lastPathComponent)
            }
        }

        if !fm.fileExists(atPath: target.appendingPathComponent("manifest.json").path) {
            let found = (fm.enumerator(at: target, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "manifest.json" }
            guard found.count == 1 else { throw ArchiveError.missingManifest }
            let nested = found[0].deletingLastPathComponent()
            let flat = target.deletingLastPathComponent().appendingPathComponent("flatten-" + UUID().uuidString)
            try fm.moveItem(at: nested, to: flat); try fm.removeItem(at: target); try fm.moveItem(at: flat, to: target)
        }
    }

    /// Inflate a raw deflate stream of known expanded size via the bundled
    /// pure-Swift decoder (Stores/Inflate.swift — no C bindings, no
    /// framework quirks; same routine backs the ZIP and gzip paths).
    static func inflateRawDeflate(_ raw: Data, expandedSize: Int) throws -> Data {
        if expandedSize == 0 { return Data() }
        do {
            return try Inflater.inflate(raw, expectedSize: expandedSize)
        } catch InflateError.sizeMismatch(let got, let want) {
            throw ArchiveError.corrupt("inflate size mismatch: got \(got), want \(want)")
        } catch {
            throw ArchiveError.corrupt("deflate decode failed (\(error))")
        }
    }

    /// Resolve `name` inside `target`, refusing traversal outside it.
    static func safeDestination(name: String, in target: URL) throws -> URL {
        var clean = name
        while clean.hasPrefix("./") { clean.removeFirst(2) }
        while clean.hasPrefix("/") { clean.removeFirst() }
        let parts = clean.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") {
            throw ArchiveError.traversalBlocked(name)
        }
        var url = target
        for part in parts where !part.isEmpty {
            url.appendPathComponent(part)
        }
        // Belt-and-braces: the resolved path must stay under target.
        let base = target.standardized.path
        let dest = url.standardized.path
        guard dest == base || dest.hasPrefix(base + "/") else {
            throw ArchiveError.traversalBlocked(name)
        }
        return url
    }
}

// MARK: - ZIP

enum ZipReader {
    static func extract(file: URL, to target: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let entries = try centralDirectory(of: data)
        guard !entries.isEmpty else { throw ArchiveError.corrupt("empty ZIP") }
        for entry in entries {
            let dest = try ArchiveReader.safeDestination(name: entry.name, in: target)
            if entry.name.hasSuffix("/") { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true); continue }
            let lh = entry.localHeaderOffset
            guard lh >= 0, lh + 30 <= data.count, data[lh] == 0x50, data[lh + 1] == 0x4b else { throw ArchiveError.corrupt("invalid ZIP entry") }
            let start = lh + 30 + Int(data[lh + 26]) + (Int(data[lh + 27]) << 8) + Int(data[lh + 28]) + (Int(data[lh + 29]) << 8)
            guard start + entry.compressedSize <= data.count else { throw ArchiveError.corrupt("truncated ZIP payload") }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.method == 8 {
                try StreamingArchive.inflate(file, to: dest, offset: UInt64(start), length: entry.compressedSize, windowBits: -15, expectedSize: entry.uncompressedSize, expectedCRC: entry.crc)
            } else if entry.method == 0 {
                let source = try FileHandle(forReadingFrom: file); defer { try? source.close() }
                try source.seek(toOffset: UInt64(start))
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                let output = try FileHandle(forWritingTo: dest); defer { try? output.close() }
                var remaining = entry.compressedSize; var crc: uLong = 0
                while remaining > 0 {
                    guard let chunk = try source.read(upToCount: min(131072, remaining)), !chunk.isEmpty else { throw ArchiveError.corrupt("truncated stored ZIP") }
                    try output.write(contentsOf: chunk); remaining -= chunk.count
                    crc = chunk.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
                }
                guard entry.compressedSize == entry.uncompressedSize, UInt32(crc) == entry.crc else { throw ArchiveError.corrupt("ZIP checksum mismatch") }
            } else { throw ArchiveError.corrupt("unsupported ZIP compression") }
        }
    }

    static func extract(data: Data, to target: URL) throws {
        let entries = try centralDirectory(of: data)
        guard !entries.isEmpty else { throw ArchiveError.corrupt("empty central directory") }
        let fm = FileManager.default
        for entry in entries {
            let dest = try ArchiveReader.safeDestination(name: entry.name, in: target)
            if entry.name.hasSuffix("/") {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            let payload = try entryPayload(entry, in: data)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: dest)
        }
    }

    private struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private static func centralDirectory(of data: Data) throws -> [Entry] {
        // EOCD is at the very end (no comment in our packages, but scan back
        // up to 64KB to tolerate one).
        let scanStart = max(0, data.count - 65558)
        var eocdAt: Int?
        var i = data.count - 22
        while i >= scanStart {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocdAt = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdAt else { throw ArchiveError.corrupt("missing end-of-central-directory") }
        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }
        let count = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count,
                  data[p] == 0x50, data[p + 1] == 0x4B, data[p + 2] == 0x01, data[p + 3] == 0x02
            else { throw ArchiveError.corrupt("bad central directory entry") }
            guard u16(p + 8) & 1 == 0 else { throw ArchiveError.corrupt("encrypted ZIP is unsupported") }
            let method = UInt16(u16(p + 10))
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let headerOffset = u32(p + 42)
            let nameEnd = p + 46 + nameLen
            guard nameEnd <= data.count else { throw ArchiveError.corrupt("entry name overruns") }
            let nameData = data[(p + 46)..<nameEnd]
            // ZIP names are UTF-8 for our packages (Python zipfile).
            let name = String(data: nameData, encoding: .utf8) ?? String(bytes: nameData, encoding: .isoLatin1) ?? ""
            entries.append(Entry(name: name, method: method, crc: UInt32(u32(p + 16)),
                                 compressedSize: compSize, uncompressedSize: uncompSize,
                                 localHeaderOffset: headerOffset))
            p = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func entryPayload(_ entry: Entry, in data: Data) throws -> Data {
        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        let lh = entry.localHeaderOffset
        guard lh + 30 <= data.count,
              data[lh] == 0x50, data[lh + 1] == 0x4B, data[lh + 2] == 0x03, data[lh + 3] == 0x04
        else { throw ArchiveError.corrupt("bad local header for \(entry.name)") }
        let nameLen = u16(lh + 26)
        let extraLen = u16(lh + 28)
        let start = lh + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ArchiveError.corrupt("payload overruns for \(entry.name)") }
        let raw = data[start..<end]
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return try ArchiveReader.inflateRawDeflate(Data(raw), expandedSize: entry.uncompressedSize)
        default:
            throw ArchiveError.corrupt("unsupported method \(entry.method) for \(entry.name)")
        }
    }
}

// MARK: - TAR.GZ

enum TarGzReader {
    static func extract(data: Data, to target: URL) throws {
        let tar = try gunzip(data)
        try extractTar(tar, to: target)
    }

    /// Strip the gzip container (fixed 10-byte header for our packages, plus
    /// optional FNAME field) and inflate the raw deflate body. The 8-byte
    /// trailer (CRC32 + ISIZE) is validated for length only.
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
            throw ArchiveError.corrupt("not a gzip stream")
        }
        let flags = data[3]
        var pos = 10
        // FEXTRA
        if flags & 0x04 != 0 {
            guard pos + 2 <= data.count else { throw ArchiveError.corrupt("bad gzip FEXTRA") }
            let xlen = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            pos += 2 + xlen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while pos < data.count && data[pos] != 0 { pos += 1 }
            pos += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while pos < data.count && data[pos] != 0 { pos += 1 }
            pos += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { pos += 2 }
        guard pos < data.count - 8 else { throw ArchiveError.corrupt("gzip body missing") }
        let raw = data[pos..<(data.count - 8)]
        let isize = Int(data[data.count - 4]) | (Int(data[data.count - 3]) << 8)
            | (Int(data[data.count - 2]) << 16) | (Int(data[data.count - 1]) << 24)
        return try ArchiveReader.inflateRawDeflate(Data(raw), expandedSize: isize)
    }

    private static func extractTar(_ tar: Data, to target: URL) throws {
        let fm = FileManager.default
        var pos = 0
        var pendingLongName: String?
        while pos + 512 <= tar.count {
            let header = tar[pos..<(pos + 512)]
            if header.allSatisfy({ $0 == 0 }) { break } // end-of-archive zero blocks
            guard let name = cString(header, offset: 0, length: 100), !name.isEmpty else {
                throw ArchiveError.corrupt("bad tar name at block \(pos / 512)")
            }
            guard let sizeStr = cString(header, offset: 124, length: 12) else {
                throw ArchiveError.corrupt("bad tar size at block \(pos / 512)")
            }
            let size = Int(sizeStr.trimmingCharacters(in: .whitespacesAndNewlines), radix: 8) ?? 0
            let typeflag = header[header.startIndex + 156]
            let prefix = cString(header, offset: 345, length: 155) ?? ""
            let fullName: String = {
                if let long = pendingLongName { pendingLongName = nil; return long }
                return prefix.isEmpty ? name : prefix + "/" + name
            }()
            let dataStart = pos + 512
            let dataEnd = dataStart + size
            guard dataEnd <= tar.count else { throw ArchiveError.corrupt("tar payload overruns: \(fullName)") }
            let body = tar[dataStart..<dataEnd]

            switch typeflag {
            case UInt8(ascii: "L"):
                // GNU longname: body is the real name for the NEXT entry.
                pendingLongName = String(data: body.prefix(while: { $0 != 0 }), encoding: .utf8)
            case UInt8(ascii: "5"):
                let dest = try ArchiveReader.safeDestination(name: fullName, in: target)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            case 0, UInt8(ascii: "0"):
                let dest = try ArchiveReader.safeDestination(name: fullName, in: target)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(body).write(to: dest)
            default:
                break // PAX 'x'/'g' headers, symlinks, etc.: skip by size
            }
            pos = dataEnd + (512 - (size % 512)) % 512
        }
    }

    private static func cString(_ header: Data, offset: Int, length: Int) -> String? {
        let slice = header[(header.startIndex + offset)..<(header.startIndex + offset + length)]
        let bytes = slice.prefix(while: { $0 != 0 })
        return String(data: Data(bytes), encoding: .utf8)
    }
}

/// 128 KiB streaming buffers keep imported multi-gigabyte books off the heap.
/// zlib validates gzip trailers; ZIP CRC and size are checked explicitly.
enum StreamingArchive {
    static func inflate(_ source: URL, to destination: URL, offset: UInt64 = 0, length: Int? = nil, windowBits: Int32 = 31, expectedSize: Int? = nil, expectedCRC: UInt32? = nil) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        try input.seek(toOffset: offset)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ArchiveError.corrupt("cannot initialize decompression") }
        defer { inflateEnd(&stream) }
        var remaining = length; var status: Int32 = Z_OK; var checksum: uLong = 0; var written = 0
        var buffer = [UInt8](repeating: 0, count: 131072)
        while status != Z_STREAM_END {
            let count = min(131072, remaining ?? 131072)
            guard count > 0, let chunk = try input.read(upToCount: count), !chunk.isEmpty else { throw ArchiveError.corrupt("truncated compressed stream") }
            if remaining != nil { remaining! -= chunk.count }
            try chunk.withUnsafeBytes { bytes in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress!); stream.avail_in = uInt(chunk.count)
                repeat {
                    try buffer.withUnsafeMutableBytes { out in
                        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress!; stream.avail_out = uInt(out.count)
                        status = zlib.inflate(&stream, Z_NO_FLUSH)
                        guard status == Z_OK || status == Z_STREAM_END else { throw ArchiveError.corrupt("compressed checksum or stream failure") }
                        let produced = out.count - Int(stream.avail_out)
                        written += produced
                        guard written <= 16 * 1024 * 1024 * 1024 else { throw ArchiveError.corrupt("package exceeds import size limit") }
                        checksum = zlib.crc32(checksum, out.bindMemory(to: Bytef.self).baseAddress, uInt(produced))
                        if produced > 0 { try output.write(contentsOf: Data(bytes: out.baseAddress!, count: produced)) }
                    }
                } while status != Z_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
            }
        }
        if let expectedSize, expectedSize != written { throw ArchiveError.corrupt("expanded ZIP size mismatch") }
        if let expectedCRC, UInt32(checksum) != expectedCRC { throw ArchiveError.corrupt("ZIP checksum mismatch") }
    }
    static func extractGzip(_ file: URL, to target: URL) throws {
        let tar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        try inflate(file, to: tar)
        try extractTarFile(tar, to: target)
    }
    static func extractTarFile(_ tar: URL, to target: URL) throws {
        let input = try FileHandle(forReadingFrom: tar); defer { try? input.close() }
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let next = try input.read(upToCount: count - data.count), !next.isEmpty else { throw ArchiveError.corrupt("truncated TAR") }
                data.append(next)
            }; return data
        }
        func string(_ data: Data, _ offset: Int, _ count: Int) -> String { String(data: data.subdata(in: offset..<(offset + count)).prefix(while: { $0 != 0 }), encoding: .utf8) ?? "" }
        var longName: String?; var paxPath: String?
        while true {
            let header = try read(512)
            if header.allSatisfy({ $0 == 0 }) { break }
            let checksum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard Int(string(header, 148, 8).trimmingCharacters(in: .whitespaces), radix: 8) == checksum,
                  let size = Int(string(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8), size >= 0 else { throw ArchiveError.corrupt("invalid TAR header") }
            let prefix = string(header, 345, 155); let short = string(header, 0, 100)
            let name = paxPath ?? longName ?? (prefix.isEmpty ? short : prefix + "/" + short)
            let type = header[156]
            if type == 76 || type == 120 || type == 103 {
                guard size <= 1_048_576 else { throw ArchiveError.corrupt("TAR metadata too large") }
                let data = try read(size)
                if type == 76 { longName = String(data: data.prefix(while: { $0 != 0 }), encoding: .utf8) }
                else if let metadata = String(data: data, encoding: .utf8) {
                    for line in metadata.split(separator: "\n") {
                        if let range = line.range(of: " path=") { paxPath = String(line[range.upperBound...]) }
                    }
                }
            } else {
                longName = nil; paxPath = nil
                let dest = try ArchiveReader.safeDestination(name: name, in: target)
                if type == 53 { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) }
                var output: FileHandle?
                if type == 0 || type == 48 {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: dest.path, contents: nil)
                    output = try FileHandle(forWritingTo: dest)
                }
                defer { try? output?.close() }
                var remaining = size
                while remaining > 0 { let data = try read(min(131072, remaining)); try output?.write(contentsOf: data); remaining -= data.count }
            }
            let pad = (512 - size % 512) % 512
            if pad > 0 { _ = try read(pad) }
        }
    }
}
