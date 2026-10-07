import AVFoundation
import AVKit
import SwiftUI

/// The video with its captions composited live, plus transport controls. Dragging the caption
/// moves it; the position is remembered per orientation.
struct PreviewView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState
    @State private var dragStart: CaptionPlacement?
    @State private var hovering = false
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
                    captionHandle(in: fitted)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(in: fitted))
                .onHover { hovering = $0 }
            }
            transport
        }
        .background(Color.black)
    }

    // MARK: - Caption handle

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
                .foregroundStyle(.white.opacity(hovering || dragStart != nil ? 0.85 : 0))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    private func dragGesture(in fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let orientation = item.orientation
                if dragStart == nil { dragStart = item.placement[orientation] }
                guard let start = dragStart, fitted.height > 0 else { return }
                var placement = start
                placement.vertical = min(0.98, max(0.02, start.vertical + value.translation.height / fitted.height))
                // Sliding sideways past a third of the frame changes the alignment.
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

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(!player.isLoaded)
            .help("Play or pause (⌥Space)")
            Text(TimeFormat.clock(scrubbing ? scrubTime : player.currentTime))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 48, alignment: .trailing)
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A scrubber drawn in SwiftUI. Reports the time under the pointer while dragging and once more
/// with `ended` when the drag finishes.
struct ScrubberView: View {
    let duration: TimeInterval
    let time: TimeInterval
    let onScrub: (TimeInterval, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, width * fraction), height: 4)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, width * fraction - 6))
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub(timeAt(value.location.x, width: width), false) }
                    .onEnded { value in onScrub(timeAt(value.location.x, width: width), true) }
            )
        }
        .frame(height: 20)
    }

    private func timeAt(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(duration, max(0, Double(x / width) * duration))
    }
}

/// An AVPlayerLayer in a plain view: no built-in controls, so the caption handle lines up exactly.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
