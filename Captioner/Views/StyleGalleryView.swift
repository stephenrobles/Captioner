import SwiftUI

/// The style picker: favorites, all, monoline and multiline tabs over a grid of samples.
struct StyleGalleryView: View {
    @Bindable var item: CaptionItem
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .all

    enum Tab: Hashable {
        case favorites, all, monoline, multiline
    }

    private var settings: AppSettings { AppSettings.shared }

    private var styles: [CaptionStyle] {
        switch tab {
        case .favorites: CaptionStyle.presets.filter { settings.favoriteStyleIDs.contains($0.id) }
        case .all: CaptionStyle.presets
        case .monoline: CaptionStyle.presets.filter { !$0.isMultiline }
        case .multiline: CaptionStyle.presets.filter { $0.isMultiline }
        }
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
                Image(systemName: "bookmark").tag(Tab.favorites)
                Text("All").tag(Tab.all)
                Text("Monoline").tag(Tab.monoline)
                Text("Multiline").tag(Tab.multiline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                if styles.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "bookmark",
                                           description: Text("Click the bookmark on a style to keep it here."))
                        .frame(height: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 16) {
                        ForEach(styles) { style in
                            StyleTile(style: style, isSelected: style.id == item.style.id,
                                      isFavorite: settings.favoriteStyleIDs.contains(style.id)) {
                                item.style = style
                            } toggleFavorite: {
                                if settings.favoriteStyleIDs.contains(style.id) {
                                    settings.favoriteStyleIDs.remove(style.id)
                                } else {
                                    settings.favoriteStyleIDs.insert(style.id)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }

            Divider()
            HStack {
                Text("Pick a style, then fine-tune fonts and colors in the inspector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 560, height: 620)
    }
}

struct StyleTile: View {
    let style: CaptionStyle
    let isSelected: Bool
    let isFavorite: Bool
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
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
            Text(style.name)
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}
