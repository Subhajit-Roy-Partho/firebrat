import SwiftUI
import UniformTypeIdentifiers

/// The library is local-first: on-device books (from each manifest.json) are
/// the primary list and work fully offline. The remote catalog is a
/// best-effort section below — unreachable servers fold to a quiet offline
/// note, never an error screen. Mirrors library_screen.dart.

struct LibraryView: View {
    @EnvironmentObject var store: BookStore
    @EnvironmentObject var settings: AppSettings
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var errorMessage: String?
    @State private var pendingDelete: BookSummary?

    var body: some View {
        NavigationStack {
            List {
                if store.importInProgress {
                    HStack {
                        ProgressView()
                        Text("Importing package…").foregroundStyle(.secondary)
                    }
                }

                Section("On this device") {
                    if store.localBooks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No books yet")
                                .font(.headline)
                            Text("Download one from your server below, or import a .zip / .tar.gz package file.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(store.localBooks) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book,
                                    progress: store.downloadProgress[book.bookId])
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = book
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Available to download") {
                    if let catalog = store.catalog {
                        let remote = catalog.filter { !store.isDownloaded(bookId: $0.bookId) }
                        if remote.isEmpty {
                            Text("Everything is already on this device.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(remote) { book in
                            RemoteBookRow(
                                book: book,
                                progress: store.downloadProgress[book.bookId],
                                onDownload: { download(book) })
                        }
                    } else if store.catalogUnreachable {
                        Label("Server unreachable — showing downloaded books only.",
                              systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            ProgressView()
                            Text("Checking server…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import package file", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .navigationDestination(for: BookSummary.self) { book in
                ReaderView(bookId: book.bookId)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { SettingsView() }
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.zip, .gzip, .init(filenameExtension: "tar")].compactMap { $0 },
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await importPackage(url) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Couldn't open that file", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete this book from the device?",
                isPresented: .constant(pendingDelete != nil),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let book = pendingDelete {
                        Task { await store.deleteLocal(bookId: book.bookId) }
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .task {
                await store.refreshLocalBooks()
                await store.refreshCatalog()
            }
            .refreshable {
                await store.refreshLocalBooks()
                await store.refreshCatalog()
            }
        }
    }

    private func download(_ book: BookSummary) {
        Task {
            do {
                try await store.download(bookId: book.bookId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPackage(_ url: URL) async {
        do {
            try await store.importPackage(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct BookRow: View {
    var book: BookSummary
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline)
            HStack(spacing: 8) {
                Label("\(book.sectionCount) sections", systemImage: "list.bullet")
                Text("·")
                Text(book.totalDurationMs.formattedDuration)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RemoteBookRow: View {
    var book: BookSummary
    var progress: Double?
    var onDownload: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline)
                HStack(spacing: 8) {
                    Text("\(book.sectionCount) sections")
                    Text("·")
                    Text(book.sizeBytes.formattedBytes)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                }
            }
            Spacer()
            if progress == nil {
                Button(action: onDownload) {
                    Label("Get", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Formatting

extension Int {
    var formattedDuration: String {
        let totalSeconds = self / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    var formattedBytes: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(self))
    }
}
