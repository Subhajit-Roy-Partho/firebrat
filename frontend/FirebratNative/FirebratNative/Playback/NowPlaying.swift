import Foundation
import MediaPlayer
import UIKit

/// Lock-screen / Control-Center / headset integration for the shared player:
/// MPNowPlayingInfoCenter metadata + MPRemoteCommandCenter handlers.
///
/// Artwork rule (mirrors Flutter's `_syncLockScreenArt`): the art is swapped
/// ONLY when the current visual id changes — position ticks, play/pause and
/// seeks reuse the existing artwork object, so there's no image churn while
/// listening.

public final class NowPlaying {
    public var onTogglePlayPause: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onScrub: ((Int) -> Void)?

    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var lastArtVisualId: String?
    private var lastArtwork: MPMediaItemArtwork?

    public init() {
        wireRemoteCommands()
    }

    /// Seeds the now-playing entry for a newly-loaded section.
    public func begin(title: String, album: String, durationMs: Int?) {
        lastArtVisualId = nil
        lastArtwork = nil
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
        ]
        if let durationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        }
        center.nowPlayingInfo = info
    }

    /// Cheap tick: position/rate/playing only. Artwork untouched.
    public func update(playing: Bool, positionMs: Int, durationMs: Int, rate: Float) {
        var info = center.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0.0
        if durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        }
        center.nowPlayingInfo = info
    }

    /// Swap artwork only when the visual id actually changed. `imageURL` is
    /// the local PNG for the new visual (formula PNGs, figures, tables).
    public func setArtworkIfChanged(visualId: String?, imageURL: URL?) {
        guard visualId != lastArtVisualId else { return }
        lastArtVisualId = visualId
        guard let imageURL,
              let data = try? Data(contentsOf: imageURL),
              let image = UIImage(data: data) else {
            lastArtwork = nil
            var info = center.nowPlayingInfo ?? [:]
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            center.nowPlayingInfo = info
            return
        }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        lastArtwork = artwork
        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        center.nowPlayingInfo = info
    }

    public func clear() {
        center.nowPlayingInfo = nil
        lastArtVisualId = nil
        lastArtwork = nil
    }

    // MARK: - Remote commands (segment nav, like Flutter's skip routing)

    private func wireRemoteCommands() {
        commands.playCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?(); return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?(); return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?(); return .success
        }
        // No queue here — one section is one track — so skip buttons move
        // between segments, exactly like the Flutter handler's routing.
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?(); return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?(); return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onScrub?(Int(pos.positionTime * 1000))
            return .success
        }
    }
}
