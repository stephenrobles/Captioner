import Speech
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Caption settings for the selected video. Changes also become the defaults for new videos.
struct InspectorView: View {
    @Bindable var item: CaptionItem
    @Environment(CaptionQueue.self) private var queue
    @Environment(AppState.self) private var appState
    @State private var confirmRegenerate = false
    @State private var showPositionFor: FrameOrientation?
    @State private var watermarkError: String?

    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        Form {
            captionsSection
            speakersSection
            styleSection
            positionSection
            watermarkSection
            controlsSection
        }
        .formStyle(.grouped)
        .onChange(of: item.placement) { _, placement in settings.placement = placement }
        .onChange(of: item.textOptions) { _, options in settings.textOptions = options }
        .onChange(of: item.watermark) { _, watermark in settings.watermark = watermark }
        .onChange(of: item.speakerMode) { _, mode in settings.speakerMode = mode }
        .alert("Couldn't Use Image", isPresented: Binding(get: { watermarkError != nil }, set: { if !$0 { watermarkError = nil } })) {
            Button("OK") { watermarkError = nil }
        } message: {
            Text(watermarkError ?? "")
        }
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
            LanguagePicker(selection: $item.localeIdentifier, label: "Spoken language")
            translateRow
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
            LabeledContent("Caption file") {
                Menu("Save As…") {
                    ForEach(SubtitleWriter.Format.allCases) { format in
                        Button(format.title) { CaptionFileExport.save(item, format: format) }
                    }
                }
                .fixedSize()
                .disabled(!item.hasCaptions || item.status.isBusy)
            }
        }
    }

    /// Translating swaps the captions for Apple's on-device translation of the speech; picking
    /// the original language puts them back.
    private var translateRow: some View {
        let catalog = TranslationCatalog.shared
        let source = item.locale.language
        let selection = Binding<String>(
            get: { item.translation?.targetIdentifier ?? "" },
            set: { identifier in
                if identifier.isEmpty {
                    item.revertTranslation()
                } else {
                    appState.translate(item, to: Locale.Language(identifier: identifier))
                }
            })
        return Group {
            Picker("Translate to", selection: selection) {
                Text("Original (\(LanguageCatalog.name(item.locale).components(separatedBy: " (").first ?? ""))").tag("")
                if let current = item.translation?.targetIdentifier, !catalog.targets(excluding: source).contains(where: { $0.minimalIdentifier == current }) {
                    Text(TranslationCatalog.name(Locale.Language(identifier: current))).tag(current)
                }
                Divider()
                ForEach(catalog.targets(excluding: source), id: \.minimalIdentifier) { language in
                    Text(TranslationCatalog.name(language)).tag(language.minimalIdentifier)
                }
            }
            .disabled(!item.hasCaptions || item.isTranscribing || item.isTranslating)
            .onAppear { catalog.load() }
            if item.isTranslating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = item.translationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if item.translation != nil {
                Text("Translated on this Mac. Timing follows the original speech; edits to the text are kept until you translate again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Speakers

    private var speakersSection: some View {
        Section {
            Picker("Speakers", selection: $item.speakerMode) {
                ForEach(SpeakerMode.choices, id: \.self) { Text($0.title).tag($0) }
            }
            if item.isDetectingSpeakers {
                HStack(spacing: 8) {
                    ProgressView(value: item.speakerProgress)
                        .controlSize(.small)
                    Text("\(item.speakerStatus) \(Int(item.speakerProgress * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            } else if let error = item.speakerError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if item.speakerMode.isOn {
                HStack {
                    Text(item.speakerCount > 0 ? "\(item.speakerCount) \(item.speakerCount == 1 ? "voice" : "voices") found. Each caption's dot in the list changes its speaker; the colors are in the style."
                         : "Captions are colored by who is speaking once the video is transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Identify Again") { item.detectSpeakers() }
                        .controlSize(.small)
                        .disabled(!item.hasCaptions || item.status.isBusy)
                }
            } else {
                Text("Colors each caption by voice: yellow, cyan, green and magenta for up to four speakers. A voiceover or narrator with no speaker keeps the text color. The first time, a 22 MB speaker model is downloaded; after that it works offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Speakers")
        }
    }

    // MARK: - Watermark

    private var watermarkSection: some View {
        Section {
            HStack(spacing: 12) {
                WatermarkThumbnail(fileName: item.watermark.fileName)
                VStack(alignment: .leading, spacing: 6) {
                    Button(item.watermark.isEnabled ? "Change Image…" : "Choose Image…") { chooseWatermark() }
                    if item.watermark.isEnabled {
                        Button("Remove") { removeWatermark() }
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            WatermarkControls(settings: $item.watermark)
            Text("A logo or handle drawn over every frame, under the captions. PNGs with transparency work best. New videos start with this watermark.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Watermark")
        }
    }

    private func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WatermarkLibrary.supportedTypes
        panel.message = "Choose an image to draw over the video."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let previous = item.watermark.fileName
            item.watermark.fileName = try WatermarkLibrary.add(url)
            if let previous { forgetWatermarkFile(previous) }
        } catch {
            watermarkError = error.localizedDescription
        }
    }

    private func removeWatermark() {
        guard let fileName = item.watermark.fileName else { return }
        item.watermark.fileName = nil
        forgetWatermarkFile(fileName)
    }

    /// Deletes a watermark image once no video in the queue uses it any more.
    private func forgetWatermarkFile(_ fileName: String) {
        guard !queue.items.contains(where: { $0.watermark.fileName == fileName }) else { return }
        WatermarkLibrary.remove(fileName)
    }

    // MARK: - Style

    private var styleSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    appState.showGallery = true
                } label: {
                    HStack(spacing: 12) {
                        StyleSampleView(style: item.style)
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.style.name)
                                    .font(.headline)
                                if settings.isDefault(item.style) {
                                    DefaultBadge()
                                }
                            }
                            Text(styleSubtitle)
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
                bookmarkMenu
            }
            StyleEditorView(style: $item.style)
            HStack {
                Spacer()
                Button("Apply to All Videos") { applyToAll() }
                    .disabled(queue.items.count < 2)
                    .help("Use this style, position, speakers, watermark and controls for every video in the queue")
            }
        } header: {
            Text("Style")
        }
    }

    private var styleSubtitle: String {
        var parts = [item.style.layoutName]
        if settings.isSavedStyle(item.style.id) { parts.append("saved") }
        if settings.isEdited(item.style) { parts.append("edited") }
        return parts.joined(separator: " · ")
    }

    /// Bookmarking keeps the current fonts, colors and options as a saved style; the default
    /// is what every new video starts with.
    private var bookmarkMenu: some View {
        Menu {
            Button("Save as New Style…") { saveAsNewStyle() }
            if settings.isSavedStyle(item.style.id) {
                Button("Update “\(settings.baseStyle(for: item.style.id)?.name ?? item.style.name)”") {
                    settings.updateSavedStyle(item.style)
                }
                .disabled(!settings.isEdited(item.style))
            }
            Divider()
            if settings.isDefault(item.style) {
                Label("Default for New Videos", systemImage: "checkmark")
            } else {
                Button("Use as Default for New Videos") { settings.defaultStyle = item.style }
            }
        } label: {
            Image(systemName: settings.isSavedStyle(item.style.id) && !settings.isEdited(item.style) ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save this style, or make it the default for new videos")
    }

    private func saveAsNewStyle() {
        let suggestion = settings.isSavedStyle(item.style.id) ? item.style.name + " copy" : item.style.name + " (Custom)"
        guard let name = NamePrompt.run(title: "Save Style", message: "Name this style. It appears in the gallery under Saved.", defaultValue: suggestion) else { return }
        let saved = settings.saveStyle(item.style, name: name)
        item.style = saved
    }

    private func applyToAll() {
        for other in queue.items where other !== item {
            other.style = item.style
            other.placement = item.placement
            other.textOptions = item.textOptions
            other.watermark = item.watermark
            other.speakerMode = item.speakerMode
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
            Toggle("Hide filler words (uhm, eh)", isOn: $item.textOptions.hideFillerWords)
            if item.textOptions.showCurseWords, item.job?.maskProfanity == true, item.hasCaptions {
                Text("These captions were generated with curse words hidden. Generate them again to show the words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// An alert with a text field, for naming things.
enum NamePrompt {
    static func run(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultValue : name
    }
}
