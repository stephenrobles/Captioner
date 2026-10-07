import SwiftUI

/// The style picker: saved and bookmarked styles, all, monoline, multiline and single-word tabs
/// over a grid of samples. Right-click a style to make it the default, rename or delete it.
struct StyleGalleryView: View {
    @Bindable var item: CaptionItem
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .all
    @State private var settings = AppSettings.shared

    enum Tab: Hashable {
        case saved, all, monoline, multiline, singleWord
    }

    private func matches(_ style: CaptionStyle) -> Bool {
        switch tab {
        case .saved, .all: true
        case .monoline: !style.isMultiline && !style.singleWord
        case .multiline: style.isMultiline
        case .singleWord: style.singleWord
        }
    }

    private var savedStyles: [CaptionStyle] {
        settings.savedStyles.filter(matches)
    }

    private var presets: [CaptionStyle] {
        let all = tab == .saved ? CaptionStyle.presets.filter { settings.favoriteStyleIDs.contains($0.id) } : CaptionStyle.presets
        return all.filter(matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Caption Styles")
                    .font(.title3.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .hidden()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Picker("", selection: $tab) {
                Image(systemName: "bookmark").tag(Tab.saved)
                Text("All").tag(Tab.all)
                Text("Monoline").tag(Tab.monoline)
                Text("Multiline").tag(Tab.multiline)
                Text("Single Word").tag(Tab.singleWord)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                if savedStyles.isEmpty, presets.isEmpty {
                    ContentUnavailableView("Nothing Saved Yet", systemImage: "bookmark",
                                           description: Text("Edit a style in the inspector and save it with the bookmark button, or bookmark a preset here."))
                        .frame(height: 300)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if !savedStyles.isEmpty {
                            grid(title: "Saved", styles: savedStyles)
                        }
                        if !presets.isEmpty {
                            grid(title: tab == .saved ? "Bookmarked Presets" : "Presets", styles: presets)
                        }
                    }
                    .padding(18)
                }
            }

            Divider()
            HStack {
                Text("Pick a style, then fine-tune it in the inspector and save it with the bookmark. The default applies to new videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 600, height: 660)
    }

    private func grid(title: String, styles: [CaptionStyle]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 16) {
                ForEach(styles) { style in
                    let isSaved = settings.isSavedStyle(style.id)
                    StyleTile(style: style,
                              isSelected: style.id == item.style.id,
                              isDefault: settings.isDefault(style),
                              isFavorite: isSaved || settings.favoriteStyleIDs.contains(style.id),
                              showsBookmark: !isSaved) {
                        item.style = style
                    } toggleFavorite: {
                        if settings.favoriteStyleIDs.contains(style.id) {
                            settings.favoriteStyleIDs.remove(style.id)
                        } else {
                            settings.favoriteStyleIDs.insert(style.id)
                        }
                    }
                    .contextMenu {
                        if settings.isDefault(style) {
                            Label("Default for New Videos", systemImage: "checkmark")
                        } else {
                            Button("Use as Default for New Videos") { settings.defaultStyle = style }
                        }
                        if isSaved {
                            Divider()
                            Button("Rename…") {
                                if let name = NamePrompt.run(title: "Rename Style", message: "", defaultValue: style.name) {
                                    settings.renameSavedStyle(id: style.id, to: name)
                                    if item.style.id == style.id { item.style.name = name }
                                }
                            }
                            Button("Delete", role: .destructive) { settings.deleteSavedStyle(id: style.id) }
                        }
                    }
                }
            }
        }
    }
}

struct StyleTile: View {
    let style: CaptionStyle
    let isSelected: Bool
    let isDefault: Bool
    let isFavorite: Bool
    /// Presets can be bookmarked here; saved styles are bookmarks already.
    let showsBookmark: Bool
    let select: () -> Void
    let toggleFavorite: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                StyleSampleView(style: style)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.08), lineWidth: isSelected ? 2.5 : 1)
                    }
                if showsBookmark {
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(isFavorite || hovering ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
            HStack(spacing: 6) {
                Text(style.name)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if isDefault {
                    DefaultBadge()
                }
            }
        }
    }
}
