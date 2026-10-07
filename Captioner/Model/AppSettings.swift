import Foundation
import Observation

nonisolated enum ExportLocation: String, Codable, CaseIterable, Sendable {
    case nextToOriginal, folder

    var title: String {
        switch self {
        case .nextToOriginal: "Next to the original"
        case .folder: "A folder you choose"
        }
    }
}

/// App-wide preferences, backed by UserDefaults. New videos start from these; each video in
/// the queue then keeps its own copy of the style, placement and controls.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: "localeIdentifier") }
    }
    var textOptions: TextOptions {
        didSet { store(textOptions, key: "textOptions") }
    }
    /// Styles the user bookmarked from the inspector; ids start with "saved-".
    var savedStyles: [CaptionStyle] {
        didSet { store(savedStyles, key: "savedStyles") }
    }
    /// The style every new video starts with. A built-in preset until the user picks one.
    var defaultStyle: CaptionStyle {
        didSet { store(defaultStyle, key: "defaultStyle") }
    }
    var placement: PlacementSettings {
        didSet { store(placement, key: "placement") }
    }
    var favoriteStyleIDs: Set<String> {
        didSet { defaults.set(Array(favoriteStyleIDs).sorted(), forKey: "favoriteStyleIDs") }
    }
    var exportCodec: ExportCodec {
        didSet { defaults.set(exportCodec.rawValue, forKey: "exportCodec") }
    }
    var exportLocation: ExportLocation {
        didSet { defaults.set(exportLocation.rawValue, forKey: "exportLocation") }
    }
    var exportFolderPath: String? {
        didSet { defaults.set(exportFolderPath, forKey: "exportFolderPath") }
    }
    /// How long a caption stays up after its last word when nothing follows.
    var captionHold: Double {
        didSet { defaults.set(captionHold, forKey: "captionHold") }
    }
    var revealOutputInFinder: Bool {
        didSet { defaults.set(revealOutputInFinder, forKey: "revealOutputInFinder") }
    }

    private init() {
        localeIdentifier = defaults.string(forKey: "localeIdentifier") ?? Locale.current.identifier
        textOptions = Self.load(TextOptions.self, key: "textOptions", from: defaults) ?? .default
        savedStyles = Self.load([CaptionStyle].self, key: "savedStyles", from: defaults) ?? []
        defaultStyle = Self.load(CaptionStyle.self, key: "defaultStyle", from: defaults) ?? .default
        placement = Self.load(PlacementSettings.self, key: "placement", from: defaults) ?? .default
        favoriteStyleIDs = Set(defaults.stringArray(forKey: "favoriteStyleIDs") ?? [])
        exportCodec = ExportCodec(rawValue: defaults.string(forKey: "exportCodec") ?? "") ?? .h264
        exportLocation = ExportLocation(rawValue: defaults.string(forKey: "exportLocation") ?? "") ?? .nextToOriginal
        exportFolderPath = defaults.string(forKey: "exportFolderPath")
        captionHold = defaults.object(forKey: "captionHold") as? Double ?? 1.0
        revealOutputInFinder = defaults.object(forKey: "revealOutputInFinder") as? Bool ?? true
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    // MARK: - Saved and default styles

    static let savedStylePrefix = "saved-"

    /// The preset or saved style a style was derived from, to tell whether it has been edited.
    func baseStyle(for id: String) -> CaptionStyle? {
        savedStyles.first { $0.id == id } ?? CaptionStyle.preset(id: id)
    }

    func isSavedStyle(_ id: String) -> Bool {
        savedStyles.contains { $0.id == id }
    }

    /// Whether `style` has been changed since it was picked or saved.
    func isEdited(_ style: CaptionStyle) -> Bool {
        guard let base = baseStyle(for: style.id) else { return true }
        return base != style
    }

    func isDefault(_ style: CaptionStyle) -> Bool {
        style == defaultStyle
    }

    /// Keeps a copy of `style` under `name` and returns it (with its new id) so the caller can adopt it.
    @discardableResult
    func saveStyle(_ style: CaptionStyle, name: String) -> CaptionStyle {
        var saved = style
        saved.id = Self.savedStylePrefix + UUID().uuidString
        saved.name = name
        savedStyles.append(saved)
        return saved
    }

    /// Overwrites the saved style with `style`'s id. If that style is the default, the default follows.
    func updateSavedStyle(_ style: CaptionStyle) {
        guard let index = savedStyles.firstIndex(where: { $0.id == style.id }) else { return }
        var updated = style
        updated.name = savedStyles[index].name
        savedStyles[index] = updated
        if defaultStyle.id == style.id { defaultStyle = updated }
    }

    func renameSavedStyle(id: String, to name: String) {
        guard let index = savedStyles.firstIndex(where: { $0.id == id }) else { return }
        savedStyles[index].name = name
        if defaultStyle.id == id { defaultStyle.name = name }
    }

    func deleteSavedStyle(id: String) {
        savedStyles.removeAll { $0.id == id }
        if defaultStyle.id == id { defaultStyle = .default }
    }

    var exportFolder: URL? {
        guard exportLocation == .folder, let exportFolderPath else { return nil }
        return URL(fileURLWithPath: exportFolderPath, isDirectory: true)
    }

    private func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
