# Captioner

A Mac app that adds animated, word-by-word captions to videos. It listens to the video with
Apple's on-device speech engine (the `SpeechAnalyzer` / `SpeechTranscriber` API in macOS 26),
groups the words into short captions, lets you fix the text and pick a style, and exports a new
video file with the captions burned in.

- Drop one or more videos on the window or the Dock icon, or use File › Add Videos… (⌘O).
  Each video is transcribed as soon as it lands in the queue, one at a time.
- **Styles**: fifteen presets in a gallery (All / Monoline / Multiline / Single Word, with
  favorites; single-word styles show only the word being spoken), each
  one editable in the inspector: system sans serif, rounded, serif and monospaced fonts, any
  font installed on the Mac, or a `.ttf` / `.otf` file you add; weight, size, case, tracking;
  colors for the text, the active word, its highlight box or underline, line backgrounds,
  outline and shadow; "pop" and "words appear as spoken" animations; and how many words and
  lines go in a caption. The default style matches a white bold sans serif with a magenta box
  behind the spoken word, one line of about four words.
- **Saved styles**: after editing a style in the inspector, the bookmark button next to its name
  saves it under your own name (or updates the saved copy). Saved styles live in the gallery's
  bookmark tab and in every category. "Use as Default for New Videos" (in that menu, or by
  right-clicking a gallery tile) marks one style with a Default badge; every video you add starts
  with it. Position and transcription controls carry over from the last video you adjusted.
- **Position** is kept separately for 16:9 and 9:16 frames: a vertical slider, left / center /
  right alignment, side margin and maximum width. Drag the caption in the preview to move it.
  Defaults: three quarters of the way down a portrait frame, near the bottom of a landscape one.
- **Transcription controls**: show punctuation, title case, show curse words. They apply when
  captions are drawn, so toggling them never loses an edit. With curse words hidden the engine's
  own etiquette replacements are requested as well, so generating again restores the words.
- **Translate to**: after captions exist, pick a target language and Apple's on-device
  translation (the Translation framework) rewrites them. Captions are sent as whole sentences
  (cut at sentence punctuation and pauses), and each translated sentence is shared back over the
  captions it came from in proportion to their text, so timing and pauses follow the original
  speech. Chinese, Japanese and Thai are split into words with `NLTokenizer`. The original words
  are kept; choosing "Original" restores them, and generating again clears the translation.
- **Generate from**: the video's audio (default) or an SRT / WebVTT file. Subtitle cues are
  split into words timed by length and regrouped to the style.
- **Speakers**: with Speakers on (detect automatically, or 2, 3 or 4 voices), Captioner listens
  to the video again and labels every word with a voice, then colors each caption by speaker:
  yellow, cyan, green and magenta, editable in the style editor's Speaker colors. Unedited
  captions are regrouped so a line never spans two voices; edited ones keep their grouping and
  take the voice that covers most of the line. Each caption's dot in the list is a menu to change
  its speaker by hand. Automatic detection can miss a voice that only says a few words, so pick an
  exact count when you know it. Export waits for detection to finish.
- **Watermark**: an image (PNG with transparency works best) drawn over every frame under the
  captions, with opacity, size (a share of the frame width), margin and a nine-spot position
  grid. Images are copied into Application Support/Captioner/Watermarks; new videos start with
  the last watermark used, and Apply Style to All copies it to every video.
- **Editing**: the caption list beside the preview. Click a time to jump there, edit text in
  place (word timings are shared out again by length), right-click to split before a word, merge
  with the next caption, insert a blank line, edit the timing, or delete. A caption with no text
  is a blank line: it keeps its span and shows nothing, so the caption before it ends exactly
  when the blank starts. "Rebuild from Transcript" regroups from the original words.
- The preview plays the video through the same compositor the export uses, so what you see is
  what you get. ⌥Space plays and pauses, ⌥⌘← / ⌥⌘→ skip 5 s.
- **Watched folders** (Settings › Watched Folders): every video that arrives in a watched folder
  is added to the queue, captioned with the default style, position and controls, and exported
  with the Export settings, then announced with a notification. Files already in the folder when
  it is added are ignored; a new file is picked up once its size has stopped changing. Captioner's
  own "… Captioned" and "… Captions.mov" outputs are skipped. Open at Login starts the app without a window.
- **Caption files**: File › Save Captions As (or the inspector's Caption file menu) writes the captions
  as SubRip (.srt), WebVTT (.vtt) or plain text (.txt), with the transcription controls applied and
  blank lines left out (they become paragraph breaks in the text). `SubtitleWriter` is the shared
  writer; the Android app produces the same files.
- **Export** (⌘E, or ⇧⌘E for every video) writes `<name> Captioned.mp4` next to the original
  or into a folder chosen in Settings, at the source resolution and frame rate with the audio
  passed through. H.264 by default, HEVC optional. Rotated iPhone footage is composited upright.
- **Export Captions Only (Transparent)** (⌥⌘E, the arrow beside the toolbar's Export button, or
  the queue's context menu) writes `<name> Captions.mov` instead: only the captions, over a
  transparent background, to lay over the video in an editor. Same upright size, frame rate,
  frame times and length as the source; no audio, and no watermark even when one is on. ProRes
  4444 by default, or HEVC with alpha (Settings › Export › Captions-only format), which is also
  what a device that cannot encode ProRes 4444 falls back to. The alpha is premultiplied and
  tagged as such, and the colors are Rec. 709. It is a per-export command: watched folders keep
  producing the captioned video.
- Everything runs locally. The first use of a language downloads Apple's speech model for it.

## iPhone and iPad

The `Captioner iOS` target (`CaptionerMobile/`) is the same engine with an iPhone-first shell:
a queue list, an editor with the live preview, caption list and a bottom bar for the Style,
Position and Captions sheets, and Export. Videos come from the Photos picker, the Files picker,
or "Open in Captioner" and are copied into Documents/Imports; exports land in Documents/Exports
(visible in the Files app) and are added to Photos unless that is turned off in Settings.
Export Captions Only (Transparent), beside Export in the editor's bottom bar, writes the transparent
`<name> Captions.mov` there too; it is never added to Photos, which can re-encode a video on
its way out and drop the alpha channel, so its Exported alert only offers Share….
Return, or the Done button above the keyboard, finishes a caption edit; the context menu (long
press) has the same split, merge, blank line and timing commands as the Mac. The Captions sheet's
Caption File section writes an SRT, VTT or text file into Captioner's folder in Files and opens the
share sheet; the Exported alert's Share… button opens the share sheet for the video. On wide screens
(iPad, or an unfolded iPhone: a regular width class or at least 600 points) the editor puts the video
on the left and the caption list beside it instead of stacking them.
Watched folders, Open at Login and Sparkle are Mac-only. Translation, saved styles, fonts
(system designs, installed families, or imported files), speakers (in the Captions sheet) and the
watermark (its own sheet, with images from Photos or Files) work the same way as on the Mac.

The simulator has no on-device speech models, so transcription fails there; the debug hook
`CAPTIONER_DEBUG_SUBTITLES=/path.srt` (with `CAPTIONER_DEBUG_OPEN`) feeds captions from an SRT
instead, passed through `simctl launch` as `SIMCTL_CHILD_…` variables, and `CAPTIONER_DEBUG_EDIT=1`
opens the first video's editor right away. Everything else, including export and saving to Photos,
runs in the simulator, with one exception: on the iOS 27 simulator runtimes (27.0, 27.1 including the
iPhone Duo) every player item that carries a custom video composition fails to become ready
(AVFoundation -11800, underlying -12784), so the preview stays black there. Real iOS 27 devices
play it fine, and the iOS 26 simulators do too; it is a known Xcode 27 simulator problem
(Apple Developer Forums thread 837179). Export is unaffected because it reads through
`AVAssetReader`.

## Project notes

- Xcode 27 project, macOS 26 / iOS 26 or later, Swift with approachable concurrency and
  MainActor default isolation. `Shared/` holds everything both targets compile: the engine,
  renderer, compositor, exporter, queue, settings, and the reusable SwiftUI (gallery, style
  editor, caption list, language picker, scrubber). `Captioner/` is the Mac app and its Mac-only
  model (updater, folder watcher, login item, notifications); `CaptionerMobile/` the iOS app.
  Platform differences inside `Shared/` are small `#if os(macOS)` blocks.
- The speech engine (`TranscriptionEngine`, `MediaAudioReader`) is shared with Transcriber;
  keep fixes in sync between the two apps.
- Speaker detection is `SpeakerDetector` over the local package `Packages/SpeakerDiarization`,
  a thin wrapper around [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7
  (Apache-2.0) that pins the version, hides its API and drops its 57 MB `NemoTextProcessing`
  binary (`traits: []`). FluidAudio's offline diarizer runs Core ML conversions of pyannote's
  `speaker-diarization-community-1` models (segmentation, WeSpeaker embedding, PLDA; CC-BY-4.0:
  pyannote, WeSpeaker, BUT Speech@FIT, Fluid Inference), about 22 MB, downloaded from Hugging
  Face on first use into `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`.
  Audio is decoded to 16 kHz mono with `MediaAudioReader`; the diarizer's turns are laid over
  the transcript words in `SpeakerDetector.assign` (most overlap, else nearest within 0.75 s,
  gaps follow neighbours). Linking the package adds about 13 MB to the Mac binary. The sandboxed
  `app-store` build needs `com.apple.security.network.client` for the download.
- `WatermarkLibrary` decodes watermark images once (ImageIO thumbnail, upright, at most 2048 px)
  and `CaptionCompositor.makeWatermark` scales, fades and places them with Core Image, cached per
  settings and frame size.
- `CaptionRenderer` draws with Core Text into a Core Graphics context, bottom-left origin.
  Everything is sized relative to the font size, which is a fraction of the frame's shorter side,
  so a style looks the same at 1080p and 4K. `CaptionCompositor` is a custom `AVVideoCompositing`
  that orients the source frame with Core Image, renders the caption region to a small image
  (cached until the active word changes) and composites it. The same `AVVideoComposition` feeds
  the preview's `AVPlayerItem` and the export, where `VideoExporter` reads it through an
  `AVAssetReaderVideoCompositionOutput` and writes with `AVAssetWriter`. For a captions-only
  export the instruction's `captionsOnly` flag makes the compositor start from a clear frame
  instead of the source frame (which still drives the frame timing), leave the watermark out and
  render premultiplied alpha in Rec. 709; the exporter then writes a `.mov` with
  `AVVideoCodecType.proRes4444` or `.hevcWithAlpha`, no audio, and the source track's time scale
  (`VideoExporter.canEncode` asks VideoToolbox which of the two this device can write).
- Translation needs a `TranslationSession`, which only SwiftUI hands out: `AppState.translate`
  stores a request and `MainView`'s `.translationTask` runs it (and shows Apple's language
  download sheet when a pack is missing). `CaptionTranslator` does the sentence grouping and
  the redistribution onto the timeline.
- `FolderWatcher`, `Notifier` and `LoginItem` are shared with Transcriber (keep them in sync);
  `WatchProcessor` is Captioner's side: add to the queue, `waitForCaptions`, `exportAndWait`.
  Watched folders keep a security-scoped bookmark so the sandboxed build can read them after a
  relaunch. `CAPTIONER_DEBUG_WATCH=/folder` watches a folder for one run without saving it.
- `CaptionOverlay` is the thread-safe handoff: the main thread writes a `RenderSnapshot`
  (captions, style, placement, text options) and the compositor reads it per frame. A paused
  preview is repainted by giving the player item a new composition object.
- The window's detail and inspector columns are wrapped in a `GeometryReader` on purpose: without
  it, the transport bar's minimum size fed back into the split view and AppKit threw
  "more Update Constraints in Window passes than there are views in the window".
- `OTHER_LDFLAGS` links AVKit, AVFoundation and Speech explicitly (see Transcriber's notes on
  `VideoPlayer` aborting when only the SwiftUI overlay is linked).
- Debug-only helpers for working without a screen: `CAPTIONER_SNAPSHOT=/path.png` (with
  `CAPTIONER_SNAPSHOT_DELAY` seconds) writes a picture of the window plus a `.tree.txt` view
  dump; `CAPTIONER_DEBUG_AUTOEXPORT=1` exports each video as soon as its captions are ready (`2` exports
  it twice, `captions` exports the captions alone on a transparent background); `CAPTIONER_DEBUG_OPEN=/a.mp4:/b.mp4` adds videos at launch; `CAPTIONER_DEBUG_TRANSLATE=es`
  translates each video once its captions are ready. When testing from a shell
  while the app is also running from Xcode, kill only your own PID, never `pkill -x Captioner`.
  Set `exportLocation` / `exportFolderPath` with `defaults write fm.beard.Captioner …` to keep
  test exports out of the source folder, or pass them for one run only as launch arguments
  (`-exportLocation folder -exportFolderPath /tmp/out -captionsOnlyFormat hevcWithAlpha`).
  `CAPTIONER_DEBUG_STYLE=<preset id>` and `CAPTIONER_DEBUG_WATERMARK=/logo.png` set the selected
  video's look.
- Engine and renderer smoke test without the UI: compile
  `Shared/Model/{Transcript,TimeFormatting,CaptionBuilder,TextTransforms,CaptionStyle,CaptionPlacement,FontLibrary,CaptionRenderer,CaptionCompositor,VideoExporter,Watermark,SubtitleImporter,MediaAudioReader,TranscriptionEngine}.swift`
  with a `main.swift` (`swiftc -default-isolation MainActor -framework AVFoundation -framework Speech -framework AppKit -framework CoreImage -framework VideoToolbox …`)
  that iterates `TranscriptionEngine.transcribe`, builds captions with `CaptionBuilder`, and
  calls `VideoExporter.export` with a `timeRange` for a short clip.
- Icon: `swift Tools/make-icon.swift Captioner/Assets.xcassets/AppIcon.appiconset` regenerates
  the icon set (magenta-to-violet tile, two lines of caption bars with one word boxed).
- Branches: `main` is the direct-download build (Developer ID, hardened runtime, not sandboxed,
  Sparkle). `app-store` is the Mac App Store build: sandboxed, no Sparkle, exports go to a
  folder the user picks (kept as a security-scoped bookmark). Develop on `main` and merge into
  `app-store`; the branch only differs in the project settings, entitlements, updater and export
  location.

## Releases and updates

Updates ship through Sparkle (SPM, 2.6+). The feed is
`https://beardfm.app/captioner/appcast.xml`, kept in the beardfm.app site repo at
`site/static/captioner/appcast.xml`; DMGs live at
`site/static/downloads/Captioner-<version>.dmg` (plus `Captioner.dmg` for the
always-latest link). The EdDSA signing key is in the login keychain under the Sparkle account
`captioner`; its public key is `SUPublicEDKey` in `Info.plist`.

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares the latter) and
   optionally write `release-notes/<version>.html`.
2. `Tools/release.sh` builds, signs and packages `dist/Captioner <version>.dmg`.
   Add `--notarize` to notarize, and `--notarize --upload` to also sign the update, copy it into
   beardfm.app, add it to the appcast and deploy the site. Commit the beardfm.app changes afterwards.

## License

MIT. See [LICENSE](LICENSE).
