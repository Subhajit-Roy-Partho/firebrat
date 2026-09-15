import SwiftUI

/// FirebratNative — Apple-native SwiftUI MVP. Library is the root; the reader
/// pushes onto the stack; settings presents as a sheet. The shared
/// PlayerEngine singleton outlives every view so playback (and lock-screen
/// controls) survive navigation.
///
/// M3-seed-like indigo theme, adapted to iOS: the seed color
/// (0xFF4F6BFF, same as the Flutter app) drives the tint, SF Symbols
/// throughout, system Dynamic Type + dark mode for free.

@main
struct FirebratNativeApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store: BookStore
    private var engine = PlayerEngine.shared

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: BookStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(Color.firebratSeed)
                .environmentObject(settings)
                .environmentObject(store)
        }
    }
}

extension Color {
    /// M3 seed 0xFF4F6BFF shared with the Flutter app.
    static let firebratSeed = Color(red: 0x4F / 255.0,
                                    green: 0x6B / 255.0,
                                    blue: 1.0)
}
