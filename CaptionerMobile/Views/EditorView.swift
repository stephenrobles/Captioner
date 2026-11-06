import SwiftUI
import UniformTypeIdentifiers

/// One video: the live preview on top, the editable caption list below, and the tools in the
/// bottom bar. The style, position and caption settings open as sheets.
struct EditorView: View {
    @Bindable var item: CaptionItem
    @Environment(CaptionQueue.self) private var queue
    @Environment(AppState.self) private var appState
    @State private var showStyle = false
    @State private var showPosition = false
    @State private var showCaptionSettings = false
    @State private var showWatermark = false
    @State private var showDebugGallery = false
    @State private var exportResult: URL?
    @State private var exportNote = ""
    @State private var confirmRegenerate = false
    @State private var shareFile: ShareFile?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var settings: AppSettings { AppSettings.shared }
    private var showTimeline: Bool { settings.showTimeline }
    private let timelineHeight: CGFloat = 112

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if sizeClass == .regular || geometry.size.width >= 600 {
                    // Wide screens (iPad, an unfolded iPhone): the video on the left, the captions beside it.
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            MobileStatusBanner(item: item)
                            MobilePreviewView(item: item)
                        }
                        .frame(width: previewWidth(for: geometry.size))
                        Divider()
                        CaptionListView(item: item)
                    }
                } else {
                    MobileStatusBanner(item: item)
                    MobilePreviewView(item: item)
                        .frame(height: previewHeight(for: geometry.size))
                    Divider()
                    CaptionListView(item: item)
                }
                if showTimeline, item.info != nil {
                    Divider()
                    CaptionTimelineView(item: item)
                        .frame(height: timelineHeight)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { showStyle = true } label: { Label("Style", systemImage: "textformat") }
                Button { showPosition = true } label: { Label("Position", systemImage: "rectangle.bottomthird.inset.filled") }
                Button { showCaptionSettings = true } label: { Label("Captions", systemImage: "captions.bubble") }
                Button { showWatermark = true } label: { Label("Watermark", systemImage: "rectangle.inset.topright.filled") }
                Button { settings.showTimeline.toggle() } label: { Label("Timeline", systemImage: "timeline.selection") }
                    .symbolVariant(showTimeline ? .fill : .none)
                Spacer()
                Button {
                    queue.export([item.id])
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!item.hasCaptions || item.status.isBusy)
            }
        }
        .sheet(isPresented: $showStyle) { StyleSheet(item: item) }
        .sheet(isPresented: $showPosition) { PositionSheet(item: item) }
        .sheet(isPresented: $showCaptionSettings) { CaptionsSheet(item: item) }
        .sheet(isPresented: $showWatermark) { WatermarkSheet(item: item) }
        #if DEBUG
        .sheet(isPresented: $showDebugGallery) { StyleGalleryView(item: item) }
        #endif
        .task(id: "\(item.id)-\(item.info == nil)") {
            let player = appState.player
            player.load(asset: item.asset, makeComposition: { item.makeComposition() }, duration: item.duration)
            item.onRenderChange = { player.refreshFrame() }
        }
        #if DEBUG
        // Development aid for App Store captures: CAPTIONER_DEBUG_SEEK=<seconds> parks the player
        // there and CAPTIONER_DEBUG_SHEET=style|position|captions|watermark opens that sheet.
        .task(id: item.info == nil) {
            guard item.info != nil else { return }
            let env = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .milliseconds(800))
            // CAPTIONER_DEBUG_STYLE=<preset id> and CAPTIONER_DEBUG_WATERMARK=/path/logo.png set the look.
            if let id = env["CAPTIONER_DEBUG_STYLE"], let preset = CaptionStyle.preset(id: id) { item.style = preset }
            if let path = env["CAPTIONER_DEBUG_WATERMARK"], let name = try? WatermarkLibrary.add(URL(fileURLWithPath: path)) {
                item.watermark.fileName = name
            }
            if let seconds = env["CAPTIONER_DEBUG_SEEK"].flatMap(Double.init) { appState.player.seek(to: seconds) }
            if let flag = env["CAPTIONER_DEBUG_TIMELINE"] { settings.showTimeline = flag != "0" }
            switch env["CAPTIONER_DEBUG_SHEET"] {
            case "style": showStyle = true
            case "position": showPosition = true
            case "captions": showCaptionSettings = true
            case "watermark": showWatermark = true
            case "gallery": showDebugGallery = true
            default: break
            }
        }
        #endif
        .onDisappear {
            appState.player.pause()
            item.onRenderChange = nil
        }
        .onChange(of: item.status) { old, new in
            if new == .exported, old == .exporting, let url = item.exportedURL {
                finishExport(url)
            }
        }
        .alert("Exported", isPresented: Binding(get: { exportResult != nil }, set: { if !$0 { exportResult = nil } })) {
            if let url = exportResult {
                Button("Share…") { shareFile = ShareFile(url: url) }
            }
            Button("Done") { exportResult = nil }
        } message: {
            Text(exportNote)
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(url: file.url)
        }
    }

    /// Side by side, the video and the captions split the width evenly.
    private func previewWidth(for size: CGSize) -> CGFloat {
        size.width / 2
    }

    /// Portrait videos get more of the screen than wide ones, and the list always keeps some room.
    private func previewHeight(for size: CGSize) -> CGFloat {
        let aspect = item.renderSize.height / max(item.renderSize.width, 1)
        let natural = size.width * aspect + 44
        let available = size.height - (showTimeline && item.info != nil ? timelineHeight : 0)
        return min(max(natural, 200), available * 0.58)
    }

    private func finishExport(_ url: URL) {
        guard settings.saveToPhotos else {
            exportNote = "\(url.lastPathComponent) is in Captioner's folder in the Files app."
            exportResult = url
            return
        }
        Task {
            do {
                try await MediaImporter.saveToPhotos(url)
                exportNote = "\(url.lastPathComponent) was added to your Photos library and kept in Captioner's folder in Files."
            } catch {
                exportNote = "\(url.lastPathComponent) is in Captioner's folder in the Files app. It couldn't be added to Photos: \(error.localizedDescription)"
            }
            exportResult = url
        }
    }
}

/// A slim bar above the preview showing what is happening to the video.
struct MobileStatusBanner: View {
    let item: CaptionItem
    @Environment(CaptionQueue.self) private var queue

    var body: some View {
        Group {
            switch item.status {
            case .loading:
                row(icon: "clock", text: "Reading video…", progress: nil)
            case .waiting:
                row(icon: "clock", text: "Waiting to generate captions…", progress: nil)
            case .transcribing:
                if let job = item.job {
                    row(icon: "waveform", text: job.phase == .downloading ? job.status : (job.liveText.isEmpty ? job.status : job.liveText),
                        progress: job.phase == .downloading ? job.downloadProgress : job.progress)
                }
            case .exporting:
                row(icon: "square.and.arrow.up", text: "Exporting…", progress: item.exportProgress)
            case .failed(let message):
                row(icon: "exclamationmark.triangle.fill", text: message, progress: nil)
            case .ready, .exported:
                if item.isTranslating {
                    row(icon: "globe", text: "Translating…", progress: nil)
                } else if item.isDetectingSpeakers {
                    row(icon: "person.2.wave.2", text: item.speakerStatus, progress: item.speakerProgress)
                }
            }
        }
        .animation(.default, value: item.status)
    }

    private func row(icon: String, text: String, progress: Double?) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Spacer()
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            if let progress {
                ProgressView(value: progress)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }
}
