# iPhone Duo screenshots (inner display, 2853 × 2007)

Five shots for the App Store `APP_IPHONE_DUO` slot, which earns the "Made for iPhone Duo"
badge. Framed like Kan Do's and Stash's sets: the whole device in Apple's Duo frame under a
centered white SF Bold headline, here on Captioner's magenta-to-violet icon gradient. Raw
captures are in `raw/` (taken on the real inner display of the shared "iPhone Duo" simulator,
D65DCFDC…, unfolded flat in Device Hub, with `INNER=1 SIM=D65DCFDC-E39E-47E6-9F1C-4F485D1D9D56`); the
earlier status-bar-less Resizable captures are in `raw/resizable/`. Composed shots sit beside this
file. First used on iOS 1.2.1 (8).

| Shot | Video (BT Shorts) | Seek | Look | Headline |
|---|---|---|---|---|
| 01-editor | iPhone Duo Split Apps | 2.6 | Highlight | Captions that follow every word. |
| 02-side-by-side | iPhone Duo Action Control | 4.3 | `STYLE=headline` | Your video and captions, side by side. |
| 03-styles | iPhone Duo Action Control | 2.0 | sheet `gallery` | Fifteen styles to start from. |
| 04-watermark | iPhone Duo Apple Pay | 6.2 | `WATERMARK=` Bearded Teacher Logo YT, trimmed | Your logo on every frame. |
| 05-dark | iPhone Duo App - Sequel | 1.9 | `STYLE=boxed`, dark appearance | Dark mode. All on device. |

## Recipe

1. **Captions.** The simulator has no speech models, so transcribe on the Mac with the app's own
   engine into a one-word-per-cue SRT (the importer keeps real word timings that way):
   `swiftc -O -default-isolation MainActor -framework AVFoundation -framework Speech -framework AppKit -framework Accelerate Shared/Model/Transcript.swift Shared/Model/MediaAudioReader.swift Shared/Model/TranscriptionEngine.swift Shared/Model/LanguageCatalog.swift Marketing/duo-tools/wordsrt-stubs.swift Marketing/duo-tools/wordsrt.swift -o wordsrt`,
   then `./wordsrt video.mp4 video.srt`. Fix brand words by hand (Duo, Split View, Sequel, Touch ID).
2. **Simulator.** "iPhone Duo (Captioner)" (EDC71188-CED7-47BD-93C0-8056DD3A7F77, iOS 27.1, the only
   runtime with the Duo). Build the Debug "Captioner iOS" scheme for it and install;
   `simctl status_bar … override --time 9:41`.
3. **Capture.** `Marketing/duo-tools/capture-duo.sh raw/NN.png <media folder> "<video>" <seek> [sheet]`.
   It uses DEBUG-only launch hooks in the iOS app: `CAPTIONER_DEBUG_SEEK`, `_SHEET`, `_STYLE`,
   `_WATERMARK` (EditorView) and `CAPTIONER_DEBUG_STILL` (MobilePreviewView), which draws the
   current frame through the export composition because iOS 27.0/27.1 simulator players can't
   draw a custom composition. The fold can't be scripted, so the app is moved to a hidden
   951 × 669 pt "Resizable" display with `devicectl device appResize`; that capture has the
   inner display's exact size and layout but no status bar. For a status bar, unfold the
   simulator in Device Hub and capture with `simctl io <udid> screenshot --display=primary-1`.
4. **Compose.** `swiftc -O Marketing/compose-duo-frame.swift -o Marketing/compose-duo`, then
   `Marketing/compose-duo 2853 2007 raw/NN.png NN.png "Headline"`. The bezel and Apple's license
   are in `Marketing/Bezels/` (copied from Kan Do).
