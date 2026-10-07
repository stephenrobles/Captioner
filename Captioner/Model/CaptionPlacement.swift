import CoreGraphics
import Foundation

nonisolated enum FrameOrientation: String, Codable, CaseIterable, Sendable {
    case landscape, portrait

    var title: String {
        switch self {
        case .landscape: "16:9"
        case .portrait: "9:16"
        }
    }

    static func of(_ size: CGSize) -> FrameOrientation {
        size.height > size.width ? .portrait : .landscape
    }
}

nonisolated enum CaptionAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing

    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }

    var symbolName: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

/// Where captions sit in the frame for one orientation.
nonisolated struct CaptionPlacement: Codable, Hashable, Sendable {
    /// Center of the caption block, 0 at the top edge … 1 at the bottom edge.
    var vertical: Double
    var alignment: CaptionAlignment
    /// Margin from the left/right edge as a fraction of the frame width.
    var horizontalInset: Double = 0.06
    /// Widest the text may run, as a fraction of the frame width.
    var maxWidth: Double = 0.88

    static let landscapeDefault = CaptionPlacement(vertical: 0.88, alignment: .center)
    static let portraitDefault = CaptionPlacement(vertical: 0.75, alignment: .center)
}

/// A placement for each orientation; a 9:16 short and a 16:9 video keep their own.
nonisolated struct PlacementSettings: Codable, Hashable, Sendable {
    var landscape: CaptionPlacement = .landscapeDefault
    var portrait: CaptionPlacement = .portraitDefault

    static let `default` = PlacementSettings()

    subscript(orientation: FrameOrientation) -> CaptionPlacement {
        get {
            switch orientation {
            case .landscape: landscape
            case .portrait: portrait
            }
        }
        set {
            switch orientation {
            case .landscape: landscape = newValue
            case .portrait: portrait = newValue
            }
        }
    }

    func placement(for size: CGSize) -> CaptionPlacement {
        self[FrameOrientation.of(size)]
    }
}
