import SwiftUI

/// Window-level state the menus and the main view share.
@Observable
final class AppState {
    let player = PlayerController()
    var showInspector = true
    var showGallery = false
}

struct MainView: View {
    @Environment(CaptionQueue.self) private var queue
    @Environment(AppState.self) private var appState
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var queue = queue
        NavigationSplitView {
            QueueSidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            // A GeometryReader at the column root keeps the column's minimum size at zero, so the
            // content's own minimum sizes never feed back into the split view's layout.
            GeometryReader { geometry in
                Group {
                    if let item = queue.selected {
                        ItemDetailView(item: item)
                            .id(item.id)
                    } else {
                        DropZoneView(onChoose: queue.openPanel)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .inspector(isPresented: $appState.showInspector) {
            GeometryReader { geometry in
                Group {
                    if let item = queue.selected {
                        InspectorView(item: item)
                            .id(item.id)
                    } else {
                        ContentUnavailableView("No Video Selected", systemImage: "captions.bubble",
                                               description: Text("Add a video to choose its caption style."))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .inspectorColumnWidth(min: 300, ideal: 350, max: 440)
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter(CaptionQueue.isVideo)
            guard !videos.isEmpty else { return false }
            queue.add(videos)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $appState.showGallery) {
            if let item = queue.selected {
                StyleGalleryView(item: item)
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { queue.lastError != nil }, set: { if !$0 { queue.clearError() } })) {
            Button("OK") { queue.clearError() }
        } message: {
            Text(queue.lastError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { queue.openPanel() } label: {
                Label("Add Videos", systemImage: "plus")
            }
            .help("Add videos to the queue (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if queue.isExporting {
                Button { queue.cancelExport() } label: {
                    Label("Stop Export", systemImage: "stop.circle")
                }
                .help("Stop exporting")
            }
            Button { if let id = queue.selectedID { queue.export([id]) } } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!(queue.selected?.hasCaptions ?? false) || (queue.selected?.status.isBusy ?? true))
            .help("Export the selected video with captions (⌘E)")
            Button { queue.exportAll() } label: {
                Label("Export All", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(!queue.items.contains { $0.hasCaptions && !$0.status.isBusy })
            .help("Export every video that has captions (⇧⌘E)")
            Button { appState.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the caption settings (⌥⌘I)")
        }
    }
}

/// The preview and the editable caption list for one video.
struct ItemDetailView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(item: item)
            HStack(spacing: 0) {
                PreviewView(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CaptionListView(item: item)
                    .frame(width: 320)
            }
        }
        .task(id: "\(item.id)-\(item.info == nil)") {
            let player = appState.player
            player.load(asset: item.asset, makeComposition: { item.makeComposition() }, duration: item.duration)
            item.onRenderChange = { player.refreshFrame() }
        }
        .onDisappear {
            item.onRenderChange = nil
        }
    }
}

/// A slim bar above the preview showing what is happening to the video.
struct StatusBanner: View {
    let item: CaptionItem
    @Environment(CaptionQueue.self) private var queue

    var body: some View {
        Group {
            switch item.status {
            case .loading:
                row(icon: "clock", text: "Reading video…", progress: nil)
            case .waiting:
                row(icon: "clock", text: item.source == .video ? "Waiting to generate captions…" : "Choose a subtitle file in the inspector.", progress: nil)
            case .transcribing:
                if let job = item.job {
                    row(icon: "waveform", text: job.phase == .downloading ? job.status : (job.liveText.isEmpty ? job.status : job.liveText),
                        progress: job.phase == .downloading ? job.downloadProgress : job.progress) {
                        Button("Cancel") { item.cancelTranscription(); queue.pumpTranscription() }
                            .controlSize(.small)
                    }
                }
            case .exporting:
                row(icon: "square.and.arrow.up", text: "Exporting…", progress: item.exportProgress) {
                    Button("Stop") { queue.cancelExport() }
                        .controlSize(.small)
                }
            case .exported:
                row(icon: "checkmark.circle.fill", text: "Exported \(item.exportedURL?.lastPathComponent ?? "")", progress: nil) {
                    if let url = item.exportedURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .controlSize(.small)
                    }
                }
            case .failed(let message):
                row(icon: "exclamationmark.triangle.fill", text: message, progress: nil) {
                    Button("Try Again") { queue.transcribeAgain(item) }
                        .controlSize(.small)
                }
            case .ready:
                EmptyView()
            }
        }
        .animation(.default, value: item.status)
    }

    private func row<Trailing: View>(icon: String, text: String, progress: Double?, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
                trailing()
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
