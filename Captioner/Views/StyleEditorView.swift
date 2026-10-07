import SwiftUI
import UniformTypeIdentifiers

/// Fonts, sizes and colors for the current style. Editing keeps the preset's name; pick a
/// preset in the gallery to start over.
struct StyleEditorView: View {
    @Binding var style: CaptionStyle
    @State private var fontLibrary = FontLibrary.shared
    @State private var showAllFonts = false

    var body: some View {
        Group {
            fontRow
            Picker("Weight", selection: $style.weight) {
                ForEach(FontWeight.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Size") {
                Slider(value: $style.sizeScale, in: 0.025...0.1)
            }
            Picker("Case", selection: $style.letterCase) {
                ForEach(LetterCase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Tracking") {
                Slider(value: $style.letterSpacing, in: -0.05...0.15)
            }

            colorRow("Text", $style.textColor)
            Picker("Active word", selection: $style.highlight) {
                ForEach(HighlightKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if style.highlight != .none {
                colorRow("Active text", $style.activeTextColor)
            }
            if style.highlight == .box || style.highlight == .underline {
                colorRow(style.highlight == .box ? "Highlight box" : "Underline", $style.highlightColor)
            }
            Toggle("Pop the active word", isOn: $style.popActiveWord)
            Toggle("Show only the spoken word", isOn: $style.singleWord)
            if !style.singleWord {
                Toggle("Words appear as spoken", isOn: $style.progressiveReveal)
            }

            Toggle("Background behind lines", isOn: $style.lineBackground)
            if style.lineBackground {
                colorRow("Background", $style.lineBackgroundColor)
            }
            if style.lineBackground || style.highlight == .box {
                LabeledContent("Corner radius") {
                    Slider(value: $style.cornerRadius, in: 0...0.6)
                }
            }
            LabeledContent("Outline") {
                Slider(value: $style.strokeWidth, in: 0...0.16)
            }
            if style.strokeWidth > 0 {
                colorRow("Outline color", $style.strokeColor)
            }
            LabeledContent("Shadow") {
                Slider(value: $style.shadowRadius, in: 0...0.4)
            }
            if style.shadowRadius > 0 {
                LabeledContent("Shadow opacity") {
                    Slider(value: $style.shadowOpacity, in: 0...1)
                }
                colorRow("Shadow color", $style.shadowColor)
            }

            if !style.singleWord {
                Stepper("Lines per caption: \(style.grouping.maxLines)", value: $style.grouping.maxLines, in: 1...3)
                Stepper("Words per line: \(style.grouping.maxWordsPerLine)", value: $style.grouping.maxWordsPerLine, in: 1...10)
                Stepper("Characters per line: \(style.grouping.maxCharactersPerLine)", value: $style.grouping.maxCharactersPerLine, in: 8...48)
                LabeledContent("Line spacing") {
                    Slider(value: $style.lineSpacing, in: 0...0.6)
                }
            }
        }
    }

    private var fontRow: some View {
        Picker("Font", selection: $style.font) {
            Section("System") {
                ForEach(FontDesign.allCases, id: \.self) { design in
                    Text(design.title).tag(FontChoice.system(design))
                }
            }
            if !fontLibrary.customFonts.isEmpty {
                Section("Added Fonts") {
                    ForEach(fontLibrary.customFonts) { font in
                        Text(font.displayName).tag(FontChoice.custom(fileName: font.fileName))
                    }
                }
            }
            if case .installed(let family) = style.font, !showAllFonts {
                Section("Installed") {
                    Text(family).tag(FontChoice.installed(family: family))
                }
            }
            if showAllFonts {
                Section("Installed") {
                    ForEach(fontLibrary.installedFamilies, id: \.self) { family in
                        Text(family).tag(FontChoice.installed(family: family))
                    }
                }
            }
            Section {
                Text(showAllFonts ? "Hide Installed Fonts" : "Installed Fonts…").tag(FontChoice.installed(family: "__toggle__"))
                Text("Add Font File…").tag(FontChoice.custom(fileName: "__add__"))
            }
        }
        .onChange(of: style.font) { old, new in
            switch new {
            case .installed(let family) where family == "__toggle__":
                showAllFonts.toggle()
                style.font = old
            case .custom(let fileName) where fileName == "__add__":
                style.font = old
                addFontFile()
            default:
                break
            }
        }
    }

    private func addFontFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.font]
        panel.message = "Choose a TrueType or OpenType font file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let font = try fontLibrary.add(url)
            style.font = .custom(fileName: font.fileName)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func colorRow(_ title: String, _ color: Binding<RGBAColor>) -> some View {
        ColorPicker(title, selection: Binding(get: { color.wrappedValue.cgColor }, set: { color.wrappedValue = RGBAColor(cgColor: $0) }),
                    supportsOpacity: true)
    }
}
