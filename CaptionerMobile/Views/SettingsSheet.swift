import SwiftUI

struct SettingsSheet: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var fontLibrary = FontLibrary.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LanguagePicker(selection: $settings.localeIdentifier, label: "Spoken language")
                    Toggle("Show punctuation", isOn: $settings.textOptions.showPunctuation)
                    Toggle("Title case", isOn: $settings.textOptions.titleCase)
                    Toggle("Show curse words", isOn: $settings.textOptions.showCurseWords)
                } header: {
                    Text("New Videos")
                } footer: {
                    Text("Speech is recognized on this device with Apple's on-device engine; nothing leaves it. A language's model downloads the first time you use it. New videos start with these settings and your default style.")
                }

                Section {
                    HStack(spacing: 12) {
                        StyleSampleView(style: settings.defaultStyle)
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(settings.defaultStyle.name)
                                    .font(.headline)
                                DefaultBadge()
                            }
                            Text(settings.defaultStyle.layoutName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Default Style")
                } footer: {
                    Text("Change it from a video's Style sheet with “Use as Default for New Videos”.")
                }

                Section {
                    Picker("Video codec", selection: $settings.exportCodec) {
                        ForEach(ExportCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Captions-only format", selection: $settings.captionsOnlyFormat) {
                        ForEach(CaptionsOnlyFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Save exports to Photos", isOn: $settings.saveToPhotos)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Keep a caption up for")
                            Spacer()
                            Text(String(format: "%.2f s", settings.captionHold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.captionHold, in: 0...3, step: 0.25)
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Exports keep the original resolution, frame rate and audio, and are named “<name> Captioned.mp4”. They stay in Captioner's folder in the Files app, and go to Photos as well when that is on. Export Captions Only writes “<name> Captions.mov” instead: the captions alone over a transparent background, with no audio or watermark, to lay over the video in an editor. It stays in Files and is not added to Photos, so the transparency is kept. The hold time is how long a caption stays after its last word when nothing follows it.")
                }

                Section {
                    if fontLibrary.customFonts.isEmpty {
                        Text("No font files added yet. Add one from a video's Style sheet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fontLibrary.customFonts) { font in
                        HStack {
                            Text(font.displayName)
                            Spacer()
                            Button("Remove") { fontLibrary.remove(font) }
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("Fonts")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Captioner for Mac", destination: URL(string: "https://beardfm.app/captioner/")!)
                    Link("Privacy Policy", destination: URL(string: "https://beardfm.app/captioner/privacy/")!)
                    Link("Support", destination: URL(string: "mailto:steve@beard.fm")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
