import SwiftUI
import AVFoundation

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
            Section("Conversion") {
                Picker("Mode", selection: $settings.mode) {
                    Text("Offline reading").tag("offline")
                    Text("Server").tag("server")
                    Text("On this device").tag("local")
                }
                Picker("Book type", selection: $settings.contentMode) {
                    Text("Illustrated / technical").tag("illustrated")
                    Text("Novel / characters").tag("novel")
                }
                NavigationLink("Convert a book") { ConversionsView() }
            }
            if settings.mode == "server" { Section("Server") {
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

            }
            if settings.mode == "local" {
                Section("Narration preparation") {
                    Picker("Narration preparation", selection: $settings.compiler) {
                        Text("Preserve source text").tag("verbatim")
                        Text("Local language model").tag("llm")
                    }
                    if settings.compiler == "llm" {
                        Picker("Language model", selection: $settings.languageModel) {
                            ForEach(NativeModel.catalog) { model in Text("\(model.name) · \(model.bytes / 1_000_000) MB").tag(model.id) }
                        }
#if targetEnvironment(simulator)
                        Toggle("Use Metal GPU when available", isOn: $settings.useMetal).disabled(true)
                        Text("Simulator conversions use CPU. Metal requires testing on a physical Apple device.").font(.footnote)
#else
                        Toggle("Use Metal GPU when available", isOn: $settings.useMetal)
#endif
                        Text("Models download once and then run offline. CPU is the default; Metal is optional on physical Apple devices. Narration retains the source if a rewrite fails coverage checks. Review model-generated narration before relying on it.").font(.footnote)
                    }
                }
                Section("Voice engine") {
                    Picker("Voice engine", selection: $settings.voiceEngine) {
                        Text("Apple installed voices").tag("apple")
                        Text("Kokoro neural voices").tag("kokoro")
                    }
                }
                if settings.voiceEngine == "kokoro" {
                    Section("Kokoro offline voices") {
                        Picker("Narrator", selection: $settings.kokoroNarrator) {
                            ForEach(KokoroRuntime.female + KokoroRuntime.male, id: \.self) { Text($0 + (KokoroRuntime.male.contains($0) ? " · Male" : " · Female")).tag($0) }
                        }
                        Picker("Male characters", selection: $settings.kokoroMale) { ForEach(KokoroRuntime.male, id: \.self) { Text($0).tag($0) } }
                        Picker("Female characters", selection: $settings.kokoroFemale) { ForEach(KokoroRuntime.female, id: \.self) { Text($0).tag($0) } }
                        TextField("Alice=Sarah, one override per line", text: $settings.characterOverrides, axis: .vertical).lineLimit(3...6)
                        Text("One verified download (about 103 MB) on first use, then neural narration works offline. Ambiguous characters keep the narrator. No voice cloning.").font(.footnote)
                    }
                } else { Section("Apple offline voices") {
                    voicePicker("Narrator", selection: $settings.narratorVoice, gender: nil)
                    voicePicker("Male characters", selection: $settings.maleVoice, gender: .male)
                    voicePicker("Female characters", selection: $settings.femaleVoice, gender: .female)
                    TextField("Name=Apple voice name, one per line", text: $settings.characterOverrides, axis: .vertical).lineLimit(3...6)
                    Text("Only installed English Apple voices are listed. For novels, explicit roles or clear he/she narration select a voice; unknown characters keep the narrator. Named overrides take priority. Download more voices in Apple Spoken Content settings.").font(.footnote)
                }
            }
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

    private func voicePicker(_ title: String, selection: Binding<String>, gender: AVSpeechSynthesisVoiceGender?) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic / narrator fallback").tag("")
            ForEach(LocalConversion.voices.filter { gender == nil || $0.gender == gender }, id: \.identifier) { voice in
                Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
            }
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
