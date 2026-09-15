import AVFoundation
import Combine
import Foundation

/// App-wide playback singleton driving one section's combined track, exposing
/// the currently-active segment (for highlight sync) and section-complete
/// events (for autoplay). Mirrors
/// frontend/firebrat_app/lib/services/playback_controller.dart +
/// audio_handler.dart, mapped onto Apple-native pieces:
///
/// - audio engine: AVPlayer (single instance, lives for the app session, so
///   playback survives navigation like the Flutter audio handler's player)
/// - position → segment: 100ms periodic observer + `activeAt` binary search,
///   deduped by segment_id (only changes are published)
/// - lock screen / remote commands: NowPlaying.swift
///
/// Manual seeks always work regardless of autoplay state.

@MainActor
public final class PlayerEngine: ObservableObject {
    public static let shared = PlayerEngine()

    private let player = AVPlayer()

    // MARK: Published state (drives SwiftUI)

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var activeSegment: Segment?
    @Published public private(set) var currentVisualId: String?
    @Published public private(set) var positionMs: Int = 0
    @Published public private(set) var durationMs: Int = 0
    @Published public private(set) var isLoading: Bool = false

    // MARK: Session state

    public private(set) var manifest: Manifest?
    public private(set) var sectionIndex: Int = 0
    public private(set) var segments: SegmentsFile?
    public private(set) var bookId: String?

    /// Fired when the current item plays to the end. The reader (not the
    /// engine) owns autoplay policy: delay → next section if the user hasn't
    /// navigated away meanwhile. Same split as Flutter's `_onSectionComplete`.
    public var onSectionComplete: (() -> Void)?

    public let nowPlaying = NowPlaying()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastActiveId: String?

    public var currentSection: ManifestSection? {
        guard let manifest, manifest.sections.indices.contains(sectionIndex) else { return nil }
        return manifest.sections[sectionIndex]
    }

    private init() {
        let interval = CMTime(value: 1, timescale: 10) // 100ms
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.handlePosition(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil,
            queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleItemEnded(note) }
        }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.toggle() }
        nowPlaying.onNext = { [weak self] in self?.seekToNextSegment() }
        nowPlaying.onPrevious = { [weak self] in self?.seekToPreviousSegment() }
        nowPlaying.onScrub = { [weak self] ms in self?.seek(toMs: ms) }
    }

    // MARK: - Loading

    public func openBook(_ manifest: Manifest, bookId: String) {
        self.manifest = manifest
        self.bookId = bookId
        sectionIndex = 0
    }

    /// Loads a section's audio + segments and seeds lock-screen state.
    /// `assetURL`: local file URL builder (bookId + relative path → file URL).
    public func loadSection(at index: Int, segments: SegmentsFile,
                            audioURL: URL, autoplay: Bool,
                            speed: Double) async {
        guard let manifest, manifest.sections.indices.contains(index) else { return }
        let section = manifest.sections[index]
        sectionIndex = index
        self.segments = segments
        lastActiveId = nil
        activeSegment = nil
        currentVisualId = segments.firstVisualRef()
        positionMs = 0
        durationMs = section.durationMs
        isLoading = true

        let item = AVPlayerItem(url: audioURL)
        player.replaceCurrentItem(with: item)
        player.rate = 0
        setSpeed(speed)
        nowPlaying.begin(
            title: section.title, album: manifest.title,
            durationMs: section.durationMs > 0 ? section.durationMs : nil)
        isLoading = false
        if autoplay { play() } else { publishNowPlaying() }
    }

    // MARK: - Transport

    public func play() {
        player.play()
        player.rate = defaultRate
        isPlaying = true
        publishNowPlaying()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        publishNowPlaying()
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        activeSegment = nil
        lastActiveId = nil
    }

    /// 0.75 – 2.0, persisted via AppSettings by the caller. AVPlayer has no
    /// separate "default rate", so the speed is stored and re-applied on
    /// every play() plus immediately when already playing.
    public func setSpeed(_ speed: Double) {
        defaultRate = Float(speed)
        if isPlaying { player.rate = defaultRate }
        publishNowPlaying()
    }

    private var defaultRate: Float = 1.0

    /// Absolute scrub seek (slider, lock-screen scrub).
    public func seek(toMs ms: Int) {
        let clamped = max(0, ms)
        player.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.positionMs = clamped
                self?.updateActiveSegment(ms: clamped)
                self?.publishNowPlaying()
            }
        }
    }

    /// Direct segment seek (tap-to-jump, prev/next). Works identically
    /// whether autoplay is on or off.
    public func seekToSegment(_ segment: Segment) {
        seek(toMs: segment.startMs)
    }

    public func seekToNextSegment() {
        guard let segments else { return }
        let idx: Int
        if let active = activeSegment,
           let i = segments.segments.firstIndex(where: { $0.segmentId == active.segmentId }) {
            idx = min(i + 1, segments.segments.count - 1)
        } else {
            idx = 0
        }
        seekToSegment(segments.segments[idx])
    }

    public func seekToPreviousSegment() {
        guard let segments else { return }
        let idx: Int
        if let active = activeSegment,
           let i = segments.segments.firstIndex(where: { $0.segmentId == active.segmentId }) {
            idx = max(i - 1, 0)
        } else {
            idx = 0
        }
        seekToSegment(segments.segments[idx])
    }

    // MARK: - Position → segment sync

    private func handlePosition(_ time: CMTime) {
        guard time.isValid, !time.isIndefinite else { return }
        let ms = Int(CMTimeGetSeconds(time) * 1000)
        positionMs = ms
        updateActiveSegment(ms: ms)
    }

    private func updateActiveSegment(ms: Int) {
        guard let segments else { return }
        let active = segments.activeAt(ms: ms)
        if active?.segmentId != lastActiveId {
            lastActiveId = active?.segmentId
            activeSegment = active
            if let seg = active, seg.ref != nil, seg.type.isVisual {
                currentVisualId = seg.ref
            }
            publishNowPlaying()
        }
    }

    private func handleItemEnded(_ note: Notification) {
        // Ignore endings from a stale item (section changed mid-callback).
        guard let item = player.currentItem,
              note.object as? AVPlayerItem === item else { return }
        isPlaying = false
        publishNowPlaying()
        onSectionComplete?()
    }

    // MARK: - Now Playing bridge

    /// Called by the reader when the sticky visual's artwork file changes.
    /// Art is swapped ONLY on visual-id change (cheap path, no churn).
    public func artworkURL(for visualId: String?,
                           resolve: (String) -> URL?) -> URL? {
        guard let visualId else { return nil }
        return resolve(visualId)
    }

    private func publishNowPlaying() {
        nowPlaying.update(playing: isPlaying, positionMs: positionMs,
                          durationMs: durationMs, rate: defaultRate)
    }
}
