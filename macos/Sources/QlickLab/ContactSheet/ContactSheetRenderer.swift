// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreGraphics
// CTFont and CTFontDescriptor are immutable, safe to share between threads.
@preconcurrency import CoreText
import os

/// What one frame of the sheet shows.
struct SheetFrameContent {
    var name: String
    /// The frame number printed on the film: its place in the whole roll, so it doesn't change with the filter.
    var number: String
    var image: CGImage?
    var flag: PhotoSidecar.Flag?
    var rating = 0
    var edited = false
    /// Qlick Lab: the colour label, a round sticker on the frame's top left corner.
    var label: ColorLabel?
    /// Qlick Lab: the stack it stands for or tops: how many, and whether it's open.
    var stack: (count: Int, open: Bool)?
    var selected = false
    var current = false
    /// A second line for the detailed view: date and exposure.
    var caption: String?
    /// How much of the mark is drawn yet, 0…1, while its gesture is animated.
    var markProgress: CGFloat = 1
}

/// The words at the top of a sheet.
struct SheetHeading: Equatable {
    var title = ""
    var subtitle = ""
    var counts = ""
    var notes = ""
    var isEmpty: Bool { title.isEmpty && subtitle.isEmpty && counts.isEmpty && notes.isEmpty }
}

/// The sheet's colours. Red is the pencil's and nothing else's.
struct SheetPalette {
    var sheet: CGColor
    var film: CGColor
    /// What shows through the perforations.
    var hole: CGColor
    var filmEdge: CGColor
    /// Edge print: frame numbers, names.
    var ink: CGColor
    var inkDim: CGColor
    /// Words written on the sheet itself, outside the film.
    var writing: CGColor
    var writingDim: CGColor
    var blank: CGColor
    var pencil: CGColor
    var cursor: CGColor
    var rejectedOpacity: CGFloat

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(gray: white, alpha: alpha) }
    static let pencilRed = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.89, 0.11, 0.14, 1])!

    /// The dark sheet: strips lying on black card, as the lab is lit.
    static let dark = SheetPalette(sheet: gray(0.058), film: gray(0), hole: gray(0.135), filmEdge: gray(1, 0.07),
                                   ink: gray(0.9, 0.86), inkDim: gray(0.62, 0.7), writing: gray(0.94), writingDim: gray(0.55),
                                   blank: gray(0.07), pencil: pencilRed, cursor: gray(1), rejectedOpacity: 0.36)
    /// A light box under the strips.
    static let lightTable = SheetPalette(sheet: gray(0.9), film: gray(0.02), hole: gray(0.9), filmEdge: gray(0, 0),
                                         ink: gray(0.92, 0.88), inkDim: gray(0.66, 0.75), writing: gray(0.1), writingDim: gray(0.42),
                                         blank: gray(0.08), pencil: pencilRed, cursor: gray(0.05), rejectedOpacity: 0.36)
    /// Printed on white paper: the strips stay black, as a contact print's are.
    static let paper = SheetPalette(sheet: gray(1), film: gray(0), hole: gray(1), filmEdge: gray(0, 0),
                                    ink: gray(1, 0.9), inkDim: gray(0.78, 0.9), writing: gray(0.08), writingDim: gray(0.4),
                                    blank: gray(0.1), pencil: pencilRed, cursor: gray(0), rejectedOpacity: 0.45)
    /// Printed as a black sheet, edge to edge.
    static let blackPaper = SheetPalette(sheet: gray(0.04), film: gray(0), hole: gray(0.17), filmEdge: gray(1, 0.1),
                                         ink: gray(0.92, 0.9), inkDim: gray(0.7, 0.8), writing: gray(0.95), writingDim: gray(0.62),
                                         blank: gray(0.09), pencil: pencilRed, cursor: gray(1), rejectedOpacity: 0.45)
}

/// The edge-print face: Rajdhani Bold, the face of QLab's focal lengths (bundled, OFL), else the system's.
enum SheetFonts {
    static let file = "Rajdhani-Bold.ttf"
    private static let registered: Bool = {
        guard let directory = Theme.Fonts.directory() else { return false }
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || (CTFontCopyPostScriptName(CTFontCreateWithName("Rajdhani-Bold" as CFString, 12, nil)) as String) == "Rajdhani-Bold"
    }()

    /// Fonts are made once a size: a sheet draws hundreds of numbers at a pass.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: CTFont]())
    private static func cached(_ key: String, _ make: () -> CTFont) -> CTFont {
        if let font = cache.withLock({ $0[key] }) { return font }
        let font = make()
        cache.withLock { $0[key] = font }
        return font
    }

    static func edge(_ size: CGFloat) -> CTFont { cached("e\(size)") { makeEdge(size) } }
    static func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> CTFont {
        cached("t\(size)|\(weight.rawValue)") { NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) as CTFont }
    }

    private static func makeEdge(_ size: CGFloat) -> CTFont {
        if registered {
            let font = CTFontCreateWithName("Rajdhani-Bold" as CFString, size * 1.12, nil)
            let features: [[CFString: Any]] = [[kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]]
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size * 1.12, nil)
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold) as CTFont
    }
}

/// Draws a contact sheet into any Core Graphics context whose origin is at the top left (y down): the window's
/// view and the printed page's PDF alike, so the print is the sheet itself and not a picture of the window.
struct ContactSheetRenderer {
    var layout: ContactSheetLayout
    var palette = SheetPalette.dark
    var sidewaysVerticals = false
    var showsNumbers = true
    var showsMarks = true
    /// Printed in the upper band every few frames, as a stock's name is on film.
    var edgeLabel = ""

    // MARK: Sheet and film

    func drawSheet(_ context: CGContext, in rect: CGRect) {
        context.setFillColor(palette.sheet)
        context.fill(rect)
    }

    func drawHeading(_ context: CGContext, _ heading: SheetHeading, scale: CGFloat = 1) {
        guard layout.header > 0, !heading.isEmpty else { return }
        let x = layout.originX + 2, right = layout.originX + layout.stripLength - 2
        var y = layout.margin + 20 * scale
        Self.draw(heading.title, font: SheetFonts.text(17 * scale, weight: .semibold), color: palette.writing, at: CGPoint(x: x, y: y), in: context)
        if !heading.counts.isEmpty {
            Self.draw(heading.counts, font: SheetFonts.text(11 * scale), color: palette.writingDim, at: CGPoint(x: right, y: y), align: .right, in: context)
        }
        y += 18 * scale
        if !heading.subtitle.isEmpty {
            Self.draw(heading.subtitle.uppercased(), font: SheetFonts.text(10 * scale, weight: .medium), color: palette.writingDim, at: CGPoint(x: x, y: y),
                      tracking: 1.1 * scale, in: context)
            y += 16 * scale
        }
        if !heading.notes.isEmpty {
            let note = heading.notes.replacingOccurrences(of: "\n", with: " · ")
            Self.draw(note, font: SheetFonts.text(11 * scale), color: palette.writingDim, at: CGPoint(x: x, y: y), maxWidth: right - x, in: context)
        }
    }

    /// The film of a row: its base, its perforations, and the sheet showing through them.
    func drawStrip(_ context: CGContext, row: Int) {
        guard layout.style != .detail, layout.showsFilm else { return }
        let strip = layout.strip(row)
        context.setFillColor(palette.film)
        context.fill(strip)
        context.setFillColor(palette.hole)
        let radius = max(layout.perforation * 0.09, 0.8)
        for top in [true, false] {
            for hole in layout.perforations(strip: strip, top: top) {
                context.addPath(CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
        }
        context.fillPath()
        if palette.filmEdge.alpha > 0 {
            context.setStrokeColor(palette.filmEdge)
            context.setLineWidth(1)
            context.stroke(strip.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    // MARK: Frames

    func drawFrame(_ context: CGContext, index: Int, _ content: SheetFrameContent) {
        let window = layout.picture(index)
        let rejected = content.flag == .reject
        if let image = content.image {
            let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            let (rect, turned) = ContactSheetLayout.fit(aspect: aspect, in: window, sideways: sidewaysVerticals)
            context.saveGState()
            context.setAlpha(rejected ? palette.rejectedOpacity : 1)
            // The window hands over thumbnails already at their size; a larger one (print) is resampled well.
            context.interpolationQuality = CGFloat(image.width) > rect.width * 2.4 ? .high : .medium
            Self.draw(image, in: rect, turned: turned, context)
            context.restoreGState()
        } else {
            context.setFillColor(palette.blank)
            context.fill(window)
        }
        drawEdgePrint(context, index: index, content, window: window)
        drawLabel(context, content, picture: content.image == nil ? window : pictureRect(index, content))
        drawStack(context, content, picture: content.image == nil ? window : pictureRect(index, content))
    }

    /// A stack's badge at the picture's bottom right: two cards and how many, filled while it's closed.
    func drawStack(_ context: CGContext, _ content: SheetFrameContent, picture: CGRect) {
        guard let stack = content.stack else { return }
        let height = min(max(layout.frame.width * 0.085, 12), 18)
        let font = CTFontCreateUIFontForLanguage(.system, height * 0.62, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, height * 0.62, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font
        let ink = stack.open ? CGColor(gray: 0.94, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let text = NSAttributedString(string: "\(stack.count)", attributes: [.font: bold, .foregroundColor: ink])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let glyph = height * 0.5
        let width = height * 0.45 + glyph + height * 0.2 + textWidth + height * 0.4
        let inset = max(height * 0.35, 4)
        let badge = CGRect(x: picture.maxX - inset - width, y: picture.maxY - inset - height, width: width, height: height)
        context.saveGState()
        let capsule = CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        context.setFillColor(stack.open ? CGColor(gray: 0, alpha: 0.6) : CGColor(gray: 0.94, alpha: 1))
        context.addPath(capsule); context.fillPath()
        context.setStrokeColor(stack.open ? CGColor(gray: 0.94, alpha: 0.7) : CGColor(gray: 0, alpha: 0.35))
        context.setLineWidth(1)
        context.addPath(capsule); context.strokePath()
        // Two cards, one behind the other.
        let card = CGRect(x: badge.minX + height * 0.45, y: badge.midY - glyph * 0.35, width: glyph * 0.72, height: glyph * 0.72)
        context.setStrokeColor(ink)
        context.setLineWidth(max(height * 0.08, 1))
        context.stroke(card.offsetBy(dx: glyph * 0.22, dy: -glyph * 0.22))
        context.setFillColor(stack.open ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 0.94, alpha: 1))
        context.fill(card); context.stroke(card)
        // The count (the context is flipped: text is drawn upright).
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(bold), descent = CTFontGetDescent(bold)
        context.textPosition = CGPoint(x: badge.minX + height * 0.45 + glyph + height * 0.2, y: badge.midY + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The colour label: a round sticker laid on the picture's top left corner, as on a print, with a dark rim so it
    /// reads on a bright sky. In every style, and printed.
    func drawLabel(_ context: CGContext, _ content: SheetFrameContent, picture: CGRect) {
        guard let label = content.label else { return }
        let diameter = min(max(layout.frame.width * 0.065, 7), 15)
        let inset = max(diameter * 0.45, 3)
        let dot = CGRect(x: picture.minX + inset, y: picture.minY + inset, width: diameter, height: diameter)
        context.saveGState()
        context.setFillColor(label.cgColor)
        context.fillEllipse(in: dot)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        context.setLineWidth(max(diameter * 0.1, 0.8))
        context.strokeEllipse(in: dot.insetBy(dx: 0.4, dy: 0.4))
        context.restoreGState()
    }

    private func drawEdgePrint(_ context: CGContext, index: Int, _ content: SheetFrameContent, window: CGRect) {
        let h = layout.frame.height
        // Without the film the edge print is written on the sheet itself.
        let ink = layout.showsFilm ? palette.ink : palette.writing, inkDim = layout.showsFilm ? palette.inkDim : palette.writingDim
        switch layout.style {
        case .classic, .compact:
            let compact = layout.style == .compact
            if showsNumbers {
                let size = min(max(layout.numberBand * 0.78, 8), 17)
                let baseline = window.minY - (layout.numberBand - size * 0.72) / 2
                Self.draw(content.number, font: SheetFonts.edge(size), color: ink,
                          at: CGPoint(x: compact ? window.minX + 2 : window.midX, y: baseline), align: compact ? .left : .center, tracking: size * 0.06, in: context)
            }
            if compact, content.rating > 0, showsNumbers {
                // No band under a compact frame: the stars go beside its number.
                let size = min(max(layout.numberBand * 0.6, 7), 12)
                Self.draw(String(repeating: "★", count: content.rating), font: SheetFonts.text(size), color: ink,
                          at: CGPoint(x: window.maxX - 2, y: window.minY - (layout.numberBand - size * 0.72) / 2), align: .right, in: context)
            }
            if layout.namesUnder {
                // Under the frame: on the sheet, below the strip, in the sheet's own writing.
                let size = min(max(ContactSheetLayout.nameBand(h) * 0.7, 8), 12)
                let stripBottom = window.maxY + layout.printBand + layout.perforation
                Self.draw(Self.stem(content.name), font: SheetFonts.text(size, weight: .medium), color: palette.writingDim,
                          at: CGPoint(x: window.minX + 1, y: stripBottom + size + 2), maxWidth: window.width, in: context)
            } else if compact, layout.showsNames, content.rating == 0, layout.frame.width >= 90 {
                // Compact has no band under its frames: on the edge, the name runs beside the number.
                let size = min(max(layout.numberBand * 0.6, 7), 11)
                Self.draw(Self.stem(content.name), font: SheetFonts.text(size, weight: .medium), color: inkDim,
                          at: CGPoint(x: window.maxX - 2, y: window.minY - (layout.numberBand - size * 0.72) / 2), align: .right,
                          maxWidth: window.width * 0.6, in: context)
            }
            guard !compact, layout.printBand >= 10 else { return }
            let size = min(max(layout.printBand * 0.62, 7.5), 11)
            let baseline = window.maxY + (layout.printBand + size * 0.7) / 2
            // The stock's name runs along the film's lower edge, every third frame, where no stars are.
            let labelled = !edgeLabel.isEmpty && index % 3 == 0 && content.rating == 0 && layout.frame.width >= 110
            if layout.showsNames && !layout.namesUnder {
                Self.draw(Self.stem(content.name), font: SheetFonts.text(size, weight: .medium), color: inkDim,
                          at: CGPoint(x: window.minX + 1, y: baseline), maxWidth: window.width * (content.rating > 0 || labelled ? 0.5 : 0.96), in: context)
            }
            if content.rating > 0 {
                Self.draw(String(repeating: "★", count: content.rating), font: SheetFonts.text(size * 1.15), color: ink,
                          at: CGPoint(x: window.maxX - 1, y: baseline), align: .right, in: context)
            } else if labelled {
                Self.draw(edgeLabel.uppercased(), font: SheetFonts.edge(size * 0.92), color: inkDim,
                          at: CGPoint(x: window.maxX - 1, y: baseline), align: .right, tracking: size * 0.1,
                          maxWidth: window.width * (layout.showsNames ? 0.48 : 0.96), in: context)
            }
        case .detail, .grid:
            let y = window.maxY + 17
            if showsNumbers {
                Self.draw(content.number, font: SheetFonts.edge(13), color: palette.writing, at: CGPoint(x: window.minX, y: y), in: context)
            }
            if layout.showsNames {
                Self.draw(content.name, font: SheetFonts.text(11, weight: .medium), color: palette.writing,
                          at: CGPoint(x: window.minX + (showsNumbers ? 30 : 0), y: y), maxWidth: window.width - (showsNumbers ? 30 : 0) - (content.rating > 0 ? 62 : 0), in: context)
            }
            if content.rating > 0 {
                Self.draw(String(repeating: "★", count: content.rating), font: SheetFonts.text(10.5), color: palette.writing,
                          at: CGPoint(x: window.maxX, y: y), align: .right, in: context)
            }
            if let caption = content.caption, !caption.isEmpty {
                Self.draw(caption, font: SheetFonts.text(10.5), color: palette.writingDim, at: CGPoint(x: window.minX, y: y + 16), maxWidth: window.width, in: context)
            }
            _ = h
        }
    }

    // MARK: Pencil

    /// The red pencil: a ring round a pick, a cross over a reject. Drawn over every frame, since a ring reaches past its own.
    func drawMark(_ context: CGContext, index: Int, _ content: SheetFrameContent) {
        guard showsMarks, let flag = content.flag else { return }
        for stroke in Self.strokes(flag, picture: layout.picture(index), name: content.name, tight: layout.style == .detail) {
            context.setFillColor(palette.pencil.copy(alpha: CGFloat(stroke.opacity)) ?? palette.pencil)
            context.addPath(stroke.path(progress: content.markProgress))
            context.fillPath()
        }
    }

    /// `tight`: the ring stays close to the picture, where there is no film round it to draw on.
    static func strokes(_ flag: PhotoSidecar.Flag, picture: CGRect, name: String, tight: Bool = false) -> [GreasePencil.Stroke] {
        let weight = GreasePencil.weight(forFrameWidth: picture.width)
        switch flag {
        case .pick:
            let rect = tight ? picture.insetBy(dx: -picture.width * 0.025, dy: -picture.height * 0.04) : GreasePencil.ringRect(around: picture)
            return GreasePencil.ring(in: rect, seed: name, weight: weight)
        case .reject: return GreasePencil.cross(in: picture, seed: name, weight: weight * 1.45)
        }
    }

    /// Everything a frame's mark can cover, to redraw when it changes.
    func markBounds(_ index: Int) -> CGRect {
        let picture = layout.picture(index)
        return GreasePencil.ringRect(around: picture).insetBy(dx: -picture.width * 0.08 - 6, dy: -picture.height * 0.1 - 6)
    }

    /// Where a frame's picture lies in its window: fitted whole, an upright one perhaps on its side.
    func pictureRect(_ index: Int, _ content: SheetFrameContent) -> CGRect {
        let window = layout.picture(index)
        guard let image = content.image else { return window }
        return ContactSheetLayout.fit(aspect: CGFloat(image.width) / CGFloat(max(image.height, 1)), in: window, sideways: sidewaysVerticals).rect
    }

    /// The pencil that boxes the frame the keys act on: the lab's red, as NEgs's grid draws its box in the accent.
    static let boxColour = SheetPalette.pencilRed

    /// The frame the keys act on is boxed by hand in red pencil, round the picture itself, so the eye finds it at
    /// once; other selected frames wear a thin line.
    func drawSelection(_ context: CGContext, index: Int, _ content: SheetFrameContent) {
        guard content.current || content.selected else { return }
        if content.current {
            let picture = pictureRect(index, content)
            let weight = min(max(layout.frame.width / 70, 1.6), 3.4)
            for stroke in GreasePencil.box(in: picture.insetBy(dx: -weight * 1.6, dy: -weight * 1.6), seed: content.name, weight: weight) {
                context.setFillColor(Self.boxColour.copy(alpha: CGFloat(stroke.opacity)) ?? Self.boxColour)
                context.addPath(stroke.path())
                context.fillPath()
            }
            return
        }
        let rect = layout.picture(index).insetBy(dx: -3.5, dy: -3.5)
        context.setStrokeColor(palette.cursor)
        if content.selected && !content.current {
            context.setAlpha(0.6)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            context.setAlpha(1)
            return
        }
        if content.selected {
            context.setAlpha(0.45)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            context.setAlpha(1)
        }
        let arm = max(min(rect.width, rect.height) * 0.16, 7), line: CGFloat = 2
        context.setLineWidth(line)
        context.setLineCap(.square)
        let r = rect.insetBy(dx: line / 2, dy: line / 2)
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            context.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            context.addLine(to: corner)
            context.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        context.strokePath()
    }

    // MARK: Helpers

    static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }

    /// Draws `image` upright in a context whose y axis points down.
    static func draw(_ image: CGImage, in rect: CGRect, turned: Bool = false, _ context: CGContext) {
        context.saveGState()
        if turned {
            // A quarter turn anticlockwise, as an upright frame lies on the strip.
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -.pi / 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width))
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        }
        context.restoreGState()
    }

    enum Align { case left, center, right }

    /// One line of text with its baseline at `point`, in a context whose y axis points down.
    static func draw(_ text: String, font: CTFont, color: CGColor, at point: CGPoint, align: Align = .left, tracking: CGFloat = 0,
                     maxWidth: CGFloat? = nil, in context: CGContext) {
        guard !text.isEmpty else { return }
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]
        if tracking != 0 { attributes[.init(kCTKernAttributeName as String)] = tracking }
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            guard let cut = CTLineCreateTruncatedLine(line, Double(max(maxWidth, 1)), .middle, ellipsis) else { return }
            line = cut
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = switch align { case .left: point.x; case .center: point.x - width / 2; case .right: point.x - width }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
