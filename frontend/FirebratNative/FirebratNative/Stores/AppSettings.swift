import Combine
import Foundation

/// Playback and reading settings use familiar Flutter key names, but persist
/// independently in this app’s sandbox. No cross-app syncing is implied.

@MainActor
public final class AppSettings: ObservableObject {
    public static let keySpeed = "reader.playbackSpeed"
    public static let keyAutoplay = "reader.autoplayEnabled"
    public static let keyDelay = "reader.autoplayDelaySeconds"
    public static let keyFontScale = "reader.fontScale"
    public static let keyServerURL = "conversion.cloudServerUrl"

    /// iOS simulator default: same host as the server. (Android used
    /// 10.0.2.2; on the simulator localhost IS the Mac.)
    public static let defaultServerURL = "http://localhost:8000"

    @Published public var playbackSpeed: Double = 1.0 // 0.75 – 2.0
    @Published public var autoplayEnabled: Bool = true
    @Published public var autoplayDelaySeconds: Int = 1
    @Published public var fontScale: Double = 1.15 // 0.85 – 1.6
    @Published public var serverURL: String = ""
    @Published public var mode = "offline"
    @Published public var contentMode = "illustrated"
    @Published public var narratorVoice = ""
    @Published public var maleVoice = ""
    @Published public var femaleVoice = ""
    @Published public var characterOverrides = ""
    @Published public var compiler = "verbatim"
    @Published public var languageModel = "qwen3-1.7b"
    @Published public var useMetal = false
    @Published public var voiceEngine = "kokoro"
    @Published public var kokoroNarrator = "Bella"
    @Published public var kokoroMale = "Adam"
    @Published public var kokoroFemale = "Sarah"

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let v = defaults.object(forKey: Self.keySpeed) as? Double { playbackSpeed = v }
        if let v = defaults.object(forKey: Self.keyAutoplay) as? Bool { autoplayEnabled = v }
        if let v = defaults.object(forKey: Self.keyDelay) as? Int { autoplayDelaySeconds = v }
        if let v = defaults.object(forKey: Self.keyFontScale) as? Double { fontScale = v }
        serverURL = defaults.string(forKey: Self.keyServerURL) ?? ""

        mode = defaults.string(forKey: "conversion.mode") ?? "offline"
        contentMode = defaults.string(forKey: "conversion.contentMode") ?? "illustrated"
        narratorVoice = defaults.string(forKey: "voice.narrator") ?? ""
        maleVoice = defaults.string(forKey: "voice.male") ?? ""
        femaleVoice = defaults.string(forKey: "voice.female") ?? ""
        characterOverrides = defaults.string(forKey: "voice.overrides") ?? ""
        for (key, publisher) in [
            ("conversion.mode", $mode), ("conversion.contentMode", $contentMode),
            ("voice.narrator", $narratorVoice), ("voice.male", $maleVoice),
            ("voice.female", $femaleVoice), ("voice.overrides", $characterOverrides)] {
            publisher.sink { [defaults] in defaults.set($0, forKey: key) }.store(in: &cancellables)
        }
        compiler = defaults.string(forKey: "local.compiler") ?? "verbatim"
        languageModel = defaults.string(forKey: "local.model") ?? "qwen3-1.7b"
        useMetal = defaults.bool(forKey: "local.metal")
        for (key, publisher) in [("local.compiler", $compiler), ("local.model", $languageModel)] {
            publisher.sink { [defaults] in defaults.set($0, forKey: key) }.store(in: &cancellables)
        }
        $useMetal.sink { [defaults] in defaults.set($0, forKey: "local.metal") }.store(in: &cancellables)
        voiceEngine = defaults.string(forKey: "voice.engine") ?? "kokoro"
        kokoroNarrator = defaults.string(forKey: "kokoro.narrator") ?? "Bella"
        kokoroMale = defaults.string(forKey: "kokoro.male") ?? "Adam"
        kokoroFemale = defaults.string(forKey: "kokoro.female") ?? "Sarah"
        for (key, publisher) in [("voice.engine", $voiceEngine), ("kokoro.narrator", $kokoroNarrator), ("kokoro.male", $kokoroMale), ("kokoro.female", $kokoroFemale)] {
            publisher.sink { [defaults] in defaults.set($0, forKey: key) }.store(in: &cancellables)
        }
        // Persist on every change (debounce not needed at these volumes).
        $playbackSpeed.sink { [defaults] in defaults.set($0, forKey: Self.keySpeed) }
            .store(in: &cancellables)
        $autoplayEnabled.sink { [defaults] in defaults.set($0, forKey: Self.keyAutoplay) }
            .store(in: &cancellables)
        $autoplayDelaySeconds.sink { [defaults] in defaults.set($0, forKey: Self.keyDelay) }
            .store(in: &cancellables)
        $fontScale.sink { [defaults] in defaults.set($0, forKey: Self.keyFontScale) }
            .store(in: &cancellables)
        $serverURL.sink { [defaults] in defaults.set($0, forKey: Self.keyServerURL) }
            .store(in: &cancellables)
    }

    /// The URL actually used for all server calls: the saved value, or the
    /// simulator default on a fresh install.
    public var effectiveServerURL: String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultServerURL : trimmed
    }

    public func apiClient() throws -> APIClient {
        try APIClient(baseURLString: effectiveServerURL)
    }
}
