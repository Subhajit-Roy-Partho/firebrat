import Foundation

@main enum ArchiveTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["nested.zip", "nested.tar.gz"] {
            let target = root.appendingPathComponent("out-" + name)
            try ArchiveReader.extract(file: root.appendingPathComponent(name), to: target)
            precondition(FileManager.default.fileExists(atPath: target.appendingPathComponent("manifest.json").path))
            let payload = target.appendingPathComponent("payload.bin")
            let size = try FileManager.default.attributesOfItem(atPath: payload.path)[.size] as! NSNumber
            precondition(size.intValue == 32 * 1024 * 1024)
        }
        for name in ["corrupt.zip", "corrupt.tar.gz", "unsafe.zip"] {
            do {
                try ArchiveReader.extract(file: root.appendingPathComponent(name), to: root.appendingPathComponent("reject-" + name))
                fatalError("Invalid archive accepted: \(name)")
            } catch { print("Rejected \(name): \(error.localizedDescription)") }
        }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        print("Archive tests passed: streaming ZIP/gzip, nested root, CRC, traversal")
    }
}
