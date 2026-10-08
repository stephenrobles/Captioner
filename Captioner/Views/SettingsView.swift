import Speech
import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(AppUpdater.self) private var updater
    @State private var fontLibrary = FontLibrary.shared

    /// Tall enough to show a tab without scrolling on a big display, never taller than the screen;
    /// the form scrolls inside it on small ones.
    private var windowHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, screen - 110)
    }

    var body: some View {
        @Bindable var updater = updater
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("New Videos") {
                        LanguagePicker(selection: $settings.localeIdentifier, label: "Spoken language")
                        Toggle("Show punctuation", isOn: $settings.textOptions.showPunctuation)
                        Toggle("Title case", isOn: $settings.textOptions.titleCase)
                        Toggle("Show curse words", isOn: $settings.textOptions.showCurseWords)
                        Text("Speech is recognized on this Mac with Apple's on-device engine; nothing leaves your computer. A language's model downloads the first time you use it. Videos you add start with these settings and the last style you used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Updates") {
                        Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                        HStack {
                            Button("Check Now…") { updater.checkForUpdates() }
                                .disabled(!updater.canCheckForUpdates)
                            Spacer()
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Export", systemImage: "square.and.arrow.up") {
                Form {
                    Section("Export") {
                        Picker("Save exports", selection: $settings.exportLocation) {
                            ForEach(ExportLocation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if settings.exportLocation == .folder {
                            LabeledContent("Folder") {
                                HStack {
                                    Text(settings.exportFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button("Choose…") { chooseFolder() }
                                }
                            }
                        }
                        Picker("Video codec", selection: $settings.exportCodec) {
                            ForEach(ExportCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Show exported files in the Finder", isOn: $settings.revealOutputInFinder)
                        LabeledContent("Keep a caption up for") {
                            HStack {
                                Slider(value: $settings.captionHold, in: 0...3, step: 0.25)
                                Text(String(format: "%.2f s", settings.captionHold))
                                    .monospacedDigit()
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                        Text("Exports keep the original resolution, frame rate and audio, and are named “<name> Captioned.mp4”. The hold time is how long a caption stays after its last word when nothing follows it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Fonts", systemImage: "textformat") {
                Form {
                    Section("Fonts") {
                        if fontLibrary.customFonts.isEmpty {
                            Text("No font files added yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(fontLibrary.customFonts) { font in
                            HStack {
                                Text(font.displayName)
                                Spacer()
                                Button("Remove") { fontLibrary.remove(font) }
                                    .controlSize(.small)
                            }
                        }
                        Button("Add Font File…") { addFont() }
                        Text("TrueType and OpenType files are copied into Captioner and appear in the inspector's font menu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 540, height: windowHeight)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where exported videos are saved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.exportFolderPath = url.path
    }

    private func addFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try fontLibrary.add(url) } catch { NSAlert(error: error).runModal() }
        }
    }
}
