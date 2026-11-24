import AVFAudio
import SwiftUI

@main
struct CaptionerMobileApp: App {
    @State private var queue = CaptionQueue.shared
    @State private var appState = AppState()

    init() {
        _ = FontLibrary.shared
        // The preview is a video player: it should be heard with the ring/silent switch on silent,
        // and not duck or be muted by the default ambient session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(queue)
                .environment(appState)
                .onOpenURL { url in
                    queue.add(MediaImporter.importFiles([url]))
                }
                .task {
                    #if DEBUG
                    // Development aid: CAPTIONER_DEBUG_OPEN=/path/a.mp4:/path/b.mp4 adds videos at launch.
                    if let list = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_OPEN"] {
                        queue.add(MediaImporter.importFiles(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }))
                        // CAPTIONER_DEBUG_SUBTITLES=/path.srt feeds captions to the first video, since the
                        // simulator has no speech models.
                        if let srt = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_SUBTITLES"], let item = queue.items.first {
                            while item.status == .loading { try? await Task.sleep(for: .milliseconds(200)) }
                            try? item.importSubtitles(from: URL(fileURLWithPath: srt))
                            queue.pumpTranscription()
                            // CAPTIONER_DEBUG_AUTOEXPORT then exports it as it would after a transcription
                            // ("captions" for the captions alone on a transparent background).
                            if let mode = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_AUTOEXPORT"], item.hasCaptions {
                                queue.export([item.id], captionsOnly: mode == "captions")
                            }
                        }
                    }
                    #endif
                }
        }
    }
}
