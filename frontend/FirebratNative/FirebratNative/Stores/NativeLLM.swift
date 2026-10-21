import Foundation
import CryptoKit
import llama

struct NativeModel: Identifiable, Sendable {
    let id: String; let name: String; let url: String; let checksum: String; let bytes: Int64; let format: String
    static let catalog: [NativeModel] = [
        .init(id: "qwen3-0.6b", name: "Qwen3 0.6B", url: "https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q4_K_M.gguf", checksum: "9acfc1e001311f34b4252001b626f2e466d592a42065f66571bff3790d4e1b14", bytes: 484220320, format: "chatml"),
        .init(id: "qwen3-1.7b", name: "Qwen3 1.7B", url: "https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q4_K_M.gguf", checksum: "72c5c3cb38fa32d5256e2fe30d03e7a64c6c79e668ad84057e3bd66e250b24fb", bytes: 1282439584, format: "chatml"),
        .init(id: "gemma-3-1b", name: "Gemma 3 1B", url: "https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q4_K_M.gguf", checksum: "12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d", bytes: 806058496, format: "gemma")
    ]
}
struct ModelGeneration: Codable, Sendable {
    var text: String; var model: String; var accelerator: String
    var promptTokens: Int; var generatedTokens: Int; var elapsedSeconds: Double; var stopped: Bool
}

enum NativeModelError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

/// One serialized context per conversion. Every inference call is local.
actor NativeLLM {
    private static let initialized: Void = { llama_backend_init() }()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let preset: NativeModel
    private let accelerator: String
    init(file: URL, preset: NativeModel, metal: Bool) throws {
        _ = Self.initialized
        self.preset = preset
        var mp = llama_model_default_params()
#if targetEnvironment(simulator)
        // The real simulator Metal trial hit the generation deadline. Keep
        // simulator conversions on the verified CPU path; physical Metal is opt-in.
        let useMetal = false
#else
        let useMetal = metal && llama_supports_gpu_offload() && ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) != nil
#endif
        accelerator = useMetal ? "metal" : "cpu"
        mp.n_gpu_layers = useMetal ? 99 : 0
        guard let loaded = llama_model_load_from_file(file.path, mp) else { throw NativeModelError.failed("Language model could not be loaded. Check available memory and the model download.") }
        model = loaded
        var cp = llama_context_default_params()
        cp.n_ctx = 2048; cp.n_batch = 512; cp.n_ubatch = 128
        cp.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)); cp.n_threads_batch = cp.n_threads
        cp.offload_kqv = useMetal
        guard let ctx = llama_init_from_model(loaded, cp) else { llama_model_free(loaded); throw NativeModelError.failed("Not enough memory for the local model context.") }
        context = ctx
    }
    deinit { llama_free(context); llama_model_free(model) }
    static func prepare(id: String, metal: Bool, progress: (@Sendable (Double) -> Void)? = nil) async throws -> NativeLLM {
        let preset = NativeModel.catalog.first(where: { $0.id == id }) ?? NativeModel.catalog[0]
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("models")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(preset.id + ".gguf"), marker = root.appendingPathComponent(preset.id + ".sha256")
        if (try? String(contentsOf: marker, encoding: .utf8)) != preset.checksum || !fm.fileExists(atPath: file.path) {
            let temp = try await AssetDownload.fetch(URL(string: preset.url)!, progress: progress)
            defer { try? fm.removeItem(at: temp) }
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                let input = try FileHandle(forReadingFrom: temp); defer { try? input.close() }
                var hash = SHA256(); var size: Int64 = 0
                while let data = try input.read(upToCount: 131072), !data.isEmpty { hash.update(data: data); size += Int64(data.count) }
                guard size == preset.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == preset.checksum else { throw NativeModelError.failed("Language-model checksum mismatch") }
            }.value
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            try fm.moveItem(at: temp, to: file); try preset.checksum.write(to: marker, atomically: true, encoding: .utf8)
        }
        return try await Task.detached(priority: .userInitiated) { try NativeLLM(file: file, preset: preset, metal: metal) }.value
    }
    func generate(instruction: String, source: String, maxTokens: Int = 384) throws -> ModelGeneration {
        try Task.checkCancellation()
        let prompt: String
        if preset.format == "gemma" { prompt = "<bos><start_of_turn>user\n\(instruction)\n\n\(source)<end_of_turn>\n<start_of_turn>model\n" }
        else { prompt = "<|im_start|>system\n\(instruction)<|im_end|>\n<|im_start|>user\n\(source) /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n" }
        guard let vocab = llama_model_get_vocab(model) else { throw NativeModelError.failed("Missing model vocabulary") }
        var tokens = [llama_token](repeating: 0, count: 2048)
        let n = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), false, true)
        guard n > 0, Int(n) + maxTokens < 2048 else { throw NativeModelError.failed("Text exceeds the selected local model context") }
        llama_memory_clear(llama_get_memory(context), true)
        let start = Date()
        for offset in stride(from: 0, to: Int(n), by: 512) {
            try Task.checkCancellation()
            let count = min(512, Int(n) - offset)
            let code = tokens.withUnsafeMutableBufferPointer { p in llama_decode(context, llama_batch_get_one(p.baseAddress!.advanced(by: offset), Int32(count))) }
            guard code == 0 else { throw NativeModelError.failed("Local model prompt evaluation failed") }
        }
        guard let sampler = llama_sampler_init_greedy() else { throw CocoaError(.coderInvalidValue) }
        defer { llama_sampler_free(sampler) }
        var data = Data(), count = 0, stopped = false
        for _ in 0..<maxTokens {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(start) < 120 else { throw NativeModelError.failed("Local model took too long. Select a smaller model or use verbatim narration.") }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { stopped = true; break }
            var piece = [CChar](repeating: 0, count: 1024)
            let size = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            guard size >= 0, size <= piece.count else { throw NativeModelError.failed("Invalid model token") }
            data.append(contentsOf: piece.prefix(Int(size)).map { UInt8(bitPattern: $0) }); count += 1
            let code = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard code == 0 else { throw NativeModelError.failed("Local model generation failed") }
        }
        return ModelGeneration(text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), model: preset.id, accelerator: accelerator, promptTokens: Int(n), generatedTokens: count, elapsedSeconds: Date().timeIntervalSince(start), stopped: stopped)
    }
}
