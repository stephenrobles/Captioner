import AVFoundation
import SwiftUI
import UIKit

/// The video with its captions composited live, plus transport controls. Dragging the caption
/// moves it; the position is remembered per orientation.
struct MobilePreviewView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState
    @State private var dragStart: CaptionPlacement?
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var player: PlayerController { appState.player }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let fitted = fittedRect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    PlayerLayerView(player: player.player)
                    #if DEBUG
                    DebugStillFrame(item: item, time: player.currentTime, frame: fitted)
                    #endif
                    captionHandle(in: fitted)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(in: fitted))
                .onTapGesture { player.togglePlayback() }
            }
            transport
        }
        // Keep the black inside the preview: a background that bled into the safe area would sit
        // behind the navigation bar and swallow its title.
        .background(Color.black, ignoresSafeAreaEdges: [])
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let size = item.renderSize
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    @ViewBuilder
    private func captionHandle(in fitted: CGRect) -> some View {
        let time = scrubbing ? scrubTime : player.currentTime
        if let block = CaptionRenderer.blockRectTopLeft(item.snapshot, time: time, size: item.renderSize), item.renderSize.width > 0 {
            let scale = fitted.width / item.renderSize.width
            let rect = CGRect(x: fitted.minX + block.minX * scale, y: fitted.minY + block.minY * scale,
                              width: max(block.width * scale, 40), height: max(block.height * scale, 20))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white.opacity(dragStart != nil ? 0.85 : 0.35))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(in fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let orientation = item.orientation
                if dragStart == nil { dragStart = item.placement[orientation] }
                guard let start = dragStart, fitted.height > 0 else { return }
                var placement = start
                placement.vertical = min(0.98, max(0.02, start.vertical + value.translation.height / fitted.height))
                let x = (value.location.x - fitted.minX) / fitted.width
                if x < 0.3 { placement.alignment = .leading }
                else if x > 0.7 { placement.alignment = .trailing }
                else { placement.alignment = .center }
                item.placement[orientation] = placement
            }
            .onEnded { _ in
                dragStart = nil
                AppSettings.shared.placement = item.placement
            }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!player.isLoaded)
            Text(TimeFormat.clock(scrubbing ? scrubTime : player.currentTime))
                .monospacedDigit()
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .trailing)
            ScrubberView(duration: player.duration, time: scrubbing ? scrubTime : player.currentTime) { time, ended in
                scrubTime = time
                if !ended {
                    if !scrubbing { player.pause() }
                    scrubbing = true
                } else {
                    scrubbing = false
                }
                player.seek(to: time)
            }
            .disabled(!player.isLoaded)
            Text(TimeFormat.clock(player.duration))
                .monospacedDigit()
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black, ignoresSafeAreaEdges: [])
    }
}

/// An AVPlayerLayer in a plain view: no built-in controls, so the caption handle lines up exactly.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { nil }
}

#if DEBUG
/// Development aid for App Store captures on simulators whose players can't draw a custom
/// composition: CAPTIONER_DEBUG_STILL=1 draws the current frame, captions and watermark included,
/// through the same composition the export uses.
private struct DebugStillFrame: View {
    let item: CaptionItem
    let time: TimeInterval
    let frame: CGRect
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(time)-\(item.captions.count)-\(item.watermark.hashValue)-\(item.style.hashValue)-\(item.speakerCount)") {
            guard ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_STILL"] != nil,
                  let composition = item.makeComposition() else { return }
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            do {
                image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            } catch {
                print("debug still failed: \(error)")
            }
        }
    }
}
#endif
