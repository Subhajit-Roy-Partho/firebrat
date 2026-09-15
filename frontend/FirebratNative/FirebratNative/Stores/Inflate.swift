import Foundation

/// Minimal pure-Swift DEFLATE decoder (RFC 1951): stored, fixed-Huffman and
/// dynamic-Huffman blocks with a 32KB LZ77 window. One file, no C bindings,
/// no framework quirks — the same routine backs both the ZIP and gzip paths
/// in ArchiveReader.

enum InflateError: Error {
    case truncated
    case invalidBlock
    case invalidLengths
    case invalidDistance
    case sizeMismatch(Int, Int)
}

/// LSB-first bit reader over the raw deflate stream.
private struct BitReader {
    var data: Data
    var bytePos: Int = 0
    var bitPos: Int = 0 // 0-7, LSB first

    mutating func readBit() throws -> Int {
        guard bytePos < data.count else { throw InflateError.truncated }
        let bit = (Int(data[bytePos]) >> bitPos) & 1
        bitPos += 1
        if bitPos == 8 { bitPos = 0; bytePos += 1 }
        return bit
    }

    mutating func readBits(_ n: Int) throws -> Int {
        var value = 0
        for i in 0..<n {
            value |= (try readBit()) << i
        }
        return value
    }

    mutating func alignToByte() {
        if bitPos != 0 { bitPos = 0; bytePos += 1 }
    }

    mutating func readUInt16LE() throws -> Int {
        alignToByte()
        guard bytePos + 2 <= data.count else { throw InflateError.truncated }
        let v = Int(data[bytePos]) | (Int(data[bytePos + 1]) << 8)
        bytePos += 2
        return v
    }

    mutating func readBytes(_ n: Int) throws -> Data {
        alignToByte()
        guard bytePos + n <= data.count else { throw InflateError.truncated }
        let slice = data[bytePos..<(bytePos + n)]
        bytePos += n
        return Data(slice)
    }
}

/// Canonical Huffman code decoded by tree walk (book assets are small;
/// clarity beats a lookup table here).
private struct HuffmanTree {
    // Binary tree stored flat: each node is (child0, child1, symbol).
    var nodes: [(Int, Int, Int)] = [(-1, -1, -1)]

    init(lengths: [Int]) throws {
        // lengths[symbol] = code length (0 = unused).
        let maxLen = lengths.max() ?? 0
        guard maxLen <= 15 else { throw InflateError.invalidLengths }
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for len in lengths where len > 0 { blCount[len] += 1 }
        var nextCode = [Int](repeating: 0, count: maxLen + 1)
        var code = 0
        for bits in 1...maxLen {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        for (symbol, len) in lengths.enumerated() where len > 0 {
            var c = nextCode[len]
            nextCode[len] += 1
            // Walk/create nodes MSB-first over `len` bits.
            var node = 0
            for i in stride(from: len - 1, through: 0, by: -1) {
                let bit = (c >> i) & 1
                if bit == 0 {
                    if nodes[node].0 == -1 {
                        nodes[node].0 = nodes.count
                        nodes.append((-1, -1, -1))
                    }
                    node = nodes[node].0
                } else {
                    if nodes[node].1 == -1 {
                        nodes[node].1 = nodes.count
                        nodes.append((-1, -1, -1))
                    }
                    node = nodes[node].1
                }
                c &= ~(1 << i)
            }
            nodes[node].2 = symbol
        }
    }

    func decode(_ reader: inout BitReader) throws -> Int {
        var node = 0
        while true {
            let bit = try reader.readBit()
            node = (bit == 0) ? nodes[node].0 : nodes[node].1
            guard node >= 0 && node < nodes.count else { throw InflateError.invalidBlock }
            let sym = nodes[node].2
            if sym >= 0 { return sym }
        }
    }
}

enum Inflater {
    // Length code 257-285 → (base, extraBits). Index = code - 257.
    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    // Dist code 0-29 → (base, extraBits).
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                   8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Inflate `raw` (a raw deflate stream, no zlib/gzip wrapper). When
    /// `expectedSize > 0` the output must match it exactly, else corrupt.
    static func inflate(_ raw: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var reader = BitReader(data: raw)
        var output = Data()
        output.reserveCapacity(expectedSize)
        var final = false
        while !final {
            final = (try reader.readBit()) == 1
            let type = try reader.readBits(2)
            switch type {
            case 0: // stored
                let len = try reader.readUInt16LE()
                let nlen = try reader.readUInt16LE()
                guard len ^ 0xFFFF == nlen else { throw InflateError.invalidBlock }
                output.append(try reader.readBytes(len))
            case 1: // fixed Huffman
                var litLengths = [Int](repeating: 0, count: 288)
                for i in 0..<144 { litLengths[i] = 8 }
                for i in 144..<256 { litLengths[i] = 9 }
                for i in 256..<280 { litLengths[i] = 7 }
                for i in 280..<288 { litLengths[i] = 8 }
                let litTree = try HuffmanTree(lengths: litLengths)
                let distTree = try HuffmanTree(lengths: [Int](repeating: 5, count: 32))
                try decodeBody(&reader, output: &output, litTree: litTree, distTree: distTree)
            case 2: // dynamic Huffman
                let hlit = try reader.readBits(5) + 257
                let hdist = try reader.readBits(5) + 1
                let hclen = try reader.readBits(4) + 4
                var clLengths = [Int](repeating: 0, count: 19)
                for i in 0..<hclen {
                    clLengths[clOrder[i]] = try reader.readBits(3)
                }
                let clTree = try HuffmanTree(lengths: clLengths)
                var allLengths: [Int] = []
                while allLengths.count < hlit + hdist {
                    let sym = try clTree.decode(&reader)
                    switch sym {
                    case 0..<16:
                        allLengths.append(sym)
                    case 16: // repeat previous 3-6 times
                        guard let prev = allLengths.last else { throw InflateError.invalidLengths }
                        let n = try reader.readBits(2) + 3
                        allLengths.append(contentsOf: [Int](repeating: prev, count: n))
                    case 17: // 3-10 zeros
                        let n = try reader.readBits(3) + 3
                        allLengths.append(contentsOf: [Int](repeating: 0, count: n))
                    case 18: // 11-138 zeros
                        let n = try reader.readBits(7) + 11
                        allLengths.append(contentsOf: [Int](repeating: 0, count: n))
                    default:
                        throw InflateError.invalidLengths
                    }
                }
                guard allLengths.count == hlit + hdist else { throw InflateError.invalidLengths }
                let litTree = try HuffmanTree(lengths: Array(allLengths[0..<hlit]))
                // hdist=1 with a single zero length is legal (no distances used).
                var distLengths = Array(allLengths[hlit...])
                while distLengths.count < 2 { distLengths.append(0) }
                let distTree = try HuffmanTree(lengths: distLengths)
                try decodeBody(&reader, output: &output, litTree: litTree, distTree: distTree)
            default:
                throw InflateError.invalidBlock // BTYPE 11 is reserved
            }
        }
        guard output.count == expectedSize else {
            throw InflateError.sizeMismatch(output.count, expectedSize)
        }
        return output
    }

    private static func decodeBody(_ reader: inout BitReader, output: inout Data,
                                   litTree: HuffmanTree, distTree: HuffmanTree) throws {
        while true {
            let sym = try litTree.decode(&reader)
            if sym < 256 {
                output.append(UInt8(sym))
            } else if sym == 256 {
                return // end of block
            } else if sym <= 285 {
                let li = sym - 257
                var length = lengthBase[li]
                length += try reader.readBits(lengthExtra[li])
                let dsym = try distTree.decode(&reader)
                guard dsym < 30 else { throw InflateError.invalidDistance }
                var dist = distBase[dsym]
                dist += try reader.readBits(distExtra[dsym])
                guard dist >= 1 && dist <= output.count else { throw InflateError.invalidDistance }
                // LZ77 copy (byte-by-byte: handles overlap correctly).
                let start = output.count - dist
                for i in 0..<length {
                    output.append(output[start + i])
                }
            } else {
                throw InflateError.invalidBlock
            }
        }
    }
}
