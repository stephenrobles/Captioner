import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Where the captions come from, which language they are in, and the transcription controls.
struct CaptionsSheet: View {
    @Bindable var item: CaptionItem
    @Environment(CaptionQueue.self) private var queue
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var importingSubtitles = false
    @State private var confirmRegenerate = false
    @State private var importError: String?
    @State private var shareFile: ShareFile?

    private var settings: AppSettings { AppSettings.shared }
    private var catalog: TranslationCatalog { TranslationCatalog.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    LabeledContent("Generate from") {
                        Menu {
                            Button("Video") { if item.source != .video { queue.transcribeAgain(item) } }
                            Button("Subtitle File…") { importingSubtitles = true }
                        } label: {
                            Text(item.source.title)
                                .lineLimit(1)
                        }
                    }
                    LanguagePicker(selection: $item.localeIdentifier, label: "Spoken language")
                    if item.isTranscribing {
                        HStack {
                            ProgressView()
                            Text(item.job?.status ?? "Listening…")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Cancel") { item.cancelTranscription(); queue.pumpTranscription() }
                        }
                    } else {
                        Button(item.hasCaptions ? "Generate Captions Again" : "Generate Captions") {
                            if item.hasCaptions { confirmRegenerate = true } else { queue.transcribeAgain(item) }
                        }
                        .disabled(item.status == .loading || item.status == .exporting)
                    }
                }

                Section {
                    translatePicker
                    if item.isTranslating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Translating…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = item.translationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("Translated on this device. Timing follows the original speech; choose the original language to switch back.")
                }

                Section {
                    Picker("Speakers", selection: $item.speakerMode) {
                        ForEach(SpeakerMode.choices, id: \.self) { Text($0.title).tag($0) }
                    }
                    if item.isDetectingSpeakers {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.speakerStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ProgressView(value: item.speakerProgress)
                        }
                    } else if let error = item.speakerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if item.speakerMode.isOn {
                        Button("Identify Again") { item.detectSpeakers() }
                            .disabled(!item.hasCaptions || item.status.isBusy)
                    }
                } header: {
                    Text("Speakers")
                } footer: {
                    Text(item.speakerMode.isOn && item.speakerCount > 0
                         ? "\(item.speakerCount) \(item.speakerCount == 1 ? "voice" : "voices") found. Tap a caption's dot in the list to change its speaker; the colors are in the style."
                         : "Colors each caption by voice: yellow, cyan, green and magenta for up to four speakers. Captions without a speaker keep the text color. The first time, a 22 MB speaker model is downloaded; after that it works offline.")
                }

                Section("Transcription Controls") {
                    Toggle("Show punctuation", isOn: $item.textOptions.showPunctuation)
                    Toggle("Title case", isOn: $item.textOptions.titleCase)
                    Toggle("Show curse words", isOn: $item.textOptions.showCurseWords)
                    Toggle("Hide filler words (uhm, eh)", isOn: $item.textOptions.hideFillerWords)
                }

                Section {
                    ForEach(SubtitleWriter.Format.allCases) { format in
                        Button {
                            do {
                                shareFile = ShareFile(url: try CaptionFileExport.write(item, format: format))
                            } catch {
                                importError = error.localizedDescription
                            }
                        } label: {
                            Label(format.title, systemImage: format == .txt ? "doc.text" : "captions.bubble")
                        }
                    }
                    .disabled(!item.hasCaptions || item.status.isBusy)
                } header: {
                    Text("Caption File")
                } footer: {
                    Text("Saves the captions as they are shown, into Captioner's folder in Files, and opens the share sheet.")
                }
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(url: file.url)
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { catalog.load() }
        .onChange(of: item.textOptions) { _, options in settings.textOptions = options }
        .onChange(of: item.speakerMode) { _, mode in settings.speakerMode = mode }
        .onChange(of: item.localeIdentifier) { _, identifier in
            settings.localeIdentifier = identifier
            guard item.source == .video, item.status != .loading, item.status != .exporting else { return }
            if item.hasEdits { confirmRegenerate = true } else { queue.transcribeAgain(item) }
        }
        .confirmationDialog("Generate captions again?", isPresented: $confirmRegenerate) {
            Button("Generate Again") { queue.transcribeAgain(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current captions and any edits are replaced.")
        }
        .fileImporter(isPresented: $importingSubtitles, allowedContentTypes: SubtitleImporter.types) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try item.importSubtitles(from: url)
                    queue.pumpTranscription()
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't Import Subtitles", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var translatePicker: some View {
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
        return Picker("Translate to", selection: selection) {
            Text("Original (\(LanguageCatalog.name(item.locale).components(separatedBy: " (").first ?? ""))").tag("")
            if let current = item.translation?.targetIdentifier, !catalog.targets(excluding: source).contains(where: { $0.minimalIdentifier == current }) {
                Text(TranslationCatalog.name(Locale.Language(identifier: current))).tag(current)
            }
            ForEach(catalog.targets(excluding: source), id: \.minimalIdentifier) { language in
                Text(TranslationCatalog.name(language)).tag(language.minimalIdentifier)
            }
        }
        .disabled(!item.hasCaptions || item.isTranscribing || item.isTranslating)
    }
}
