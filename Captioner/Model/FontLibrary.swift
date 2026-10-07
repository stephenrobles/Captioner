import AppKit
import CoreText
import Foundation
import Observation

/// A font file the user added to Captioner.
nonisolated struct CustomFont: Codable, Hashable, Identifiable, Sendable {
    var fileName: String
    var displayName: String

    var id: String { fileName }
}

/// Font files added by the user live in Application Support/Captioner/Fonts and are registered
/// with Core Text for this process at launch and when added.
@Observable
final class FontLibrary {
    static let shared = FontLibrary()

    private(set) var customFonts: [CustomFont] = []
    private(set) var installedFamilies: [String] = []

    static let supportedExtensions = ["ttf", "otf", "ttc"]

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Captioner/Fonts", directoryHint: .isDirectory)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        reload()
        installedFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var fonts: [CustomFont] = []
        for url in urls where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            Self.register(url)
            fonts.append(CustomFont(fileName: url.lastPathComponent, displayName: Self.displayName(of: url)))
        }
        customFonts = fonts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Copies a font file into the library and registers it. Returns the font so the caller can select it.
    @discardableResult
    func add(_ source: URL) throws -> CustomFont {
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Choose a TrueType (.ttf) or OpenType (.otf) font file."])
        }
        let destination = Self.directory.appending(path: source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        Self.register(destination)
        FontResolver.clearCache()
        reload()
        return CustomFont(fileName: destination.lastPathComponent, displayName: Self.displayName(of: destination))
    }

    func remove(_ font: CustomFont) {
        let url = Self.directory.appending(path: font.fileName)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        FontResolver.clearCache()
        reload()
    }

    private static func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    nonisolated private static func displayName(of url: URL) -> String {
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first,
           let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String {
            return family
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// Turns a FontChoice into a Core Text font. Safe to call from the render thread.
nonisolated enum FontResolver {
    private struct Key: Hashable {
        let choice: FontChoice
        let weight: FontWeight
        let size: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CTFont] = [:]

    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    static func font(for choice: FontChoice, weight: FontWeight, size: CGFloat) -> CTFont {
        let key = Key(choice: choice, weight: weight, size: Double(size))
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let font = make(choice: choice, weight: weight, size: size)
        lock.lock()
        cache[key] = font
        lock.unlock()
        return font
    }

    private static func make(choice: FontChoice, weight: FontWeight, size: CGFloat) -> CTFont {
        switch choice {
        case .system(let design):
            let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let traits: [CFString: Any] = [kCTFontWeightTrait: weight.traitValue]
            var attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            var font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
            if design != .sansSerif {
                let designName: NSFontDescriptor.SystemDesign = switch design {
                case .rounded: .rounded
                case .serif: .serif
                case .monospaced: .monospaced
                case .sansSerif: .default
                }
                let nsDescriptor = (font as NSFont).fontDescriptor.withDesign(designName) ?? (font as NSFont).fontDescriptor
                if let designed = NSFont(descriptor: nsDescriptor, size: size) {
                    font = designed as CTFont
                }
            }
            attributes.removeAll()
            return font

        case .installed(let family):
            let traits: [CFString: Any] = [kCTFontWeightTrait: weight.traitValue]
            let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family, kCTFontTraitsAttribute: traits]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)

        case .custom(let fileName):
            let url = FontLibrary.directory.appending(path: fileName)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else {
                return make(choice: .system(.sansSerif), weight: weight, size: size)
            }
            // Pick the face whose weight is closest to the one asked for.
            let best = descriptors.min { a, b in
                abs(weightTrait(a) - weight.traitValue) < abs(weightTrait(b) - weight.traitValue)
            } ?? descriptors[0]
            return CTFontCreateWithFontDescriptor(best, size, nil)
        }
    }

    private static func weightTrait(_ descriptor: CTFontDescriptor) -> Double {
        guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any],
              let weight = traits[kCTFontWeightTrait] as? Double else { return 0 }
        return weight
    }
}
