#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import os
import UniformTypeIdentifiers

/// The videos dropped on the app, transcribed one at a time and exported one at a time.
@Observable
final class CaptionQueue {
    static let shared = CaptionQueue()

    private(set) var items: [CaptionItem] = []
    var selectedID: CaptionItem.ID?
    private(set) var exportPending: [CaptionItem.ID] = []
    private(set) var exportingItem: CaptionItem?
    private(set) var lastError: String?

    @ObservationIgnored private var transcribingItem: CaptionItem?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var batchOutputs: [URL] = []
    /// The pending exports that write the captions alone (transparent, no audio) instead of the captioned video.
    @ObservationIgnored private var captionsOnlyPending: Set<CaptionItem.ID> = []

    private var settings: AppSettings { AppSettings.shared }

    var selected: CaptionItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var isExporting: Bool { exportingItem != nil || !exportPending.isEmpty }
    var readyItems: [CaptionItem] { items.filter { $0.status == .ready || $0.status == .exported } }

    static let acceptedTypes: [UTType] = [.movie]

    nonisolated static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else {
            return false
        }
        return type.conforms(to: .movie)
    }

    // MARK: - Adding and removing

    func add(_ urls: [URL]) {
        let videos = urls.filter(Self.isVideo)
        var added: [CaptionItem] = []
        for url in videos where !items.contains(where: { $0.url == url }) {
            let item = CaptionItem(url: url, settings: settings)
            items.append(item)
            added.append(item)
        }
        if selectedID == nil { selectedID = added.first?.id }
        for item in added {
            Task {
                await item.load()
                pumpTranscription()
            }
        }
    }

    // MARK: - Watched folders

    /// Adds a video from a watched folder, or returns the queue's existing item for it.
    func addFromWatchedFolder(_ url: URL) -> CaptionItem? {
        if let existing = items.first(where: { $0.url == url }) { return existing }
        add([url])
        guard let item = items.first(where: { $0.url == url }) else { return nil }
        item.isFromWatchedFolder = true
        return item
    }

    /// Returns once `item` has captions; throws if it failed or was removed.
    func waitForCaptions(of item: CaptionItem) async throws {
        while true {
            guard items.contains(where: { $0 === item }) else { throw WatchError.removed }
            switch item.status {
            case .ready, .exported, .exporting: return
            case .failed(let message): throw WatchError.failed(message)
            case .waiting where item.source == .video && !item.isTranscribing && !item.hasCaptions:
                pumpTranscription()
            default: break
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Exports `item` and returns the file once it is written.
    func exportAndWait(_ item: CaptionItem) async throws -> URL {
        item.exportedURL = nil
        export([item.id])
        while true {
            guard items.contains(where: { $0 === item }) else { throw WatchError.removed }
            switch item.status {
            case .exported:
                if let url = item.exportedURL { return url }
            case .failed(let message):
                throw WatchError.failed(message)
            case .ready where !exportPending.contains(item.id) && exportingItem !== item:
                throw CancellationError()
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    func remove(_ ids: Set<CaptionItem.ID>) {
        for item in items where ids.contains(item.id) {
            item.cancelTranscription()
            if exportingItem === item { cancelExport() }
        }
        exportPending.removeAll { ids.contains($0) }
        captionsOnlyPending.subtract(ids)
        items.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) { self.selectedID = items.first?.id }
        pumpTranscription()
    }

    func clearError() {
        lastError = nil
    }

    func clearFinished() {
        remove(Set(items.filter { $0.status == .exported }.map(\.id)))
    }

    // MARK: - Transcription

    func pumpTranscription() {
        if let current = transcribingItem, current.isTranscribing { return }
        transcribingItem = nil
        guard let next = items.first(where: { $0.status == .waiting && $0.source == .video }) else { return }
        transcribingItem = next
        next.startTranscription { [weak self, weak next] in
            self?.transcribingItem = nil
            self?.pumpTranscription()
            #if DEBUG
            // Development aid: CAPTIONER_DEBUG_AUTOEXPORT=1 exports each video as soon as its captions are ready.
            // "2" exports twice in a row, to exercise exporting the same video again, and "captions"
            // exports the captions alone on a transparent background.
            if let mode = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_AUTOEXPORT"], ["1", "2", "captions"].contains(mode), let next, next.status == .ready {
                self?.export([next.id], captionsOnly: mode == "captions")
                if mode == "2" { self?.exportPending.append(next.id) }
            }
            #endif
        }
    }

    func transcribeAgain(_ item: CaptionItem) {
        item.cancelTranscription()
        item.source = .video
        item.status = .waiting
        if transcribingItem === item { transcribingItem = nil }
        pumpTranscription()
    }

    // MARK: - Export

    /// Queues the videos for export. `captionsOnly` writes `<name> Captions.mov` instead: the
    /// captions over a transparent background, with no audio and no watermark.
    func export(_ ids: [CaptionItem.ID], captionsOnly: Bool = false) {
        for id in ids where !exportPending.contains(id) && exportingItem?.id != id {
            if let item = items.first(where: { $0.id == id }), item.hasCaptions, !item.status.isBusy {
                exportPending.append(id)
                if captionsOnly { captionsOnlyPending.insert(id) }
            }
        }
        pumpExport()
    }

    func exportAll() {
        export(items.filter { $0.hasCaptions && !$0.status.isBusy }.map(\.id))
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportPending.removeAll()
        captionsOnlyPending.removeAll()
        if let item = exportingItem {
            item.status = item.hasCaptions ? .ready : .waiting
            item.exportProgress = 0
        }
        exportingItem = nil
    }

    private func pumpExport() {
        guard exportingItem == nil else { return }
        guard !exportPending.isEmpty else {
            #if os(macOS)
            if !batchOutputs.isEmpty, settings.revealOutputInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(batchOutputs)
            }
            #endif
            batchOutputs = []
            return
        }
        let id = exportPending.removeFirst()
        guard let item = items.first(where: { $0.id == id }) else {
            pumpExport()
            return
        }
        if item.isDetectingSpeakers {
            // The captions are about to be colored by voice; export them once they are.
            exportPending.insert(id, at: 0)
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                pumpExport()
            }
            return
        }
        let captionsOnly = captionsOnlyPending.remove(id) != nil
        guard let composition = item.exportComposition(captionsOnly: captionsOnly) else {
            pumpExport()
            return
        }
        exportingItem = item
        item.status = .exporting
        item.exportProgress = 0
        let output = VideoExporter.outputURL(for: item.url, in: settings.exportFolder, captionsOnly: captionsOnly)
        let codec = settings.exportCodec
        let captionsOnlyFormat = captionsOnly ? settings.captionsOnlyFormat : nil
        let started = Date()
        exportTask = Task {
            do {
                try await VideoExporter.export(sourceURL: item.url, composition: composition, to: output, codec: codec, captionsOnly: captionsOnlyFormat) { fraction in
                    Task { @MainActor in item.exportProgress = fraction }
                }
                item.exportedCaptionsOnly = captionsOnly
                item.exportedURL = output
                item.status = .exported
                // Watched-folder results announce themselves with a notification, not the Finder.
                if !item.isFromWatchedFolder { batchOutputs.append(output) }
                CaptionItem.log.notice("Exported \(item.name, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            } catch is CancellationError {
                item.status = .ready
            } catch {
                if Task.isCancelled {
                    item.status = .ready
                } else {
                    item.status = .failed(error.localizedDescription)
                    lastError = "\(item.name): \(error.localizedDescription)"
                }
            }
            item.exportProgress = 0
            exportingItem = nil
            exportTask = nil
            pumpExport()
        }
    }

    // MARK: - Panels

    #if os(macOS)
    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Choose one or more videos to caption."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
    #endif
}

/// Why a queued video couldn't be finished on someone's behalf (watched folders on the Mac).
nonisolated enum WatchError: LocalizedError {
    case notAVideo
    case removed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAVideo: "This isn't a video Captioner can open."
        case .removed: "The video was removed from the queue before it finished."
        case .failed(let message): message
        }
    }
}
