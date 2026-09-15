import SwiftUI

/// The reader: sticky visual header (formula PNG first, then figures/tables),
/// section navigation, segment list with live highlight + tap-to-seek, and the
/// playback bar. The FocusMode split is folded in — the sticky header IS the
/// focus visual (see README). Mirrors reader_screen.dart + reader_providers.dart.

struct ReaderView: View {
    var bookId: String
    @EnvironmentObject var store: BookStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var session: ReaderSession
    @ObservedObject private var engine = PlayerEngine.shared

    init(bookId: String) {
        self.bookId = bookId
        _session = StateObject(wrappedValue: ReaderSession(bookId: bookId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let manifest = session.manifest,
               let section = session.currentSection {
                // Sticky visual header — always on screen, never scrolled away.
                VisualHeader(visual: session.currentVisual,
                             sectionTitle: section.title,
                             bookDir: session.bookDir)
                .background(Color(.secondarySystemBackground))

                // Section navigator.
                SectionNavBar(
                    title: section.title,
                    index: session.sectionIndex,
                    count: manifest.sections.count,
                    onPrevious: { session.go(to: session.sectionIndex - 1) },
                    onNext: { session.go(to: session.sectionIndex + 1) },
                    onPick: { session.go(to: $0) },
                    sections: manifest.sections)

                Divider()

                // Segment list with live highlight.
                if session.isLoading {
                    Spacer()
                    ProgressView("Loading section…")
                    Spacer()
                } else if let segments = session.segments {
                    SegmentList(segments: segments,
                                activeId: engine.activeSegment?.segmentId,
                                fontScale: settings.fontScale,
                                onTap: { engine.seekToSegment($0) })
                }
            } else if let error = session.loadError {
                Spacer()
                ContentUnavailableView("Couldn't open this book",
                                       systemImage: "book.closed",
                                       description: Text(error))
                Spacer()
            } else {
                Spacer()
                ProgressView("Opening book…")
                Spacer()
            }

            Divider()
            PlaybackBar()
        }
        .navigationTitle(session.manifest?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            session.configure(store: store, settings: settings, engine: engine)
            await session.open()
        }
    }
}

// MARK: - Session (owns manifest/section/segments; engine owns audio)

@MainActor
final class ReaderSession: ObservableObject {
    let bookId: String
    @Published var manifest: Manifest?
    @Published var sectionIndex: Int = 0
    @Published var segments: SegmentsFile?
    @Published var isLoading: Bool = false
    @Published var loadError: String?

    var bookDir: URL?
    private var store: BookStore?
    private var settings: AppSettings?
    private var engine: PlayerEngine?
    /// Asset URLs for the CURRENT section only: ref id → local file URL.
    private var assetURLs: [String: URL] = [:]
    private var autoplayTask: Task<Void, Never>?

    init(bookId: String) { self.bookId = bookId }

    func configure(store: BookStore, settings: AppSettings, engine: PlayerEngine) {
        self.store = store
        self.settings = settings
        self.engine = engine
    }

    var currentSection: ManifestSection? {
        guard let manifest, manifest.sections.indices.contains(sectionIndex) else { return nil }
        return manifest.sections[sectionIndex]
    }

    /// The image that should be on screen right now: the last figure/table/
    /// formula spoken about (sticky across prose), falling back to the first
    /// visual in reading order when a section loads.
    var currentVisual: VisualItem? {
        guard let manifest, let engine else { return nil }
        let id = engine.currentVisualId ?? segments?.firstVisualRef()
        guard let id, let url = assetURLs[id] else { return nil }
        if let fig = manifest.figure(id: id) {
            return VisualItem(id: id, kind: .figure, imageURL: url, caption: fig.caption)
        }
        if let tbl = manifest.table(id: id) {
            return VisualItem(id: id, kind: .table, imageURL: url, caption: tbl.caption)
        }
        if let formula = manifest.formula(id: id) {
            return VisualItem(id: id, kind: .formula, imageURL: url,
                              caption: formula.spokenText, latex: formula.latex)
        }
        return nil
    }

    func open() async {
        guard let store else { return }
        do {
            manifest = try store.loadManifest(bookId: bookId)
            bookDir = try store.bookDirectory(bookId: bookId)
            engine?.openBook(manifest!, bookId: bookId)
            wireCompletion()
            await loadSection(0, autoplay: false)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func go(to index: Int) {
        guard let manifest, manifest.sections.indices.contains(index) else { return }
        autoplayTask?.cancel()
        autoplayTask = nil
        let wasPlaying = engine?.isPlaying ?? false
        Task { await loadSection(index, autoplay: wasPlaying) }
    }

    private func loadSection(_ index: Int, autoplay: Bool) async {
        guard let store, let engine, let settings, let manifest,
              manifest.sections.indices.contains(index) else { return }
        isLoading = true
        sectionIndex = index
        segments = nil
        do {
            let section = manifest.sections[index]
            let segs = try store.loadSegments(bookId: bookId, section: section)
            segments = segs
            assetURLs = resolveAssets(section: section, manifest: manifest)
            let audioURL = try store.assetURL(bookId: bookId, relativePath: section.audioPath)
            await engine.loadSection(at: index, segments: segs, audioURL: audioURL,
                                     autoplay: autoplay, speed: settings.playbackSpeed)
            syncArtwork()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func resolveAssets(section: ManifestSection, manifest: Manifest) -> [String: URL] {
        var out: [String: URL] = [:]
        for id in section.figureRefs {
            if let f = manifest.figure(id: id),
               let url = try? store?.assetURL(bookId: bookId, relativePath: f.imagePath) {
                out[id] = url
            }
        }
        for id in section.tableRefs {
            if let t = manifest.table(id: id),
               let url = try? store?.assetURL(bookId: bookId, relativePath: t.imagePath) {
                out[id] = url
            }
        }
        for id in section.formulaRefs {
            if let f = manifest.formula(id: id),
               let url = try? store?.assetURL(bookId: bookId, relativePath: f.imagePath) {
                out[id] = url
            }
        }
        return out
    }

    /// Lock-screen art follows the sticky visual (art swaps only on id change).
    func syncArtwork() {
        guard let engine else { return }
        let id = engine.currentVisualId ?? segments?.firstVisualRef()
        let url = engine.artworkURL(for: id) { self.assetURLs[$0] }
        engine.nowPlaying.setArtworkIfChanged(visualId: id, imageURL: url)
    }

    private func wireCompletion() {
        engine?.onSectionComplete = { [weak self] in
            Task { @MainActor in self?.sectionCompleted() }
        }
    }

    /// Autoplay policy (mirrors Flutter `_onSectionComplete`): honor the
    /// toggle + delay, and only continue if the user hasn't navigated away.
    private func sectionCompleted() {
        guard let settings, let manifest, let engine else { return }
        guard settings.autoplayEnabled else { return }
        guard sectionIndex < manifest.sections.count - 1 else { return }
        let fromIndex = sectionIndex
        let delay = settings.autoplayDelaySeconds
        autoplayTask?.cancel()
        autoplayTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            guard !Task.isCancelled, self.sectionIndex == fromIndex else { return }
            await self.loadSection(fromIndex + 1, autoplay: true)
            _ = engine
        }
    }
}

// MARK: - Visual model + sticky header (formula PNG primary)

struct VisualItem: Equatable {
    enum Kind { case figure, formula, table }
    var id: String
    var kind: Kind
    var imageURL: URL
    var caption: String
    var latex: String?
}

private struct VisualHeader: View {
    var visual: VisualItem?
    var sectionTitle: String
    var bookDir: URL?

    var body: some View {
        Group {
            if let visual {
                HStack(alignment: .center, spacing: 12) {
                    VisualImage(visual: visual)
                        .frame(maxWidth: 220, maxHeight: 150)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(visual.kindLabel, systemImage: visual.kindSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        if !visual.caption.isEmpty {
                            Text(visual.caption)
                                .font(.subheadline)
                                .lineLimit(4)
                        }
                        if visual.kind == .formula, let latex = visual.latex, !latex.isEmpty {
                            Text(latex)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                HStack {
                    Image(systemName: "text.book.closed")
                        .foregroundStyle(.secondary)
                    Text(sectionTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct VisualImage: View {
    var visual: VisualItem

    var body: some View {
        Group {
#if os(iOS)
            if let data = try? Data(contentsOf: visual.imageURL),
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VisualPlaceholder(kind: visual.kind)
            }
#else
            VisualPlaceholder(kind: visual.kind)
#endif
        }
    }
}

private struct VisualPlaceholder: View {
    var kind: VisualItem.Kind
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: kind == .formula ? "function" : kind == .figure ? "photo" : "tablecells")
                    .foregroundStyle(.secondary)
            }
    }
}

private extension VisualItem {
    var kindLabel: String {
        switch kind {
        case .figure: return "Figure"
        case .formula: return "Formula"
        case .table: return "Table"
        }
    }

    var kindSymbol: String {
        switch kind {
        case .figure: return "photo"
        case .formula: return "function"
        case .table: return "tablecells"
        }
    }
}

// MARK: - Section nav

private struct SectionNavBar: View {
    var title: String
    var index: Int
    var count: Int
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onPick: (Int) -> Void
    var sections: [ManifestSection]

    var body: some View {
        HStack {
            Button(action: onPrevious) {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(index <= 0)

            Spacer()

            Menu {
                ForEach(sections.indices, id: \.self) { i in
                    Button {
                        onPick(i)
                    } label: {
                        Label(sections[i].title, systemImage: i == index ? "checkmark" : "list.bullet")
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("Section \(index + 1) of \(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onNext) {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(index >= count - 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Segment list

private struct SegmentList: View {
    var segments: SegmentsFile
    var activeId: String?
    var fontScale: Double
    var onTap: (Segment) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(segments.segments) { segment in
                SegmentRow(segment: segment,
                           isActive: segment.segmentId == activeId,
                           fontScale: fontScale)
                .id(segment.segmentId)
                .listRowBackground(segment.segmentId == activeId
                    ? Color.accentColor.opacity(0.12) : Color.clear)
                .onTapGesture { onTap(segment) }
            }
            .listStyle(.plain)
            .onChange(of: activeId) { _, newId in
                if let newId {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct SegmentRow: View {
    var segment: Segment
    var isActive: Bool
    var fontScale: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: segment.type.symbolName)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(segment.text)
                .font(scaledBody)
                .fontWeight(segment.type == .heading ? .bold : .regular)
                .foregroundStyle(isActive ? .primary : .primary)
        }
        .padding(.vertical, 2)
    }

    /// Respects both Dynamic Type and the in-app font scale (dyslexia-friendly
    /// sizing, same intent as Flutter's fontScale).
    private var scaledBody: Font {
        let base: CGFloat = segment.type == .heading ? 19 : 17
#if os(iOS)
        let ui = UIFontMetrics.default.scaledFont(
            for: UIFont.systemFont(ofSize: base * fontScale,
                                   weight: segment.type == .heading ? .bold : .regular))
        return Font(ui)
#else
        return segment.type == .heading ? .headline : .body
#endif
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    @ObservedObject private var engine = PlayerEngine.shared
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            // Scrub slider.
            HStack(spacing: 8) {
                Text(msLabel(engine.positionMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(engine.positionMs) },
                    set: { engine.seek(toMs: Int($0)) }
                ), in: 0...max(1, Double(engine.durationMs)))
                Text(msLabel(engine.durationMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Button { engine.seekToPreviousSegment() } label: {
                    Label("Previous segment", systemImage: "backward.end.fill")
                }
                Button { engine.toggle() } label: {
                    Label(engine.isPlaying ? "Pause" : "Play",
                          systemImage: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                Button { engine.seekToNextSegment() } label: {
                    Label("Next segment", systemImage: "forward.end.fill")
                }

                Spacer()

                // Speed, persisted to the shared UserDefaults key.
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                        Button {
                            settings.playbackSpeed = speed
                            engine.setSpeed(speed)
                        } label: {
                            Label("\(speed, specifier: "%g")×",
                                  systemImage: settings.playbackSpeed == speed ? "checkmark" : "gauge")
                        }
                    }
                } label: {
                    Text("\(settings.playbackSpeed, specifier: "%g")×")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                .onChange(of: settings.playbackSpeed) { _, v in engine.setSpeed(v) }
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func msLabel(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
