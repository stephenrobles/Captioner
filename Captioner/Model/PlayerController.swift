import AVFoundation
import Combine
import Foundation
import Observation

/// Wraps an AVPlayer showing a video through its caption composition, so the preview is
/// exactly what the export will be.
@Observable
final class PlayerController {
    let player = AVPlayer()

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoaded = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusCancellable: AnyCancellable?
    @ObservationIgnored private var makeComposition: (() -> AVVideoComposition?)?
    @ObservationIgnored private var refreshScheduled = false

    init() {
        player.actionAtItemEnd = .pause
        statusCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status != .paused }
    }

    /// `makeComposition` is called again whenever a paused frame has to be repainted.
    func load(asset: AVURLAsset, makeComposition: @escaping () -> AVVideoComposition?, duration: TimeInterval) {
        unload()
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = makeComposition()
        self.makeComposition = makeComposition
        self.duration = duration
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        isLoaded = true
    }

    func unload() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        makeComposition = nil
        isLoaded = false
        currentTime = 0
        duration = 0
    }

    /// Repaints the current frame after the captions changed. While playing the next frame
    /// picks the change up anyway; paused, the player needs a nudge.
    func refreshFrame() {
        guard isLoaded, !isPlaying, !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            refreshScheduled = false
            guard let item = player.currentItem, let makeComposition else { return }
            // A new composition object makes the player render the current frame again.
            item.videoComposition = makeComposition()
        }
    }

    func togglePlayback() {
        guard isLoaded else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval, thenPlay: Bool = false) {
        guard isLoaded else { return }
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if thenPlay, !isPlaying { player.play() }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }
}
