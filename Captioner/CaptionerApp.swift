import AppKit
import AVFoundation
import SwiftUI

@main
struct CaptionerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var updater = AppUpdater()
    @State private var queue = CaptionQueue.shared
    @State private var appState = AppState()

    init() {
        _ = FontLibrary.shared
    }

    var body: some Scene {
        Window("Captioner", id: "main") {
            MainView()
                .environment(updater)
                .environment(queue)
                .environment(appState)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            AppCommands(updater: updater, queue: queue, appState: appState)
        }

        Settings {
            SettingsView()
                .environment(updater)
        }
        .windowResizability(.contentSize)
    }
}

/// Receives videos opened from the Finder, the Dock icon, or `open -a Captioner file.mp4`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginItem.launchEventIsLoginItem
        Notifier.install()
        FolderWatcher.shared.configure(accepts: WatchProcessor.accepts, process: WatchProcessor.caption)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        CaptionQueue.shared.add(urls)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// Closing the window quits, unless folders are being watched.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !FolderWatcher.shared.isWatching && CaptionQueue.shared.items.isEmpty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LoginItem.launchEventIsLoginItem { launchedAtLogin = true }
        if launchedAtLogin {
            // Started by the system at login to watch folders: stay out of the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for window in NSApp.windows where window.isVisible { window.close() }
            }
        }
        #if DEBUG
        // Development aid: CAPTIONER_DEBUG_OPEN=/path/a.mp4:/path/b.mp4 adds videos at launch without the Finder.
        if let list = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_OPEN"] {
            CaptionQueue.shared.add(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        // Development aid: CAPTIONER_SNAPSHOT=/path/to.png writes a picture of the main window a few seconds after launch.
        if let path = ProcessInfo.processInfo.environment["CAPTIONER_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["CAPTIONER_SNAPSHOT_DELAY"] ?? "") ?? 6
            // CAPTIONER_SNAPSHOT_SIZE=1440x900 sizes the window first; CAPTIONER_SNAPSHOT_SIDEBAR=hidden collapses the sidebar.
            if let size = ProcessInfo.processInfo.environment["CAPTIONER_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                        var frame = window.frame
                        frame.size = NSSize(width: size[0], height: size[1])
                        window.setFrame(frame, display: true)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSLog("snapshot: %d windows: %@", NSApp.windows.count, NSApp.windows.map { "\($0.title) visible=\($0.isVisible) \($0.frame)" })
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = window.contentView?.superview ?? window.contentView else { NSLog("snapshot: no window"); return }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSLog("snapshot: no rep"); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSLog("snapshot: wrote %@", path)
                    if let tree = view.perform(NSSelectorFromString("_subtreeDescription"))?.takeUnretainedValue() as? String {
                        try? tree.write(toFile: path + ".tree.txt", atomically: true, encoding: .utf8)
                    }
                    // The player layer doesn't draw into the snapshot, so also write the composited frame
                    // at CAPTIONER_DEBUG_SEEK (default half a second) for pasting into the preview area.
                    if let item = CaptionQueue.shared.selected, let composition = item.makeComposition() {
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                        generator.videoComposition = composition
                        generator.requestedTimeToleranceBefore = .zero
                        generator.requestedTimeToleranceAfter = .zero
                        if let frame = try? generator.copyCGImage(at: CMTime(seconds: Double(ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_SEEK"] ?? "") ?? 0.5, preferredTimescale: 600), actualTime: nil) {
                            let rep = NSBitmapImageRep(cgImage: frame)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".frame.png"))
                        }
                    }
                } catch {
                    NSLog("snapshot failed: %@", String(describing: error))
                }
            }
        }
        #endif
    }
}
