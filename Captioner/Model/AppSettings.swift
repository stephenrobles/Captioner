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
    var style: CaptionStyle {
        didSet { store(style, key: "style") }
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
        style = Self.load(CaptionStyle.self, key: "style", from: defaults) ?? .default
        placement = Self.load(PlacementSettings.self, key: "placement", from: defaults) ?? .default
        favoriteStyleIDs = Set(defaults.stringArray(forKey: "favoriteStyleIDs") ?? [])
        exportCodec = ExportCodec(rawValue: defaults.string(forKey: "exportCodec") ?? "") ?? .h264
        exportLocation = ExportLocation(rawValue: defaults.string(forKey: "exportLocation") ?? "") ?? .nextToOriginal
        exportFolderPath = defaults.string(forKey: "exportFolderPath")
        captionHold = defaults.object(forKey: "captionHold") as? Double ?? 1.0
        revealOutputInFinder = defaults.object(forKey: "revealOutputInFinder") as? Bool ?? true
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

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
