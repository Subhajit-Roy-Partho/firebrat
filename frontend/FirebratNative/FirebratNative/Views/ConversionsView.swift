import SwiftUI
import UniformTypeIdentifiers

struct ConversionsView: View {
    @EnvironmentObject var store: BookStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var local: LocalConversion
    @EnvironmentObject var auth: AuthStore
    @State private var jobs: [ConversionJob] = []
    @State private var importing = false
    @State private var uploading = false
    @State private var error: String?
    var body: some View {
        List {
            Section("Book type") {
                Picker("Book type", selection: $settings.contentMode) {
                    Text("Illustrated / technical").tag("illustrated")
                    Text("Novel / characters").tag("novel")
                }
            }
            if settings.mode == "offline" {
                Section { Text("Offline reading is selected. Choose Server or On this device in Settings to convert a PDF.") }
            } else {
                Section {
                    if settings.mode == "server" && auth.email.isEmpty {
                        NavigationLink("Sign in to submit conversions") { AccountView() }
                    }
                    Button { importing = true } label: {
                        Label(settings.mode == "local" ? "Convert PDF on this device" : "Upload PDF or ZIP", systemImage: "doc.badge.plus")
                    }
                    .disabled(local.running || uploading || (settings.mode == "server" && auth.email.isEmpty))
                    if uploading { ProgressView("Uploading…") }
#if DEBUG
                    if let name = ProcessInfo.processInfo.environment["FIREBRAT_TEST_PDF_NAME"] {
                        Button("Convert test PDF") {
                            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                            local.start(pdf: url, store: store, settings: settings)
                        }
                    }
#endif
                }
            }
            if local.running || !local.status.isEmpty {
                Section("On this device") {
                    Text(local.status)
                    if let note = local.reviewNote { Text(note).foregroundStyle(.orange).font(.footnote) }
                    if local.running { ProgressView(value: local.progress); Button("Cancel conversion", role: .cancel) { local.cancel() } }
                    if let error = local.error { Text(error).foregroundStyle(.red) }
                }
            }
            if settings.mode == "local" {
                Section {
                    Text("PDFKit extraction, offline Vision OCR and your selected Apple or Kokoro voice engine. Original prose is preserved. Keep this app open during conversion. Novel casting uses explicit book evidence and your voice choices.")
                    Text("Choose preserved source text or a downloaded language model in Settings. Original page layouts stay available. Local model output is checked for source coverage and marked for review; rejected rewrites retain the original text.").foregroundStyle(.secondary)
                }.font(.footnote)
            }
            if settings.mode == "server" {
                Section("Server queue") {
                    if jobs.isEmpty { Text("No conversions to display.").foregroundStyle(.secondary) }
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.title.isEmpty ? job.filename : job.title).font(.headline)
                            Text([job.state.rawValue, job.stage, job.detail].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                            if let progress = job.progress { ProgressView(value: min(1, max(0, progress))) }
                            if let error = job.error { Text(error).foregroundStyle(.red) }
                            if job.needsReviewCount > 0 { Text("\(job.needsReviewCount) sections need review").foregroundStyle(.orange) }
                            if job.isRetryable { Button("Retry conversion") { Task { await retry(job) } } }
                            if job.state == .done { Button("Download book") { Task { do { try await store.download(bookId: job.bookId) } catch { self.error = error.localizedDescription } } } }
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Conversions")
        .fileImporter(isPresented: $importing, allowedContentTypes: settings.mode == "local" ? [.pdf] : [.pdf, .zip]) { result in
            switch result {
            case .success(let url):
                if settings.mode == "local" { local.start(pdf: url, store: store, settings: settings) }
                else { Task { await upload(url) } }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .task(id: settings.mode) {
            guard settings.mode == "server" else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
            }
        }
        .refreshable { await refresh() }
    }
    private func refresh() async {
        guard !auth.email.isEmpty else { return }
        do { jobs = try await settings.apiClient().listJobs(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func upload(_ url: URL) async {
        uploading = true; error = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; uploading = false }
        do { _ = try await settings.apiClient().uploadBook(url, title: nil, contentMode: settings.contentMode); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    private func retry(_ job: ConversionJob) async {
        do { _ = try await settings.apiClient().retryJob(job.jobId); await refresh() }
        catch { self.error = error.localizedDescription }
    }
}

struct AccountView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var email = ""
    @State private var password = ""
    @State private var create = false
    var body: some View {
        Form {
            if !auth.email.isEmpty {
                Section { Text(auth.email); Button("Sign out", role: .destructive) { auth.signOut() } }
            } else {
                Section {
                    Button("Continue with Google") { Task { await auth.signInGoogle() } }.disabled(auth.busy)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    SecureField("Password", text: $password).textContentType(create ? .newPassword : .password)
                    Toggle("Create a new account", isOn: $create)
                    Button(create ? "Create account" : "Sign in") { Task { await auth.signIn(email: email, password: password, create: create) } }.disabled(auth.busy || email.isEmpty || password.isEmpty)
                    if auth.busy { ProgressView() }
                }
            }
            if let error = auth.error { Text(error).foregroundStyle(.red) }
            Section { Text("Sign-in is only required for server conversions. Downloaded books and local conversion work without an account.").font(.footnote) }
        }.navigationTitle("Account")
    }
}
