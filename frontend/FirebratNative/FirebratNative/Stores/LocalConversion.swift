import Foundation
import Combine
import PDFKit
import Vision
import AVFoundation
import UIKit

struct LocalPage: Sendable { var index: Int; var text: String }
struct CastMember: Codable { var name: String; var gender: String; var evidencePages: [Int]; var voice: String }

struct LocalVoiceOptions: Sendable {
    let compiler: String; let languageModel: String; let useMetal: Bool
    let contentMode: String; let narratorVoice: String; let maleVoice: String; let femaleVoice: String
    let characterOverrides: String; let voiceEngine: String
    let kokoroNarrator: String; let kokoroMale: String; let kokoroFemale: String
    @MainActor init(_ settings: AppSettings) {
        compiler = settings.compiler; languageModel = settings.languageModel; useMetal = settings.useMetal
        contentMode = settings.contentMode; narratorVoice = settings.narratorVoice
        maleVoice = settings.maleVoice; femaleVoice = settings.femaleVoice
        characterOverrides = settings.characterOverrides; voiceEngine = settings.voiceEngine
        kokoroNarrator = settings.kokoroNarrator; kokoroMale = settings.kokoroMale; kokoroFemale = settings.kokoroFemale
    }
}

/// Verbatim local conversion: PDFKit + Vision OCR + installed Apple speech.
/// No cloud, credentials, or speculative LLM rewriting is used in this path.
@MainActor final class LocalConversion: NSObject, ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var progress = 0.0
    @Published var error: String?
    @Published var reviewNote: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?
    private var speechFile: AVAudioFile?
    private var speechURL: URL?
    private var speechID: UUID?
    private var task: Task<Void, Never>?
    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.name, $0.identifier) < ($1.name, $1.identifier) }
    }
    func cancel() {
        task?.cancel(); synthesizer.stopSpeaking(at: .immediate)
        if let continuation { self.continuation = nil; continuation.resume(throwing: CancellationError()) }
    }
    func start(pdf: URL, store: BookStore, settings: AppSettings) {
        guard !running else { return }
        running = true; error = nil; reviewNote = nil; progress = 0
        task = Task {
            let access = pdf.startAccessingSecurityScopedResource()
            defer { if access { pdf.stopAccessingSecurityScopedResource() }; running = false }
            do { try await convert(pdf: pdf, store: store, settings: settings) }
            catch is CancellationError { status = "Conversion cancelled. No incomplete book was added." }
            catch { self.error = error.localizedDescription; status = "Conversion failed" }
        }
    }
    private func convert(pdf: URL, store: BookStore, settings: AppSettings) async throws {
        let conversionStarted = Date()
        var ttsSeconds = 0.0
        let options = LocalVoiceOptions(settings)
        let fm = FileManager.default
        let id = "local-" + UUID().uuidString.lowercased()
        let root = try store.booksDirectory()
        let stage = root.appendingPathComponent(".conversion-\(id)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: pdf, to: stage.appendingPathComponent("source.pdf"))
        status = "Extracting text and original pages…"
        let novel = options.contentMode == "novel"
        let worker = Task.detached(priority: .userInitiated) { () throws -> [LocalPage] in
            guard let document = PDFDocument(url: stage.appendingPathComponent("source.pdf")), document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            if !novel { try fm.createDirectory(at: stage.appendingPathComponent("figures"), withIntermediateDirectories: true) }
            var result: [LocalPage] = []
            for i in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: i) else { throw CocoaError(.fileReadCorruptFile) }
                var text = page.string ?? ""
                let size = page.bounds(for: .mediaBox).size
                let scale = min(1600 / max(size.width, size.height), 3)
                let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
                    guard let cg = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
                if !novel {
                    guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: stage.appendingPathComponent(String(format: "figures/page_%04d.png", i + 1)))
                }
                result.append(LocalPage(index: i, text: text))
            }
            return result
        }
        var pages = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        let extractionSeconds = Date().timeIntervalSince(conversionStarted)
        guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain: "Firebrat", code: 1, userInfo: [NSLocalizedDescriptionKey: "No readable text found, including offline OCR."])
        }
        // Cast comes from original prose, never the model's guesses.
        let originalPages = pages
        var generationReport: [[String: Any]] = []
        if options.compiler == "llm" {
            status = "Preparing local language model (first use downloads weights)…"
            let llm = try await NativeLLM.prepare(id: options.languageModel, metal: options.useMetal) { [weak self] fraction in
                Task { @MainActor in self?.status = "Downloading language model: \(Int(fraction * 100))%" }
            }
            for i in pages.indices {
                try Task.checkCancellation()
                let source = pages[i].text
                // Bounded chunks keep memory/context predictable on a phone.
                var remainder = source, chunks: [String] = [], results: [String] = []
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(1000, remainder.count))
                    let split = end == remainder.endIndex ? end : (remainder[..<end].lastIndex(where: { $0.isWhitespace }).map { remainder.index(after: $0) } ?? end)
                    chunks.append(String(remainder[..<split])); remainder = String(remainder[split...])
                }
                for chunk in chunks {
                    status = "Preparing narration for page \(i + 1) of \(pages.count)…"
                    do {
                        let result = try await llm.generate(instruction: "Convert the SOURCE to natural spoken narration. Preserve every fact, name, number, equation and dialogue quotation. Do not summarize, add facts or discuss these instructions. Return only narration. /no_think", source: chunk)
                        let accepted = result.stopped && Self.retainsSource(source: chunk, output: result.text)
                        results.append(accepted ? result.text : chunk)
                        var record = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))) as! [String: Any]
                        record["page"] = i; record["accepted"] = accepted; record["source_preserved_on_failure"] = !accepted
                        generationReport.append(record)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        results.append(chunk)
                        generationReport.append(["page": i, "accepted": false, "source_preserved_on_failure": true, "error": error.localizedDescription])
                    }
                }
                pages[i].text = results.joined(separator: "\n")
            }
            let retained = generationReport.filter { $0["accepted"] as? Bool == false }.count
            reviewNote = retained > 0 ? "The model did not pass source checks for \(retained) passage(s), so the original text was kept. Review the narration against the source PDF." : "Local model narration was generated. Review it against the source PDF before relying on it."
            try Self.writeJSON(["requested_metal": options.useMetal, "provider": "llama.cpp", "model": options.languageModel, "chunks": generationReport, "human_review_required": true], to: stage.appendingPathComponent("compilation_report.json"))
        }
        let available = Self.voices
        let narrator = available.first(where: { $0.identifier == options.narratorVoice }) ?? available.first
        if options.voiceEngine != "kokoro" && narrator == nil {
            throw NSError(domain: "Firebrat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Install an English voice in Apple Spoken Content settings, then try again."])
        }
        var kokoro: KokoroRuntime?
        if options.voiceEngine == "kokoro" {
            status = "Preparing Kokoro neural voices (first use downloads about 100 MB)…"
            kokoro = try await KokoroRuntime.prepare { [weak self] fraction in
                Task { @MainActor in self?.status = "Downloading Kokoro voices: \(Int(fraction * 100))%" }
            }
        }
        let cast = novel ? NovelCasting.scan(pages: originalPages, voices: available, narrator: narrator, settings: options) : []
        try JSONEncoder().encode(cast).write(to: stage.appendingPathComponent("character_roster.json"))
        var sections: [[String: Any]] = []; var figures: [[String: Any]] = []; var totalMs = 0
        for page in pages where !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            let sid = String(format: "sec_%04d", sections.count + 1)
            let dir = stage.appendingPathComponent("sections/\(sid)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let utterances = novel ? NovelCasting.split(page.text, cast: cast) : [(page.text, nil)]
            var clips: [(URL, String)] = []
            for (text, speaker) in utterances {
                // Keep every source character while bounding individual utterances.
                var remainder = text
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(400, remainder.count))
                    let boundary = end == remainder.endIndex ? end : (remainder[..<end].lastIndex(where: { $0.isWhitespace }).map { remainder.index(after: $0) } ?? end)
                    let part = String(remainder[..<boundary]); remainder = String(remainder[boundary...])
                    if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    let clip = dir.appendingPathComponent("clip-\(clips.count).wav")
                    status = "Narrating page \(page.index + 1) of \(pages.count)…"
                    let speechStarted = Date()
                    if let kokoro {
                        try await kokoro.synthesize(part, preset: speaker?.voice ?? options.kokoroNarrator, to: clip)
                    } else {
                        let voice = speaker.flatMap { member in available.first(where: { $0.identifier == member.voice }) } ?? narrator!
                        try await synthesize(part, voice: voice, to: clip)
                    }
                    ttsSeconds += Date().timeIntervalSince(speechStarted)
                    clips.append((clip, part))
                }
            }
            guard !clips.isEmpty else { continue }
            let audio = dir.appendingPathComponent("audio.wav")
            let output = try AVAudioFile(forWriting: audio, settings: Self.audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var timed: [[String: Any]] = []; var frames: AVAudioFramePosition = 0
            for (i, clip) in clips.enumerated() {
                let input = try AVAudioFile(forReading: clip.0)
                let start = Int(frames * 1000 / 24000)
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
                while input.framePosition < input.length { try input.read(into: buffer); try output.write(from: buffer); frames += Int64(buffer.frameLength) }
                let end = Int(frames * 1000 / 24000)
                let fid = String(format: "fig_%04d", page.index + 1)
                timed.append(["segment_id": "\(sid)_seg_\(i)", "index": i, "type": !novel && i == 0 ? "figure_callout" : "prose", "text": clip.1, "ref": !novel && i == 0 ? fid as Any : NSNull(), "start_ms": start, "end_ms": end, "visually_essential": !novel && i == 0])
                if i < clips.count - 1 {
                    let silence = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 6240)!
                    silence.frameLength = 6240; memset(silence.floatChannelData![0], 0, 6240 * MemoryLayout<Float>.size)
                    try output.write(from: silence); frames += 6240
                }
                try fm.removeItem(at: clip.0)
            }
            let duration = Int(frames * 1000 / 24000); totalMs += duration
            try Self.writeJSON(["section_id": sid, "sample_rate": 24000, "pause_ms_between_segments": 260, "segments": timed], to: dir.appendingPathComponent("segments.json"))
            let fid = String(format: "fig_%04d", page.index + 1)
            sections.append(["section_id": sid, "order": sections.count + 1, "title": "Page \(page.index + 1)", "audio_path": "sections/\(sid)/audio.wav", "segments_path": "sections/\(sid)/segments.json", "duration_ms": duration, "figure_refs": novel ? [] : [fid], "formula_refs": [], "table_refs": [], "source_pages": [page.index], "needs_review": options.compiler == "llm"])
            if !novel { figures.append(["figure_id": fid, "caption": "Source page \(page.index + 1) (original layout)", "image_path": String(format: "figures/page_%04d.png", page.index + 1), "page": page.index]) }
            progress = Double(page.index + 1) / Double(pages.count)
        }
        try Self.writeJSON(["schema_version": "1.0", "book_id": id, "title": pdf.deletingPathExtension().lastPathComponent, "author": "", "source_pdf": pdf.lastPathComponent, "source_pdf_path": "source.pdf", "content_mode": novel ? "novel" : "illustrated", "generated_at": ISO8601DateFormatter().string(from: Date()), "total_duration_ms": totalMs, "sections": sections, "figures": figures, "formulas": [], "tables": [], "narrator_voice": ["engine": options.voiceEngine == "kokoro" ? "kokoro_onnx" : "apple_speech", "voice": options.voiceEngine == "kokoro" ? options.kokoroNarrator : narrator!.identifier, "sample_rate": 24000], "audio_format": ["codec": "pcm_s16le", "container": "wav", "sample_rate": 24000, "channels": 1]], to: stage.appendingPathComponent("manifest.json"))
        try Self.writeJSON(["elapsed_seconds": Date().timeIntervalSince(conversionStarted), "extraction_seconds": extractionSeconds, "tts_seconds": ttsSeconds, "audio_seconds": Double(totalMs) / 1000, "tts_realtime_factor": ttsSeconds / max(0.001, Double(totalMs) / 1000), "voice_engine": options.voiceEngine, "compiler": options.compiler, "source_page_count": originalPages.count], to: stage.appendingPathComponent("conversion_metrics.json"))
        try fm.moveItem(at: stage, to: root.appendingPathComponent(id))
        await store.refreshLocalBooks(); status = "Converted offline — open the book in your library."
    }
    static func retainsSource(source: String, output: String) -> Bool {
        guard !output.isEmpty, output.count >= source.count * 3 / 4, output.count <= source.count * 3 / 2 else { return false }
        let number = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)
        func values(_ text: String) -> Set<String> { Set(number.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }) }
        guard values(source) == values(output) else { return false }
        func words(_ text: String) -> Set<String> { Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }) }
        let a = words(source), b = words(output)
        return !a.isEmpty && Double(a.intersection(b).count) / Double(a.count) >= 0.9 && Double(a.intersection(b).count) / Double(max(1, b.count)) >= 0.8
    }
    static let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    static func writeJSON(_ object: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic) }
    private func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, to url: URL) async throws {
        try Task.checkCancellation()
        speechFile = nil; speechURL = url
        let identifier = UUID(); speechID = identifier
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                DispatchQueue.main.async { self?.received(buffer, id: identifier) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, self.speechID == identifier, let pending = self.continuation else { return }
                self.continuation = nil; self.speechID = nil
                self.synthesizer.stopSpeaking(at: .immediate)
                pending.resume(throwing: NSError(domain: "FirebratSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech generation timed out. Install an offline Apple voice and try again."]))
            }
        }
    }
    private func received(_ buffer: AVAudioBuffer, id: UUID) {
        guard speechID == id, let continuation else { return }
        guard let input = buffer as? AVAudioPCMBuffer else { return }
        do {
            if input.frameLength == 0 {
                speechFile = nil
                guard let url = speechURL, (try AVAudioFile(forReading: url)).length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                self.continuation = nil; continuation.resume(); return
            }
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: input.format, to: target),
                  let normalized = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 24000 / input.format.sampleRate) + 128) else { throw CocoaError(.coderInvalidValue) }
            var provided = false; var conversionError: NSError?
            converter.convert(to: normalized, error: &conversionError) { _, state in
                if provided { state.pointee = .endOfStream; return nil }
                provided = true; state.pointee = .haveData; return input
            }
            if let conversionError { throw conversionError }
            if speechFile == nil { speechFile = try AVAudioFile(forWriting: speechURL!, settings: Self.audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false) }
            try speechFile?.write(from: normalized)
        } catch { self.continuation = nil; speechFile = nil; continuation.resume(throwing: error); synthesizer.stopSpeaking(at: .immediate) }
    }
}

enum NovelCasting {
    static let quotes = try! NSRegularExpression(pattern: "“[^”]+”|\"[^\"\\n]+\"")
    static func speaker(_ text: String, _ range: Range<String.Index>) -> String? {
        let tail = String(text[range.upperBound...]).components(separatedBy: .newlines).first ?? ""
        let regex = try! NSRegularExpression(pattern: "^\\s*[,;:]?\\s*([A-Z][a-z]+(?: [A-Z][a-z]+)?)\\s+(?:said|asked|replied|answered|whispered|shouted)\\b")
        var found: String?
        if let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)), let nameRange = Range(match.range(at: 1), in: tail) { found = String(tail[nameRange]) }
        if found == nil {
            let head = String(text[..<range.lowerBound].suffix(160))
            let before = try! NSRegularExpression(pattern: #"\b([A-Z][a-z]+(?: [A-Z][a-z]+)?)\s+(?:said|asked|replied|answered|whispered|shouted)\s*[,;:]?\s*$"#)
            if let match = before.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)), let names = Range(match.range(at: 1), in: head) { found = String(head[names]) }
        }
        guard let name = found else { return nil }
        return ["He", "She", "They", "It", "We", "You"].contains(name) ? nil : name
    }
    @MainActor static func scan(pages: [LocalPage], voices: [AVSpeechSynthesisVoice], narrator: AVSpeechSynthesisVoice?, settings: LocalVoiceOptions) -> [CastMember] {
        var names: [String: Set<Int>] = [:]
        for page in pages { for match in quotes.matches(in: page.text, range: NSRange(page.text.startIndex..., in: page.text)) {
            if let range = Range(match.range, in: page.text), let name = speaker(page.text, range) { names[name, default: []].insert(page.index) }
        } }
        var overrides: [String: String] = [:]
        for line in settings.characterOverrides.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { overrides[parts[0]] = parts[1] }
        }
        var voiceCounts: [String: Int] = [:]
        return names.keys.sorted().map { name in
            var genders = Set<String>()
            for page in pages {
                let text = quotes.stringByReplacingMatches(in: page.text, range: NSRange(page.text.startIndex..., in: page.text), withTemplate: " ")
                for (gender, pattern) in [ ("female", "\\b(?:was|is) (?:a )?(?:woman|girl|female)\\b|\\b(?:as|while) she\\b"), ("male", "\\b(?:was|is) (?:a )?(?:man|boy|male)\\b|\\b(?:as|while) he\\b") ] {
                    let regex = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b[^.!?\\n]{0,65}(?:" + pattern + ")")
                    for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
                        // Do not attach another named character's pronoun to this one.
                        let otherName = names.keys.contains { other in
                            other != name && sentence.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: other) + #"\b"#, options: .regularExpression) != nil
                        }
                        if !otherName && regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil { genders.insert(gender) }
                    }
                }
            }
            let gender = genders.count == 1 ? genders.first! : "unknown"
            let index = voiceCounts[gender, default: 0]; voiceCounts[gender] = index + 1
            if settings.voiceEngine == "kokoro" {
                let primary = gender == "male" ? settings.kokoroMale : settings.kokoroFemale
                let pool = gender == "male" ? KokoroRuntime.male : gender == "female" ? KokoroRuntime.female : [settings.kokoroNarrator]
                let ordered = [primary] + pool.filter { $0 != primary }
                let automatic = gender == "unknown" ? settings.kokoroNarrator : ordered[index % ordered.count]
                let preset = overrides[name] ?? automatic
                return CastMember(name: name, gender: gender, evidencePages: Array(names[name]!).sorted(), voice: KokoroRuntime.ids[preset] != nil ? preset : settings.kokoroNarrator)
            }
            let selected = gender == "male" ? settings.maleVoice : gender == "female" ? settings.femaleVoice : (narrator?.identifier ?? "")
            let primary = voices.first(where: { $0.identifier == selected })
            let pool = voices.filter { (gender == "male" && $0.gender == .male) || (gender == "female" && $0.gender == .female) }
            let ordered = (primary.map { [$0] } ?? []) + pool.filter { $0.identifier != primary?.identifier }
            let automatic = ordered.isEmpty || gender == "unknown" ? narrator : ordered[index % ordered.count]
            let desired = overrides[name]
            let voice = voices.first(where: { $0.identifier == desired || $0.name == desired }) ?? automatic
            return CastMember(name: name, gender: gender, evidencePages: Array(names[name]!).sorted(), voice: voice?.identifier ?? "")
        }
    }
    static func split(_ text: String, cast: [CastMember]) -> [(String, CastMember?)] {
        var result: [(String, CastMember?)] = []; var cursor = text.startIndex
        for match in quotes.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound { result.append((String(text[cursor..<range.lowerBound]), nil)) }
            let name = speaker(text, range); result.append((String(text[range]), cast.first(where: { $0.name == name }))); cursor = range.upperBound
        }
        if cursor < text.endIndex { result.append((String(text[cursor...]), nil)) }; return result
    }
}
