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
- **Position** is kept separately for 16:9 and 9:16 frames: a vertical slider, left / center /
  right alignment, side margin and maximum width. Drag the caption in the preview to move it.
  Defaults: three quarters of the way down a portrait frame, near the bottom of a landscape one.
- **Transcription controls**: show punctuation, title case, show curse words. They apply when
  captions are drawn, so toggling them never loses an edit. With curse words hidden the engine's
  own etiquette replacements are requested as well, so generating again restores the words.
- **Generate from**: the video's audio (default) or an SRT / WebVTT file. Subtitle cues are
  split into words timed by length and regrouped to the style.
- **Editing**: the caption list beside the preview. Click a time to jump there, edit text in
  place (word timings are shared out again by length), right-click to split before a word, merge
  with the next caption or delete. "Rebuild from Transcript" regroups from the original words.
- The preview plays the video through the same compositor the export uses, so what you see is
  what you get. ⌥Space plays and pauses, ⌥⌘← / ⌥⌘→ skip 5 s.
- **Export** (⌘E, or ⇧⌘E for every video) writes `<name> Captioned.mp4` next to the original
  or into a folder chosen in Settings, at the source resolution and frame rate with the audio
  passed through. H.264 by default, HEVC optional. Rotated iPhone footage is composited upright.
- Everything runs locally. The first use of a language downloads Apple's speech model for it.

## Project notes

- Xcode 27 project, macOS 26 or later, Swift with approachable concurrency and MainActor default
  isolation. Sources live in `Captioner/` as a synchronized folder: `Model/` has the engine,
  renderer, compositor, exporter and queue; `Views/` the SwiftUI.
- The speech engine (`TranscriptionEngine`, `MediaAudioReader`) is shared with Transcriber;
  keep fixes in sync between the two apps.
- `CaptionRenderer` draws with Core Text into a Core Graphics context, bottom-left origin.
  Everything is sized relative to the font size, which is a fraction of the frame's shorter side,
  so a style looks the same at 1080p and 4K. `CaptionCompositor` is a custom `AVVideoCompositing`
  that orients the source frame with Core Image, renders the caption region to a small image
  (cached until the active word changes) and composites it. The same `AVVideoComposition` feeds
  the preview's `AVPlayerItem` and the `AVAssetExportSession`.
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
  dump; `CAPTIONER_DEBUG_AUTOEXPORT=1` exports each video as soon as its captions are ready.
  Set `exportLocation` / `exportFolderPath` with `defaults write fm.beard.Captioner …` to keep
  test exports out of the source folder.
- Engine and renderer smoke test without the UI: compile
  `Captioner/Model/{Transcript,TimeFormatting,CaptionBuilder,TextTransforms,CaptionStyle,CaptionPlacement,FontLibrary,CaptionRenderer,CaptionCompositor,VideoExporter,SubtitleImporter,MediaAudioReader,TranscriptionEngine}.swift`
  with a `main.swift` (`swiftc -default-isolation MainActor -framework AVFoundation -framework Speech -framework AppKit -framework CoreImage …`)
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
