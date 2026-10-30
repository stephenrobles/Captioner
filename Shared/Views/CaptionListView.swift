import SwiftUI

/// The captions as an editable list. Click a time to jump there; edit the text in place.
struct CaptionListView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState
    @State private var followPlayback = true
    @State private var timingCaption: Caption?

    private var player: PlayerController { appState.player }

    private var currentIndex: Int? {
        item.captions.index(at: player.currentTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captions")
                    .font(.headline)
                Spacer()
                Text("\(item.captions.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Toggle(isOn: $followPlayback) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Follow playback")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(item.captions.enumerated()), id: \.element.id) { index, caption in
                        CaptionRow(caption: caption, isCurrent: index == currentIndex, item: item,
                                   onSeek: { player.seek(to: caption.start) },
                                   onEditTiming: { timingCaption = caption })
                            .id(caption.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.plain)
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { endEditing() }
                            .fontWeight(.semibold)
                    }
                }
                #endif
                .onChange(of: currentIndex) { _, index in
                    guard followPlayback, player.isPlaying, let index, item.captions.indices.contains(index) else { return }
                    withAnimation { proxy.scrollTo(item.captions[index].id, anchor: .center) }
                }
            } .overlay {
                if item.captions.isEmpty {
                    ContentUnavailableView {
                        Label(item.isTranscribing ? "Listening…" : "No Captions Yet", systemImage: "text.bubble")
                    } description: {
                        Text(item.isTranscribing ? "Captions appear here as the speech is recognized." : "Captions are generated from the video's audio, or import a subtitle file in the inspector.")
                    }
                }
            }
            if item.hasEdits {
                Divider()
                HStack {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rebuild from Transcript") { item.rebuildCaptions() }
                        .controlSize(.small)
                        .help("Regroup the captions from the original recognition, discarding edits")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .sheet(item: $timingCaption) { caption in
            TimingEditorView(caption: caption, playhead: player.currentTime) { start, end in
                item.retime(caption.id, start: start, end: end)
            }
        }
    }
}

/// Start and end of one caption, typed or taken from the playhead.
struct TimingEditorView: View {
    let caption: Caption
    let playhead: TimeInterval
    let onSave: (TimeInterval, TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var startText = ""
    @State private var endText = ""

    private var start: TimeInterval? { TimeFormat.parse(startText) }
    private var end: TimeInterval? { TimeFormat.parse(endText) }
    private var isValid: Bool {
        guard let start, let end else { return false }
        return end > start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(caption.isBlank ? "Blank line timing" : "Timing for “\(caption.text)”")
                .font(.headline)
                .lineLimit(2)
            Grid(alignment: .leading, verticalSpacing: 10) {
                GridRow {
                    Text("Start")
                    TextField("0:00.000", text: $startText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .monospacedDigit()
                        .timeKeyboard()
                    Button("Playhead") { startText = TimeFormat.precise(playhead) }
                }
                GridRow {
                    Text("End")
                    TextField("0:00.000", text: $endText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .monospacedDigit()
                        .timeKeyboard()
                    Button("Playhead") { endText = TimeFormat.precise(playhead) }
                }
            }
            Text("Minutes, seconds and a fraction, like 0:18.4. The caption's words are spread over the new span.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let start, let end { onSave(start, end) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            startText = TimeFormat.precise(caption.start)
            endText = TimeFormat.precise(caption.end)
        }
        #if !os(macOS)
        .presentationDetents([.medium])
        #endif
    }
}

struct FormattedTextField: View {
    let title: String
    @Binding var rawValue: String
    let format: (String) -> String
    
    @FocusState private var isFocused: Bool
    
    // Custom binding that switches representation based on focus state
    private var displayBinding: Binding<String> {
        Binding(
            get: {
                isFocused ? rawValue : format(rawValue)
            },
            set: { newValue in
                guard isFocused else { return }
                rawValue = newValue
            }
        )
    }
    
    var body: some View {
        TextField(title, text: displayBinding)
            .focused($isFocused)
    }
}

struct CaptionRow: View {
    let caption: Caption
    let isCurrent: Bool
    let item: CaptionItem
    let onSeek: () -> Void
    let onEditTiming: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private func previewText (_: String) -> String {
        let transformed = TextTransforms.apply(item.textOptions, to: caption.text)
        return item.style.letterCase.apply(to: transformed)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(TimeFormat.cue(caption.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 56, alignment: .leading)
            .padding(.top, 3)
            if item.speakerMode.isOn {
                SpeakerChip(caption: caption, style: item.style) { item.setSpeaker($0, of: caption.id) }
                    .padding(.top, 1)
            }
            FormattedTextField(title: "Blank line, nothing shown", rawValue: $text, format: previewText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: caption.text) { _, new in if !focused { text = new } }
                #if os(iOS)
                // Captions are single lines: Return commits and puts the keyboard away instead of adding a line.
                .submitLabel(.done)
                .onChange(of: text) { _, new in
                    if new.contains("\n") {
                        text = new.replacingOccurrences(of: "\n", with: "")
                        focused = false
                    }
                }
                #endif
                .font(.body)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear { text = caption.text }
        .contextMenu {
            if caption.words.count > 1 {
                Menu("Split Before") {
                    ForEach(Array(caption.words.enumerated().dropFirst()), id: \.offset) { index, word in
                        Button(word.text) { item.split(caption.id, atWord: index) }
                    }
                }
            }
            Button("Merge with Next") { item.mergeWithNext(caption.id) }
                .disabled(item.captions.last?.id == caption.id)
            Button("Insert Blank Line After") { item.insertBlank(after: caption.id) }
            Button("Edit Timing…") { onEditTiming() }
            if item.speakerMode.isOn {
                Menu("Speaker") {
                    Button("No speaker") { item.setSpeaker(nil, of: caption.id) }
                    ForEach(1...CaptionStyle.maxSpeakers, id: \.self) { number in
                        Button("Speaker \(number)") { item.setSpeaker(number, of: caption.id) }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { item.delete(caption.id) }
        }
    }

    private func commit() {
        item.updateText(of: caption.id, to: text)
    }
}

#if os(iOS)
/// Resigns whatever text field has the keyboard.
@MainActor func endEditing() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

private extension View {
    /// Digits and punctuation for a time like 0:18.4 on iOS; no change on the Mac.
    @ViewBuilder func timeKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
}
