import SwiftUI

struct QueueSidebarView: View {
    @Environment(CaptionQueue.self) private var queue

    var body: some View {
        @Bindable var queue = queue
        List(selection: $queue.selectedID) {
            ForEach(queue.items) { item in
                QueueRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Export") { queue.export([item.id]) }
                            .disabled(!item.hasCaptions || item.status.isBusy)
                        Button("Generate Captions Again") { queue.transcribeAgain(item) }
                            .disabled(item.status.isBusy)
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Remove from Queue") { queue.remove([item.id]) }
                    }
            }
            .onDelete { offsets in
                queue.remove(Set(offsets.map { queue.items[$0].id }))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Captioner")
        .overlay {
            if queue.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Drop videos here")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if queue.items.contains(where: { $0.status == .exported }) {
                HStack {
                    Button("Clear Exported") { queue.clearFinished() }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

struct QueueRow: View {
    let item: CaptionItem

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var progress: Double? {
        switch item.status {
        case .transcribing: item.job?.phase == .downloading ? item.job?.downloadProgress : item.job?.progress
        case .exporting: item.exportProgress
        default: nil
        }
    }

    private var subtitle: String {
        let size = item.info.map { "\(Int($0.renderSize.width))×\(Int($0.renderSize.height))" } ?? ""
        let length = item.duration > 0 ? TimeFormat.clock(item.duration) : ""
        let media = [size, length].filter { !$0.isEmpty }.joined(separator: " · ")
        switch item.status {
        case .loading: return "Reading…"
        case .waiting: return media.isEmpty ? "Waiting" : "Waiting · \(media)"
        case .transcribing: return "Generating captions…"
        case .ready: return "\(item.captions.count) captions · \(media)"
        case .exporting: return "Exporting…"
        case .exported: return "Exported"
        case .failed: return "Failed"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .loading, .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "captions.bubble")
                .foregroundStyle(Color.accentColor)
        case .exporting:
            ProgressView()
                .controlSize(.small)
        case .exported:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
