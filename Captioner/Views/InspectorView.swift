import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Caption settings for the selected video. Changes also become the defaults for new videos.
struct InspectorView: View {
    @Bindable var item: CaptionItem
    @Environment(CaptionQueue.self) private var queue
    @Environment(AppState.self) private var appState
    @State private var supportedLocales: [Locale] = []
    @State private var confirmRegenerate = false
    @State private var showPositionFor: FrameOrientation?

    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        Form {
            captionsSection
            styleSection
            positionSection
            controlsSection
        }
        .formStyle(.grouped)
        .task {
            let supported = await SpeechTranscriber.supportedLocales
            supportedLocales = supported.sorted { TranscriptionEngine.languageName($0) < TranscriptionEngine.languageName($1) }
        }
        .onChange(of: item.style) { _, style in settings.style = style }
        .onChange(of: item.placement) { _, placement in settings.placement = placement }
        .onChange(of: item.textOptions) { _, options in settings.textOptions = options }
        .onChange(of: item.localeIdentifier) { _, identifier in
            settings.localeIdentifier = identifier
            // A new language means a new transcription; edits are worth a confirmation first.
            guard item.source == .video, item.status != .loading, item.status != .exporting else { return }
            if item.hasEdits { confirmRegenerate = true } else { queue.transcribeAgain(item) }
        }
        .confirmationDialog("Generate captions again?", isPresented: $confirmRegenerate) {
            Button("Generate Again") { queue.transcribeAgain(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current captions and any edits are replaced.")
        }
    }

    // MARK: - Captions

    private var captionsSection: some View {
        Section("Captions") {
            LabeledContent("Generate from") {
                Menu {
                    Button("Video") {
                        if item.source != .video {
                            queue.transcribeAgain(item)
                        }
                    }
                    Button("Subtitle File…") { chooseSubtitles() }
                } label: {
                    Text(item.source.title)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            Picker("Spoken language", selection: $item.localeIdentifier) {
                if !supportedLocales.contains(where: { $0.identifier == item.localeIdentifier }) {
                    Text(TranscriptionEngine.languageName(item.locale)).tag(item.localeIdentifier)
                }
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(TranscriptionEngine.languageName(locale)).tag(locale.identifier)
                }
            }
            HStack {
                if item.isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.job?.status ?? "Listening…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { item.cancelTranscription(); queue.pumpTranscription() }
                } else {
                    Spacer()
                    Button(item.hasCaptions ? "Generate Captions Again" : "Generate Captions") {
                        if item.hasCaptions { confirmRegenerate = true } else { queue.transcribeAgain(item) }
                    }
                    .disabled(item.status == .loading || item.status == .exporting)
                }
            }
        }
    }

    private func chooseSubtitles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleImporter.types
        panel.message = "Choose an SRT or WebVTT file with this video's captions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try item.importSubtitles(from: url)
            queue.pumpTranscription()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Style

    private var styleSection: some View {
        Section {
            Button {
                appState.showGallery = true
            } label: {
                HStack(spacing: 12) {
                    StyleSampleView(style: item.style)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.style.name)
                            .font(.headline)
                        Text(item.style.layoutName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            StyleEditorView(style: $item.style)
            HStack {
                Spacer()
                Button("Apply to All Videos") { applyToAll() }
                    .disabled(queue.items.count < 2)
                    .help("Use this style, position and controls for every video in the queue")
            }
        } header: {
            Text("Style")
        }
    }

    private func applyToAll() {
        for other in queue.items where other !== item {
            other.style = item.style
            other.placement = item.placement
            other.textOptions = item.textOptions
        }
    }

    // MARK: - Position

    private var positionSection: some View {
        Section {
            let orientation = showPositionFor ?? item.orientation
            Picker("Frame", selection: Binding(get: { orientation }, set: { showPositionFor = $0 })) {
                ForEach(FrameOrientation.allCases, id: \.self) { o in
                    Text(o == item.orientation ? "\(o.title) (this video)" : o.title).tag(o)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let binding = Binding(get: { item.placement[orientation] }, set: { item.placement[orientation] = $0 })
            LabeledContent("Vertical") {
                HStack {
                    Slider(value: binding.vertical, in: 0.05...0.97)
                    Text("\(Int(binding.wrappedValue.vertical * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Picker("Alignment", selection: binding.alignment) {
                ForEach(CaptionAlignment.allCases, id: \.self) { alignment in
                    Image(systemName: alignment.symbolName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Side margin") {
                Slider(value: binding.horizontalInset, in: 0...0.2)
            }
            LabeledContent("Max width") {
                Slider(value: binding.maxWidth, in: 0.4...1)
            }
            HStack {
                Text("Drag the caption in the preview to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    item.placement[orientation] = orientation == .portrait ? .portraitDefault : .landscapeDefault
                }
                .controlSize(.small)
            }
        } header: {
            Text("Position")
        }
    }

    // MARK: - Transcription controls

    private var controlsSection: some View {
        Section("Transcription Controls") {
            Toggle("Show punctuation", isOn: $item.textOptions.showPunctuation)
            Toggle("Title case", isOn: $item.textOptions.titleCase)
            Toggle("Show curse words", isOn: $item.textOptions.showCurseWords)
            if item.textOptions.showCurseWords, item.job?.maskProfanity == true, item.hasCaptions {
                Text("These captions were generated with curse words hidden. Generate them again to show the words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A rendered preview of a style on a dark tile.
struct StyleSampleView: View {
    let style: CaptionStyle

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: StyleSampleRenderer.image(for: style, size: geometry.size))
                .resizable()
                .interpolation(.high)
        }
        .background(Color(red: 0.16, green: 0.165, blue: 0.18))
    }
}

/// Renders style samples for the gallery, cached by style.
enum StyleSampleRenderer {
    private struct Key: Hashable {
        let style: CaptionStyle
        let width: Int
        let height: Int
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(for style: CaptionStyle, size: CGSize) -> NSImage {
        let scale: CGFloat = 2
        let pixels = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let key = Key(style: style, width: Int(pixels.width), height: Int(pixels.height))
        if let cached = cache[key] { return cached }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        CaptionRenderer.drawSample(style, size: pixels, in: context)
        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
