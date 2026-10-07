import AppKit
import SwiftUI

struct AppCommands: Commands {
    let updater: AppUpdater
    let queue: CaptionQueue
    let appState: AppState

    private var selected: CaptionItem? { queue.selected }
    private var player: PlayerController { appState.player }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Videos…") { queue.openPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .saveItem) {
            Button("Export Selected Video") { if let id = queue.selectedID { queue.export([id]) } }
                .keyboardShortcut("e")
                .disabled(!(selected?.hasCaptions ?? false) || (selected?.status.isBusy ?? true))
            Button("Export All") { queue.exportAll() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!queue.items.contains { $0.hasCaptions && !$0.status.isBusy })
            Divider()
            Button("Remove from Queue") { if let id = queue.selectedID { queue.remove([id]) } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(selected == nil)
        }

        CommandMenu("Captions") {
            Button("Generate Captions Again") { if let selected { queue.transcribeAgain(selected) } }
                .disabled(selected == nil || (selected?.status.isBusy ?? true))
            Button("Rebuild Captions from Transcript") { selected?.rebuildCaptions() }
                .disabled(!(selected?.hasEdits ?? false))
            Divider()
            Button("Caption Styles…") { appState.showGallery = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(selected == nil)
            Button("Apply Style to All Videos") {
                guard let selected else { return }
                for other in queue.items where other !== selected {
                    other.style = selected.style
                    other.placement = selected.placement
                    other.textOptions = selected.textOptions
                }
            }
            .disabled(selected == nil || queue.items.count < 2)
        }

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [.option])
                .disabled(!player.isLoaded)
            Button("Skip Back 5 Seconds") { player.skip(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!player.isLoaded)
            Button("Skip Forward 5 Seconds") { player.skip(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!player.isLoaded)
            Button("Go to Start") { player.seek(to: 0) }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!player.isLoaded)
        }

        CommandGroup(after: .toolbar) {
            Button(appState.showInspector ? "Hide Inspector" : "Show Inspector") { appState.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}
