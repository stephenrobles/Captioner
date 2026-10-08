import AppKit
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
    func application(_ application: NSApplication, open urls: [URL]) {
        CaptionQueue.shared.add(urls)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Development aid: CAPTIONER_DEBUG_OPEN=/path/a.mp4:/path/b.mp4 adds videos at launch without the Finder.
        if let list = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_OPEN"] {
            CaptionQueue.shared.add(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        // Development aid: CAPTIONER_SNAPSHOT=/path/to.png writes a picture of the main window a few seconds after launch.
        if let path = ProcessInfo.processInfo.environment["CAPTIONER_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["CAPTIONER_SNAPSHOT_DELAY"] ?? "") ?? 6
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
                } catch {
                    NSLog("snapshot failed: %@", String(describing: error))
                }
            }
        }
        #endif
    }
}
