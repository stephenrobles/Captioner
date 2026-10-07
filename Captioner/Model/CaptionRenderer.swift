import CoreGraphics
import CoreText
import Foundation

/// Everything the renderer needs for one frame, frozen so it can cross to the render thread.
nonisolated struct RenderSnapshot: Hashable, Sendable {
    var captions: [Caption]
    var style: CaptionStyle
    var placement: PlacementSettings
    var textOptions: TextOptions
    /// How long a caption stays after its last word when nothing follows it.
    var hold: TimeInterval = 1.0
}

/// One laid-out word: where it sits and what it says after the text options are applied.
nonisolated struct LaidWord {
    var text: String
    var start: TimeInterval
    /// Glyph bounds in the frame, bottom-left origin.
    var frame: CGRect
    var baseline: CGPoint
    var line: CTLine
}

/// A caption measured into lines for a frame of a given size.
nonisolated struct CaptionLayout {
    var captionID: UUID
    var fontSize: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var lines: [[LaidWord]]
    /// Bounds of the laid-out text, bottom-left origin.
    var blockRect: CGRect

    var words: [LaidWord] { lines.flatMap { $0 } }
}

/// Draws captions with Core Text. Coordinates are Core Graphics' (origin bottom-left),
/// which is what pixel buffers and bitmap contexts use.
nonisolated enum CaptionRenderer {
    static let popDuration: TimeInterval = 0.14
    static let popScale: CGFloat = 1.14

    // MARK: - Drawing

    /// What to lay out for `caption` at `time`: the whole caption, or just the spoken word for a
    /// single-word style. Returns the caption to draw and which of its words is active.
    static func displayed(_ caption: Caption, style: CaptionStyle, time: TimeInterval) -> (caption: Caption, activeIndex: Int?) {
        let active = caption.activeWordIndex(at: time)
        guard style.singleWord else { return (caption, active) }
        let index = active ?? 0
        guard caption.words.indices.contains(index) else { return (caption, active) }
        return (Caption(id: caption.id, words: [caption.words[index]]), 0)
    }

    /// Draws whatever caption is visible at `time` into `context`, a frame of `size`.
    static func draw(_ snapshot: RenderSnapshot, time: TimeInterval, size: CGSize, in context: CGContext) {
        guard let index = snapshot.captions.visibleIndex(at: time, hold: snapshot.hold) else { return }
        let shown = displayed(snapshot.captions[index], style: snapshot.style, time: time)
        let layout = layout(shown.caption, style: snapshot.style, placement: snapshot.placement.placement(for: size),
                            textOptions: snapshot.textOptions, fontSize: fontSize(for: snapshot.style, in: size), size: size)
        draw(layout, style: snapshot.style, activeIndex: shown.activeIndex, time: time, in: context)
    }

    /// The region a caption occupies at `time`, with room for its decorations; nil when nothing shows.
    /// Bottom-left origin.
    static func region(_ snapshot: RenderSnapshot, time: TimeInterval, size: CGSize) -> CGRect? {
        guard let index = snapshot.captions.visibleIndex(at: time, hold: snapshot.hold) else { return nil }
        let shown = displayed(snapshot.captions[index], style: snapshot.style, time: time)
        let layout = layout(shown.caption, style: snapshot.style, placement: snapshot.placement.placement(for: size),
                            textOptions: snapshot.textOptions, fontSize: fontSize(for: snapshot.style, in: size), size: size)
        return decoratedBounds(of: layout, style: snapshot.style).intersection(CGRect(origin: .zero, size: size))
    }

    /// The text block's bounds for the caption at `time`, with the origin at the top-left as
    /// SwiftUI expects. Used to show the drag handle over the preview.
    static func blockRectTopLeft(_ snapshot: RenderSnapshot, time: TimeInterval, size: CGSize) -> CGRect? {
        guard let index = snapshot.captions.index(at: time) ?? (snapshot.captions.isEmpty ? nil : 0) else { return nil }
        let shown = displayed(snapshot.captions[index], style: snapshot.style, time: time)
        let layout = layout(shown.caption, style: snapshot.style, placement: snapshot.placement.placement(for: size),
                            textOptions: snapshot.textOptions, fontSize: fontSize(for: snapshot.style, in: size), size: size)
        let rect = decoratedBounds(of: layout, style: snapshot.style)
        return CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Renders only the caption's region into a transparent image, so the compositor can
    /// blend a small picture instead of repainting the whole frame.
    static func overlayImage(_ snapshot: RenderSnapshot, time: TimeInterval, size: CGSize) -> (image: CGImage, origin: CGPoint)? {
        guard let region = region(snapshot, time: time, size: size) else { return nil }
        let rect = region.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(snapshot, time: time, size: size, in: context)
        guard let image = context.makeImage() else { return nil }
        return (image, rect.origin)
    }

    /// A preview tile for the style gallery: "Pick a style" with the second word active.
    static func drawSample(_ style: CaptionStyle, size: CGSize, in context: CGContext) {
        let text = style.isMultiline ? ["Pick", "a", "style", "for", "your", "video"] : ["Pick", "a", "style"]
        var words: [TranscriptWord] = []
        for (i, piece) in text.enumerated() {
            words.append(TranscriptWord(text: piece, start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.35))
        }
        let caption = Caption(words: words)
        var placement = CaptionPlacement(vertical: 0.5, alignment: .center)
        placement.maxWidth = style.isMultiline ? 0.62 : 0.9
        let fontSize = size.height * (style.isMultiline ? 0.15 : style.singleWord ? 0.26 : 0.19)
        let activeIndex = style.isMultiline ? 2 : style.singleWord ? 0 : 1
        let time = words[activeIndex].start + popDuration
        let shown = displayed(caption, style: style, time: time)
        let layout = layout(shown.caption, style: style, placement: placement, textOptions: .default, fontSize: fontSize, size: size)
        draw(layout, style: style, activeIndex: shown.activeIndex, time: time, in: context)
    }

    // MARK: - Layout

    static func fontSize(for style: CaptionStyle, in size: CGSize) -> CGFloat {
        max(4, min(size.width, size.height) * style.sizeScale)
    }

    static func layout(_ caption: Caption, style: CaptionStyle, placement: CaptionPlacement, textOptions: TextOptions,
                       fontSize: CGFloat, size: CGSize) -> CaptionLayout {
        let font = FontResolver.font(for: style.font, weight: style.weight, size: fontSize)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent
        let lineGap = style.lineSpacing * fontSize
        let kern = style.letterSpacing * fontSize

        func line(for text: String) -> CTLine {
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTKernAttributeName: kern]
            return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        }

        let spaceWidth = CGFloat(CTLineGetTypographicBounds(line(for: " "), nil, nil, nil))
        let maxWidth = max(fontSize, size.width * placement.maxWidth)

        // Wrap greedily by width. Captions are grouped to fit their style, so this rarely adds lines.
        var rows: [[(word: TranscriptWord, text: String, line: CTLine, width: CGFloat)]] = [[]]
        var rowWidth: CGFloat = 0
        for word in caption.words {
            let text = style.letterCase.apply(to: TextTransforms.apply(textOptions, to: word.text))
            guard !text.isEmpty else { continue }
            let ctLine = line(for: text)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if !rows[rows.count - 1].isEmpty, rowWidth + spaceWidth + width > maxWidth {
                rows.append([])
                rowWidth = 0
            }
            rowWidth += (rows[rows.count - 1].isEmpty ? 0 : spaceWidth) + width
            rows[rows.count - 1].append((word, text, ctLine, width))
        }
        rows = rows.filter { !$0.isEmpty }

        let blockHeight = CGFloat(rows.count) * lineHeight + CGFloat(max(rows.count - 1, 0)) * lineGap
        let centerY = size.height * (1 - placement.vertical)
        let top = centerY + blockHeight / 2
        let inset = size.width * placement.horizontalInset

        var lines: [[LaidWord]] = []
        var block = CGRect.null
        for (rowIndex, row) in rows.enumerated() {
            let width = row.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(row.count - 1, 0)) * spaceWidth
            var x: CGFloat = switch placement.alignment {
            case .leading: inset
            case .center: (size.width - width) / 2
            case .trailing: size.width - inset - width
            }
            let baseline = top - CGFloat(rowIndex) * (lineHeight + lineGap) - ascent
            var laid: [LaidWord] = []
            for entry in row {
                let frame = CGRect(x: x, y: baseline - descent, width: entry.width, height: lineHeight)
                laid.append(LaidWord(text: entry.text, start: entry.word.start, frame: frame, baseline: CGPoint(x: x, y: baseline), line: entry.line))
                block = block.union(frame)
                x += entry.width + spaceWidth
            }
            lines.append(laid)
        }
        if block.isNull { block = CGRect(x: size.width / 2, y: centerY, width: 0, height: 0) }
        return CaptionLayout(captionID: caption.id, fontSize: fontSize, ascent: ascent, descent: descent, lines: lines, blockRect: block)
    }

    /// The layout's bounds plus everything drawn around the text: boxes, outlines, shadows, the pop.
    static func decoratedBounds(of layout: CaptionLayout, style: CaptionStyle) -> CGRect {
        let f = layout.fontSize
        var pad = f * 0.25
        if style.lineBackground { pad = max(pad, linePadding(f).x + f * 0.1) }
        if style.highlight == .box { pad = max(pad, boxPadding(f).x + f * 0.1) }
        pad += style.strokeWidth * f
        pad += style.shadowRadius * f * 2
        if style.popActiveWord { pad += f * 0.5 }
        return layout.blockRect.insetBy(dx: -pad, dy: -pad)
    }

    private static func boxPadding(_ fontSize: CGFloat) -> CGPoint { CGPoint(x: fontSize * 0.16, y: fontSize * 0.06) }
    private static func linePadding(_ fontSize: CGFloat) -> CGPoint { CGPoint(x: fontSize * 0.35, y: fontSize * 0.14) }

    // MARK: - Painting

    static func draw(_ layout: CaptionLayout, style: CaptionStyle, activeIndex: Int?, time: TimeInterval, in context: CGContext) {
        let f = layout.fontSize
        let words = layout.words
        guard !words.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        context.textMatrix = .identity

        func visible(_ index: Int) -> Bool {
            !style.progressiveReveal || words[index].start <= time + 0.0001
        }

        func activeScale(for index: Int) -> CGFloat {
            guard style.popActiveWord, index == activeIndex else { return 1 }
            let elapsed = time - words[index].start
            guard elapsed >= 0 else { return 1 }
            let t = min(1, elapsed / popDuration)
            // Ease out: snaps up quickly and settles.
            let eased = 1 - pow(1 - t, 3)
            return 1 + (Self.popScale - 1) * eased
        }

        // Line backgrounds.
        if style.lineBackground {
            let pad = linePadding(f)
            context.setFillColor(style.lineBackgroundColor.cgColor)
            var offset = 0
            for line in layout.lines {
                let drawn = line.enumerated().filter { visible(offset + $0.offset) }.map(\.element)
                offset += line.count
                guard let first = drawn.first, let last = drawn.last else { continue }
                let rect = CGRect(x: first.frame.minX - pad.x, y: first.frame.minY - pad.y,
                                  width: last.frame.maxX - first.frame.minX + pad.x * 2, height: first.frame.height + pad.y * 2)
                let radius = min(style.cornerRadius * f, rect.height / 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }

        // Highlight behind the active word.
        if let activeIndex, words.indices.contains(activeIndex), visible(activeIndex) {
            let word = words[activeIndex]
            let scale = activeScale(for: activeIndex)
            switch style.highlight {
            case .box:
                let pad = boxPadding(f)
                var rect = word.frame.insetBy(dx: -pad.x, dy: -pad.y)
                if scale != 1 {
                    rect = rect.insetBy(dx: -rect.width * (scale - 1) / 2, dy: -rect.height * (scale - 1) / 2)
                }
                let radius = min(style.cornerRadius * f, rect.height / 2)
                context.setFillColor(style.highlightColor.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case .underline:
                let thickness = max(1, f * 0.09)
                let rect = CGRect(x: word.frame.minX, y: word.frame.minY + layout.descent * 0.15 - thickness, width: word.frame.width, height: thickness)
                context.setFillColor(style.highlightColor.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil))
                context.fillPath()
            case .color, .none:
                break
            }
        }

        // Words.
        for (index, word) in words.enumerated() where visible(index) {
            let isActive = index == activeIndex && style.highlight != .none
            let color = (isActive ? style.activeTextColor : style.textColor).cgColor
            let scale = activeScale(for: index)

            context.saveGState()
            if scale != 1 {
                let center = CGPoint(x: word.frame.midX, y: word.frame.midY)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -center.x, y: -center.y)
            }

            let shadowColor = style.shadowRadius > 0 && style.shadowOpacity > 0
                ? style.shadowColor.withAlpha(style.shadowColor.alpha * style.shadowOpacity).cgColor : nil
            let strokePercent = style.strokeWidth * 100 * 2  // Core Text's width is a % of the font size; half lands inside the glyph.

            if style.strokeWidth > 0 {
                context.saveGState()
                if let shadowColor { context.setShadow(offset: CGSize(width: 0, height: -f * 0.04), blur: style.shadowRadius * f, color: shadowColor) }
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: fontOf(word.line),
                    kCTKernAttributeName: style.letterSpacing * f,
                    kCTStrokeWidthAttributeName: strokePercent,
                    kCTStrokeColorAttributeName: style.strokeColor.cgColor,
                    kCTForegroundColorAttributeName: style.strokeColor.cgColor,
                ]
                let outline = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, word.text as CFString, attributes as CFDictionary))
                context.setLineJoin(.round)
                context.textPosition = word.baseline
                CTLineDraw(outline, context)
                context.restoreGState()
            }

            context.saveGState()
            if style.strokeWidth == 0, let shadowColor {
                context.setShadow(offset: CGSize(width: 0, height: -f * 0.04), blur: style.shadowRadius * f, color: shadowColor)
            }
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: fontOf(word.line),
                kCTKernAttributeName: style.letterSpacing * f,
                kCTForegroundColorAttributeName: color,
            ]
            let fill = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, word.text as CFString, attributes as CFDictionary))
            context.textPosition = word.baseline
            CTLineDraw(fill, context)
            context.restoreGState()
            context.restoreGState()
        }
    }

    /// The font a measured line was built with.
    private static func fontOf(_ line: CTLine) -> CTFont {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        if let run = runs.first, let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] {
            return font as! CTFont
        }
        return CTFontCreateUIFontForLanguage(.system, 12, nil)!
    }
}
