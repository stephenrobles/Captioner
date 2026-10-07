import AppKit
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

    func remove(_ ids: Set<CaptionItem.ID>) {
        for item in items where ids.contains(item.id) {
            item.cancelTranscription()
            if exportingItem === item { cancelExport() }
        }
        exportPending.removeAll { ids.contains($0) }
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
            if ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_AUTOEXPORT"] == "1", let next, next.status == .ready {
                self?.export([next.id])
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

    func export(_ ids: [CaptionItem.ID]) {
        for id in ids where !exportPending.contains(id) && exportingItem?.id != id {
            if let item = items.first(where: { $0.id == id }), item.hasCaptions, !item.status.isBusy {
                exportPending.append(id)
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
        if let item = exportingItem {
            item.status = item.hasCaptions ? .ready : .waiting
            item.exportProgress = 0
        }
        exportingItem = nil
    }

    private func pumpExport() {
        guard exportingItem == nil else { return }
        guard !exportPending.isEmpty else {
            if !batchOutputs.isEmpty, settings.revealOutputInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(batchOutputs)
            }
            batchOutputs = []
            return
        }
        let id = exportPending.removeFirst()
        guard let item = items.first(where: { $0.id == id }), let composition = item.exportComposition() else {
            pumpExport()
            return
        }
        exportingItem = item
        item.status = .exporting
        item.exportProgress = 0
        let output = VideoExporter.outputURL(for: item.url, in: settings.exportFolder)
        let codec = settings.exportCodec
        let started = Date()
        exportTask = Task {
            do {
                try await VideoExporter.export(asset: item.asset, composition: composition, to: output, codec: codec) { fraction in
                    Task { @MainActor in item.exportProgress = fraction }
                }
                item.exportedURL = output
                item.status = .exported
                batchOutputs.append(output)
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

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Choose one or more videos to caption."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
}
