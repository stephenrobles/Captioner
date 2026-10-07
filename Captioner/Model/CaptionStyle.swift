import CoreGraphics
import Foundation

/// A color that can live in UserDefaults and cross threads; converted to CGColor when drawing.
nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ hex: UInt32, alpha: Double = 1) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    init(cgColor: CGColor) {
        let srgb = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? cgColor
        let c = srgb.components ?? [0, 0, 0, 1]
        if c.count >= 4 {
            self.init(red: c[0], green: c[1], blue: c[2], alpha: c[3])
        } else if c.count >= 2 {
            self.init(red: c[0], green: c[0], blue: c[0], alpha: c[1])
        } else {
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    static let white = RGBAColor(0xFFFFFF)
    static let black = RGBAColor(0x000000)
    static let clear = RGBAColor(0x000000, alpha: 0)
}

nonisolated enum FontDesign: String, Codable, CaseIterable, Sendable {
    case sansSerif, rounded, serif, monospaced

    var title: String {
        switch self {
        case .sansSerif: "Sans Serif"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }
}

/// Which typeface a style uses.
nonisolated enum FontChoice: Codable, Hashable, Sendable {
    /// The system font in one of its designs.
    case system(FontDesign)
    /// A font family installed on this Mac.
    case installed(family: String)
    /// A font file added to Captioner, by file name inside the app's Fonts folder.
    case custom(fileName: String)

    var title: String {
        switch self {
        case .system(let design): design.title
        case .installed(let family): family
        case .custom(let fileName): (fileName as NSString).deletingPathExtension
        }
    }
}

nonisolated enum FontWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold, heavy, black

    var title: String { rawValue.capitalized }

    /// Core Text's weight trait: -1…1, where 0 is regular and 0.62 is black.
    var traitValue: Double {
        switch self {
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }
}

nonisolated enum LetterCase: String, Codable, CaseIterable, Sendable {
    case asSpoken, uppercase, lowercase

    var title: String {
        switch self {
        case .asSpoken: "As spoken"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        }
    }

    func apply(to text: String) -> String {
        switch self {
        case .asSpoken: text
        case .uppercase: text.uppercased()
        case .lowercase: text.lowercased()
        }
    }
}

/// How the word being spoken stands out.
nonisolated enum HighlightKind: String, Codable, CaseIterable, Sendable {
    case none, box, color, underline

    var title: String {
        switch self {
        case .none: "None"
        case .box: "Box behind word"
        case .color: "Text color"
        case .underline: "Underline"
        }
    }
}

/// Everything about how captions look. Sizes are fractions of the font size (which itself is a
/// fraction of the frame), so a style looks the same on a 1080p export and a 4K one.
nonisolated struct CaptionStyle: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String

    var font: FontChoice = .system(.sansSerif)
    var weight: FontWeight = .bold
    /// Font size as a fraction of the frame's shorter side.
    var sizeScale: Double = 0.05
    var letterCase: LetterCase = .asSpoken
    /// Tracking in ems.
    var letterSpacing: Double = 0
    /// Extra space between lines as a fraction of the font size.
    var lineSpacing: Double = 0.18

    var textColor: RGBAColor = .white
    /// Outline thickness as a fraction of the font size; 0 for none.
    var strokeWidth: Double = 0
    var strokeColor: RGBAColor = .black
    /// Shadow blur as a fraction of the font size; 0 for none.
    var shadowRadius: Double = 0.08
    var shadowOpacity: Double = 0.5
    var shadowColor: RGBAColor = .black

    var highlight: HighlightKind = .box
    var activeTextColor: RGBAColor = .white
    /// Box or underline color.
    var highlightColor: RGBAColor = RGBAColor(0xD623B9)
    /// Scales the active word up briefly as it is spoken.
    var popActiveWord: Bool = false

    var lineBackground: Bool = false
    var lineBackgroundColor: RGBAColor = RGBAColor(0x000000, alpha: 0.7)
    /// Corner radius for boxes as a fraction of the font size.
    var cornerRadius: Double = 0.22

    /// Words appear one by one as they are spoken instead of the whole caption at once.
    var progressiveReveal: Bool = false

    var grouping: CaptionGrouping = CaptionGrouping()

    var isMultiline: Bool { grouping.maxLines > 1 }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // MARK: - Presets

    static let `default` = presets[0]

    static func preset(id: String) -> CaptionStyle? {
        presets.first { $0.id == id }
    }

    static let presets: [CaptionStyle] = [
        {
            var s = CaptionStyle(id: "highlight", name: "Highlight")
            s.font = .system(.sansSerif)
            s.weight = .bold
            s.highlight = .box
            s.highlightColor = RGBAColor(0xD623B9)
            s.grouping = CaptionGrouping(maxWordsPerLine: 5, maxLines: 1, maxCharactersPerLine: 24, maxDuration: 4, pauseBreak: 0.8)
            return s
        }(),
        {
            var s = CaptionStyle(id: "outline", name: "Outline")
            s.weight = .black
            s.strokeWidth = 0.09
            s.shadowRadius = 0
            s.highlight = .color
            s.activeTextColor = RGBAColor(0xFFD60A)
            s.grouping = CaptionGrouping(maxWordsPerLine: 4, maxLines: 1, maxCharactersPerLine: 22, maxDuration: 4, pauseBreak: 0.8)
            return s
        }(),
        {
            var s = CaptionStyle(id: "boxed", name: "Boxed")
            s.weight = .bold
            s.shadowRadius = 0
            s.lineBackground = true
            s.lineBackgroundColor = RGBAColor(0x000000, alpha: 0.78)
            s.highlight = .color
            s.activeTextColor = RGBAColor(0xFFD60A)
            s.cornerRadius = 0.3
            s.grouping = CaptionGrouping(maxWordsPerLine: 5, maxLines: 1, maxCharactersPerLine: 24, maxDuration: 4, pauseBreak: 0.8)
            return s
        }(),
        {
            var s = CaptionStyle(id: "pop", name: "Pop")
            s.weight = .black
            s.strokeWidth = 0.06
            s.shadowRadius = 0.1
            s.highlight = .color
            s.activeTextColor = RGBAColor(0xFFD60A)
            s.popActiveWord = true
            s.grouping = CaptionGrouping(maxWordsPerLine: 3, maxLines: 1, maxCharactersPerLine: 18, maxDuration: 3, pauseBreak: 0.7)
            return s
        }(),
        {
            var s = CaptionStyle(id: "rounded", name: "Bubble")
            s.font = .system(.rounded)
            s.weight = .black
            s.strokeWidth = 0.1
            s.shadowRadius = 0
            s.highlight = .box
            s.highlightColor = RGBAColor(0x0A84FF)
            s.cornerRadius = 0.35
            s.popActiveWord = true
            s.grouping = CaptionGrouping(maxWordsPerLine: 3, maxLines: 1, maxCharactersPerLine: 18, maxDuration: 3, pauseBreak: 0.7)
            return s
        }(),
        {
            var s = CaptionStyle(id: "headline", name: "Headline")
            s.weight = .black
            s.letterCase = .uppercase
            s.letterSpacing = 0.02
            s.shadowRadius = 0
            s.highlight = .box
            s.highlightColor = RGBAColor(0xD623B9)
            s.cornerRadius = 0.1
            s.grouping = CaptionGrouping(maxWordsPerLine: 4, maxLines: 1, maxCharactersPerLine: 18, maxDuration: 3.5, pauseBreak: 0.7)
            return s
        }(),
        {
            var s = CaptionStyle(id: "glow", name: "Glow")
            s.font = .system(.rounded)
            s.weight = .bold
            s.textColor = RGBAColor(0x5EF2FF)
            s.shadowRadius = 0.3
            s.shadowOpacity = 1
            s.shadowColor = RGBAColor(0x00C8FF)
            s.highlight = .color
            s.activeTextColor = .white
            s.grouping = CaptionGrouping(maxWordsPerLine: 4, maxLines: 1, maxCharactersPerLine: 22, maxDuration: 4, pauseBreak: 0.8)
            return s
        }(),
        {
            var s = CaptionStyle(id: "karaoke", name: "Karaoke")
            s.weight = .bold
            s.shadowRadius = 0.1
            s.shadowOpacity = 0.7
            s.highlight = .color
            s.activeTextColor = RGBAColor(0xFF9F0A)
            s.grouping = CaptionGrouping(maxWordsPerLine: 4, maxLines: 2, maxCharactersPerLine: 24, maxDuration: 5, pauseBreak: 0.9)
            return s
        }(),
        {
            var s = CaptionStyle(id: "serif", name: "Serif")
            s.font = .system(.serif)
            s.weight = .bold
            s.shadowRadius = 0.12
            s.shadowOpacity = 0.7
            s.highlight = .underline
            s.highlightColor = RGBAColor(0xF5C542)
            s.grouping = CaptionGrouping(maxWordsPerLine: 4, maxLines: 2, maxCharactersPerLine: 24, maxDuration: 5, pauseBreak: 0.9)
            return s
        }(),
        {
            var s = CaptionStyle(id: "typewriter", name: "Typewriter")
            s.font = .system(.monospaced)
            s.weight = .bold
            s.sizeScale = 0.042
            s.shadowRadius = 0
            s.lineBackground = true
            s.lineBackgroundColor = RGBAColor(0x000000, alpha: 0.8)
            s.cornerRadius = 0.1
            s.highlight = .color
            s.activeTextColor = RGBAColor(0xA6E3A1)
            s.progressiveReveal = true
            s.grouping = CaptionGrouping(maxWordsPerLine: 5, maxLines: 2, maxCharactersPerLine: 26, maxDuration: 5, pauseBreak: 0.9)
            return s
        }(),
        {
            var s = CaptionStyle(id: "subtitle", name: "Subtitle")
            s.weight = .semibold
            s.sizeScale = 0.038
            s.shadowRadius = 0
            s.lineBackground = true
            s.lineBackgroundColor = RGBAColor(0x000000, alpha: 0.6)
            s.cornerRadius = 0.15
            s.highlight = .none
            s.grouping = CaptionGrouping(maxWordsPerLine: 7, maxLines: 2, maxCharactersPerLine: 36, maxDuration: 6, pauseBreak: 1)
            return s
        }(),
        {
            var s = CaptionStyle(id: "minimal", name: "Minimal")
            s.weight = .medium
            s.sizeScale = 0.042
            s.shadowRadius = 0.15
            s.shadowOpacity = 0.8
            s.highlight = .none
            s.progressiveReveal = true
            s.grouping = CaptionGrouping(maxWordsPerLine: 6, maxLines: 2, maxCharactersPerLine: 30, maxDuration: 5, pauseBreak: 0.9)
            return s
        }(),
    ]
}
