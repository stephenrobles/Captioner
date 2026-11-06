import AVFoundation
import SwiftUI

/// The video as a strip: a time ruler, the captions as blocks, and frames from the video
/// underneath, all on one horizontal scroll with the playhead drawn across them. Blocks drag
/// to move a caption and their edges drag to change how long it stays up; neither can cross
/// a neighbour. Pinch (or ⌘-scroll on the Mac) zooms around the middle of the view.
struct CaptionTimelineView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState

    @State private var pointsPerSecond: CGFloat = 0
    @State private var magnifyBase: CGFloat?
    @State private var position = ScrollPosition(x: 0)
    @State private var visible = CGRect.zero
    @State private var drag: BlockDrag?
    @State private var scrubbing = false
    @State private var filmstrip = Filmstrip()
    @State private var timingCaption: Caption?

    private var player: PlayerController { appState.player }

    private static let rulerHeight: CGFloat = 20
    private static let trackHeight: CGFloat = 36
    private static let minimumDuration: TimeInterval = 0.25
    private static let snapPoints: CGFloat = 6
    private static let edgePoints: CGFloat = 10
    private static let sidePadding: CGFloat = 12
    private static let maximumPointsPerSecond: CGFloat = 400

    private var duration: TimeInterval { item.duration }
    private var contentWidth: CGFloat { CGFloat(duration) * pointsPerSecond + Self.sidePadding * 2 }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let stripHeight = max(24, height - Self.rulerHeight - Self.trackHeight)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler
                            .frame(height: Self.rulerHeight)
                        captionTrack
                            .frame(height: Self.trackHeight)
                        FilmstripView(filmstrip: filmstrip, pointsPerSecond: pointsPerSecond, visible: visible, height: stripHeight,
                                      aspect: item.renderSize.width / max(item.renderSize.height, 1), leading: Self.sidePadding)
                            .frame(height: stripHeight)
                            #if os(macOS)
                            .gesture(scrubGesture)
                            #else
                            .onTapGesture { location in seek(toX: location.x) }
                            #endif
                    }
                    playhead(height: height)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in visible = rect }
            .gesture(magnifyGesture(viewport: geometry.size.width))
            #if os(macOS)
            .overlay { CommandScrollZoomCatcher { delta in zoom(by: 1 + delta * 0.01, viewport: geometry.size.width) } }
            #endif
            .overlay(alignment: .bottomTrailing) {
                if geometry.size.width >= 600 { zoomControls(viewport: geometry.size.width) }
            }
            .onAppear { fitInitialZoom(viewport: geometry.size.width) }
            .onChange(of: duration) { _, _ in fitInitialZoom(viewport: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                if pointsPerSecond < minimumPointsPerSecond(viewport: width) { setZoom(minimumPointsPerSecond(viewport: width), viewport: width) }
            }
            .onChange(of: player.currentTime) { _, time in followPlayhead(time, viewport: geometry.size.width) }
            .onChange(of: pointsPerSecond) { _, _ in filmstrip.configure(asset: item.asset, duration: duration, pointsPerSecond: pointsPerSecond, height: stripHeight, aspect: item.renderSize.width / max(item.renderSize.height, 1)) }
            .onChange(of: visible) { _, _ in filmstrip.request(visible: visible, leading: Self.sidePadding) }
            .onChange(of: stripHeight) { _, _ in filmstrip.configure(asset: item.asset, duration: duration, pointsPerSecond: pointsPerSecond, height: stripHeight, aspect: item.renderSize.width / max(item.renderSize.height, 1)) }
        }
        .background(Color.timelineBackground)
        .clipped()
        .sheet(item: $timingCaption) { caption in
            TimingEditorView(caption: caption, playhead: player.currentTime) { start, end in
                item.retime(caption.id, start: start, end: end)
            }
        }
    }

    // MARK: - Ruler

    private var ruler: some View {
        Canvas { context, size in
            guard pointsPerSecond > 0 else { return }
            let step = rulerStep
            let first = max(0, floor(Double((visible.minX - Self.sidePadding) / pointsPerSecond) / step) * step)
            let last = min(duration, Double((visible.maxX - Self.sidePadding) / pointsPerSecond) + step)
            var time = first
            let line = GraphicsContext.Shading.color(.secondary.opacity(0.5))
            while time <= last + 0.0001 {
                let x = Self.sidePadding + CGFloat(time) * pointsPerSecond
                let isLabel = (time / step).rounded() == time / step
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (isLabel ? 7 : 4)))
                context.stroke(tick, with: line, lineWidth: 1)
                if isLabel {
                    let text = Text(step < 1 ? TimeFormat.cue(time) : TimeFormat.clock(time)).font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                    context.draw(context.resolve(text), at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                time += step / 2
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .gesture(scrubGesture)
        #else
        .highPriorityGesture(scrubGesture)
        #endif
    }

    /// The label spacing that keeps labels at least 70 points apart.
    private var rulerStep: Double {
        guard pointsPerSecond > 0 else { return 1 }
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { CGFloat($0) * pointsPerSecond >= 70 } ?? steps.last!
    }

    // MARK: - Captions

    private var captionTrack: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                #if os(macOS)
                .gesture(scrubGesture)
                #else
                .onTapGesture { location in seek(toX: location.x) }
                #endif
            ForEach(visibleCaptions, id: \.element.id) { index, caption in
                let span = draggedSpan(for: caption)
                CaptionBlock(caption: caption, start: span.start, end: span.end, pointsPerSecond: pointsPerSecond,
                             color: blockColor(for: caption), textColor: blockTextColor(for: caption), isSelected: appState.selectedCaptionID == caption.id,
                             isDragging: drag?.id == caption.id)
                    .contentShape(Rectangle())
                    .onTapGesture { select(caption) }
                    #if os(macOS)
                    .gesture(blockDrag(index: index, caption: caption))
                    #else
                    .highPriorityGesture(blockDrag(index: index, caption: caption))
                    #endif
                    .contextMenu {
                        Button("Edit Timing…") { timingCaption = caption }
                        Button("Delete Caption", role: .destructive) { delete(caption) }
                    }
                    // Last, so the gestures and the menu hit-test where the block is drawn.
                    .offset(x: Self.sidePadding + CGFloat(span.start) * pointsPerSecond, y: 3)
            }
        }
    }

    /// Only the captions that are on screen get views; the rest are a few hundred invisible rows.
    private var visibleCaptions: [(offset: Int, element: Caption)] {
        guard pointsPerSecond > 0 else { return [] }
        let from = Double((visible.minX - Self.sidePadding) / pointsPerSecond) - 1
        let to = Double((visible.maxX - Self.sidePadding) / pointsPerSecond) + 1
        return Array(item.captions.enumerated()).filter { _, caption in
            let span = draggedSpan(for: caption)
            return span.end >= from && span.start <= to
        }
    }

    private func draggedSpan(for caption: Caption) -> (start: TimeInterval, end: TimeInterval) {
        if let drag, drag.id == caption.id { return (drag.start, drag.end) }
        return (caption.start, caption.end)
    }

    private func blockColor(for caption: Caption) -> Color {
        if caption.isBlank { return Color.secondary.opacity(0.35) }
        if item.speakerMode.isOn, let speaker = caption.speaker {
            return Color(cgColor: item.style.textColor(forSpeaker: speaker).cgColor)
        }
        return .accentColor
    }

    /// White text on the accent and dark speaker colours, black on light ones like yellow.
    private func blockTextColor(for caption: Caption) -> Color {
        guard item.speakerMode.isOn, let speaker = caption.speaker else { return .white }
        let color = item.style.textColor(forSpeaker: speaker)
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.6 ? .black.opacity(0.8) : .white
    }

    private func select(_ caption: Caption) {
        appState.selectedCaptionID = caption.id
        player.pause()
        player.seek(to: caption.start)
    }

    private func delete(_ caption: Caption) {
        if appState.selectedCaptionID == caption.id { appState.selectedCaptionID = nil }
        item.delete(caption.id)
    }

    /// Moves the whole block, or one edge when the drag began within a few points of it. A
    /// block never crosses its neighbours, never gets shorter than a quarter second, and snaps
    /// to the neighbours' edges and the playhead.
    private func blockDrag(index: Int, caption: Caption) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in update(value, index: index, caption: caption) }
            .onEnded { value in
                // The last change can lag the lift, so measure once more from where the touch ended.
                update(value, index: index, caption: caption)
                guard let current = drag else { return }
                drag = nil
                if current.start != caption.start || current.end != caption.end {
                    item.retime(caption.id, start: current.start, end: current.end)
                }
            }
    }

    private func update(_ value: DragGesture.Value, index: Int, caption: Caption) {
                guard pointsPerSecond > 0 else { return }
                if drag == nil {
                    let width = CGFloat(caption.duration) * pointsPerSecond
                    let edge = min(Self.edgePoints, width / 3)
                    let mode: BlockDrag.Mode = value.startLocation.x < edge ? .leading : (value.startLocation.x > width - edge ? .trailing : .move)
                    drag = BlockDrag(id: caption.id, mode: mode, start: caption.start, end: caption.end)
                    appState.selectedCaptionID = caption.id
                    player.pause()
                }
                guard var current = drag else { return }
                let delta = TimeInterval(value.translation.width / pointsPerSecond)
                let snap = TimeInterval(Self.snapPoints / pointsPerSecond)
                let lower = index > 0 ? item.captions[index - 1].end : 0
                let upper = index + 1 < item.captions.count ? item.captions[index + 1].start : (duration > 0 ? duration : .greatestFiniteMagnitude)
                let targets = [lower, upper, player.currentTime]
                func snapped(_ time: TimeInterval) -> TimeInterval {
                    targets.first { abs($0 - time) <= snap } ?? time
                }
                switch current.mode {
                case .move:
                    let length = caption.duration
                    var start = caption.start + delta
                    if let hit = targets.first(where: { abs($0 - start) <= snap }) { start = hit }
                    else if let hit = targets.first(where: { abs($0 - (start + length)) <= snap }) { start = hit - length }
                    start = min(max(start, lower), max(lower, upper - length))
                    current.start = start
                    current.end = start + length
                case .leading:
                    let start = snapped(caption.start + delta)
                    current.start = min(max(start, lower), caption.end - Self.minimumDuration)
                case .trailing:
                    let end = snapped(caption.end + delta)
                    current.end = max(min(end, upper), caption.start + Self.minimumDuration)
                }
                drag = current
    }

    // MARK: - Playhead and scrubbing

    private func playhead(height: CGFloat) -> some View {
        let x = Self.sidePadding + CGFloat(player.currentTime) * pointsPerSecond
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.5), radius: 1)
            Triangle()
                .fill(.white)
                .frame(width: 10, height: 6)
                .shadow(color: .black.opacity(0.4), radius: 1)
        }
        .frame(width: 10, height: height, alignment: .top)
        .offset(x: x - 5)
        .allowsHitTesting(false)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if !scrubbing { scrubbing = true; player.pause() }
                seek(toX: value.location.x)
            }
            .onEnded { value in
                scrubbing = false
                seek(toX: value.location.x)
            }
    }

    private func seek(toX x: CGFloat) {
        guard pointsPerSecond > 0 else { return }
        player.seek(to: min(max(0, TimeInterval((x - Self.sidePadding) / pointsPerSecond)), duration))
    }

    /// Keeps the playhead on screen while the video plays: when it runs off the right edge the
    /// view jumps so the playhead sits a quarter of the way in, like a cutting-room timeline.
    private func followPlayhead(_ time: TimeInterval, viewport: CGFloat) {
        guard player.isPlaying, drag == nil, !scrubbing, viewport > 0, pointsPerSecond > 0 else { return }
        let x = Self.sidePadding + CGFloat(time) * pointsPerSecond
        if x > visible.maxX - 8 || x < visible.minX {
            position.scrollTo(x: max(0, x - viewport * 0.25))
        }
    }

    // MARK: - Zoom

    private func minimumPointsPerSecond(viewport: CGFloat) -> CGFloat {
        guard duration > 0 else { return 60 }
        return max(2, (viewport - Self.sidePadding * 2) / CGFloat(duration))
    }

    /// Starts close enough to read half-second captions: about ten seconds across a Mac window,
    /// five across an iPhone.
    private func fitInitialZoom(viewport: CGFloat) {
        guard viewport > 0 else { return }
        setZoom(max(80, minimumPointsPerSecond(viewport: viewport)), viewport: viewport)
    }

    /// Minus, a slider and plus for pointer-first screens; the slider runs on a log scale so
    /// each step feels the same size.
    private func zoomControls(viewport: CGFloat) -> some View {
        let minimum = minimumPointsPerSecond(viewport: viewport)
        let range = log(Self.maximumPointsPerSecond / minimum)
        let fraction = Binding<Double>(
            get: { range > 0 ? Double(log(max(pointsPerSecond, minimum) / minimum) / range) : 0 },
            set: { setZoom(minimum * exp(CGFloat($0) * range), viewport: viewport) }
        )
        return HStack(spacing: 6) {
            Button { zoom(by: 1 / 1.5, viewport: viewport) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Slider(value: fraction, in: 0...1)
                .frame(width: 100)
                .accessibilityLabel("Timeline zoom")
            Button { zoom(by: 1.5, viewport: viewport) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .controlSize(.mini)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }

    private func magnifyGesture(viewport: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = pointsPerSecond }
                guard let base = magnifyBase else { return }
                setZoom(base * value.magnification, viewport: viewport)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    private func zoom(by factor: CGFloat, viewport: CGFloat) {
        setZoom(pointsPerSecond * factor, viewport: viewport)
    }

    /// Changes the scale and keeps the time at the middle of the view where it was.
    private func setZoom(_ proposed: CGFloat, viewport: CGFloat) {
        let clamped = min(Self.maximumPointsPerSecond, max(minimumPointsPerSecond(viewport: viewport), proposed))
        guard clamped != pointsPerSecond else { return }
        let centerTime = pointsPerSecond > 0 ? (visible.midX - Self.sidePadding) / pointsPerSecond : 0
        pointsPerSecond = clamped
        let x = Self.sidePadding + centerTime * clamped - viewport / 2
        position.scrollTo(x: max(0, x))
    }
}

/// A caption being dragged: which part took the drag and where it is now.
private struct BlockDrag {
    enum Mode { case move, leading, trailing }
    let id: UUID
    let mode: Mode
    var start: TimeInterval
    var end: TimeInterval
}

private struct CaptionBlock: View {
    let caption: Caption
    let start: TimeInterval
    let end: TimeInterval
    let pointsPerSecond: CGFloat
    let color: Color
    let textColor: Color
    let isSelected: Bool
    let isDragging: Bool

    private var width: CGFloat { max(4, CGFloat(end - start) * pointsPerSecond) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(caption.isBlank ? 0.5 : 0.9))
            if caption.isBlank {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            if width > 36 {
                Text(caption.isBlank ? "Blank" : caption.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(caption.isBlank ? Color.secondary : textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(width: width - 2, alignment: .leading)
            }
            if isSelected || isDragging {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
            }
            if isDragging {
                Text("\(TimeFormat.cue(start)) – \(TimeFormat.cue(end))")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: -28)
            }
        }
        .padding(.horizontal, 1)
        .frame(width: width, height: 30)
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let edge = min(10, width / 3)
                if point.x < edge || point.x > width - edge { NSCursor.resizeLeftRight.set() } else { NSCursor.openHand.set() }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #endif
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Filmstrip

/// Frames from the video, one per slot, fetched for the part of the strip that is on screen
/// and kept for the current zoom. Zooming far enough changes the slot length and starts over.
@Observable
final class Filmstrip {
    private(set) var interval: TimeInterval = 1
    private(set) var slotWidth: CGFloat = 0
    private(set) var images: [Int: CGImage] = [:]
    private var requested: Set<Int> = []
    private var asset: AVURLAsset?
    private var duration: TimeInterval = 0
    private var pointsPerSecond: CGFloat = 0
    private var height: CGFloat = 0
    private var aspect: CGFloat = 1
    private var task: Task<Void, Never>?
    private var generation = 0

    var slotCount: Int { interval > 0 ? Int((duration / interval).rounded(.up)) : 0 }

    func configure(asset: AVURLAsset, duration: TimeInterval, pointsPerSecond: CGFloat, height: CGFloat, aspect: CGFloat) {
        guard pointsPerSecond > 0, duration > 0 else { return }
        let naturalWidth = height * aspect
        let steps: [TimeInterval] = [0.25, 0.5, 1, 2, 3, 5, 10, 15, 30, 60, 120]
        let interval = steps.first { CGFloat($0) * pointsPerSecond >= naturalWidth } ?? steps.last!
        let changed = self.asset !== asset || interval != self.interval || abs(height - self.height) > 8
        self.asset = asset
        self.duration = duration
        self.pointsPerSecond = pointsPerSecond
        self.aspect = aspect
        slotWidth = CGFloat(interval) * pointsPerSecond
        if changed {
            self.interval = interval
            self.height = height
            images = [:]
            requested = []
            task?.cancel()
            generation += 1
        }
    }

    /// Fetches the frames for the slots under `visible`, a few either side included.
    func request(visible: CGRect, leading: CGFloat) {
        guard let asset, slotWidth > 0, slotCount > 0 else { return }
        let first = max(0, Int((visible.minX - leading) / slotWidth) - 2)
        let last = min(slotCount - 1, Int((visible.maxX - leading) / slotWidth) + 2)
        guard first <= last else { return }
        let missing = (first...last).filter { !requested.contains($0) }
        guard !missing.isEmpty else { return }
        requested.formUnion(missing)
        let interval = interval
        let times = missing.map { CMTime(seconds: Double($0) * interval + interval / 2, preferredTimescale: 600) }
        let generation = generation
        let scale: CGFloat = 2
        let size = CGSize(width: (height * aspect * scale).rounded(.up), height: (height * scale).rounded(.up))
        let previous = task
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)
            for await result in generator.images(for: times) {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                if let image = try? result.image {
                    let slot = Int((result.requestedTime.seconds / interval).rounded(.down))
                    self.images[slot] = image
                }
            }
        }
    }
}

private struct FilmstripView: View {
    let filmstrip: Filmstrip
    let pointsPerSecond: CGFloat
    let visible: CGRect
    let height: CGFloat
    let aspect: CGFloat
    let leading: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.25)
            if filmstrip.slotWidth > 0 {
                let first = max(0, Int((visible.minX - leading) / filmstrip.slotWidth) - 1)
                let last = min(filmstrip.slotCount - 1, Int((visible.maxX - leading) / filmstrip.slotWidth) + 1)
                if first <= last {
                    ForEach(first...last, id: \.self) { slot in
                        Group {
                            if let image = filmstrip.images[slot] {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: filmstrip.slotWidth, height: height)
                        .clipped()
                        .offset(x: leading + CGFloat(slot) * filmstrip.slotWidth)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#if os(macOS)
/// Lets ⌘ + scroll wheel zoom the timeline. Only takes the event while ⌘ is down, so plain
/// scrolling still reaches the scroll view underneath.
private struct CommandScrollZoomCatcher: NSViewRepresentable {
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomCatcherView {
        let view = ZoomCatcherView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ZoomCatcherView, context: Context) {
        nsView.onZoom = onZoom
    }

    final class ZoomCatcherView: NSView {
        var onZoom: ((CGFloat) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSEvent.modifierFlags.contains(.command) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
            onZoom?(event.scrollingDeltaY)
        }
    }
}
#endif

extension Color {
    static var timelineBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
