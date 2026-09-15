import Combine
import Foundation

/// Playback + reading settings, persisted in UserDefaults under the SAME keys
/// the Flutter app uses — so switching between the two apps on one device
/// keeps speed/autoplay/font preferences in sync:
///
/// reader.playbackSpeed · reader.autoplayEnabled · reader.autoplayDelaySeconds
/// reader.fontScale · conversion.cloudServerUrl

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

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let v = defaults.object(forKey: Self.keySpeed) as? Double { playbackSpeed = v }
        if let v = defaults.object(forKey: Self.keyAutoplay) as? Bool { autoplayEnabled = v }
        if let v = defaults.object(forKey: Self.keyDelay) as? Int { autoplayDelaySeconds = v }
        if let v = defaults.object(forKey: Self.keyFontScale) as? Double { fontScale = v }
        serverURL = defaults.string(forKey: Self.keyServerURL) ?? ""

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
