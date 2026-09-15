import SwiftUI

/// Server URL (+ health check), playback speed, autoplay + delay, and text
/// size. All persisted under the same UserDefaults keys as the Flutter app.
/// Mirrors conversion_settings_screen.dart (server part) + the reader settings.

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var health: HealthState = .unknown
    @State private var draftURL: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Server") {
                TextField("http://localhost:8000", text: $draftURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                HStack {
                    Button("Check & save") {
                        saveAndCheck()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    healthLabel
                }
                Text("The address of your Firebrat server. On the simulator this is usually http://localhost:8000.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(settings.playbackSpeed, specifier: "%g")×")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.playbackSpeed, in: 0.75...2.0, step: 0.25)
                Toggle("Autoplay next section", isOn: $settings.autoplayEnabled)
                Stepper("Delay between sections: \(settings.autoplayDelaySeconds)s",
                        value: $settings.autoplayDelaySeconds, in: 0...10)
            }

            Section("Reading") {
                HStack {
                    Text("Text size")
                    Spacer()
                    Text("\(Int(settings.fontScale * 100))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontScale, in: 0.85...1.6, step: 0.05)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.body)
            }

            Section {
                Text("Books already on this device keep playing with no server — the library is offline-first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            draftURL = settings.serverURL.isEmpty ? AppSettings.defaultServerURL : settings.serverURL
        }
    }

    private func saveAndCheck() {
        settings.serverURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        health = .checking
        Task {
            do {
                let ok = try await settings.apiClient().checkHealth()
                health = ok ? .ok : .unreachable
            } catch {
                health = .unreachable
            }
        }
    }

    @ViewBuilder
    private var healthLabel: some View {
        switch health {
        case .unknown:
            Text("Not checked").foregroundStyle(.secondary).font(.caption)
        case .checking:
            ProgressView().scaleEffect(0.8)
        case .ok:
            Label("Reachable", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .unreachable:
            Label("Unreachable", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        }
    }

    private enum HealthState { case unknown, checking, ok, unreachable }
}
