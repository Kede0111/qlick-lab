// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The lab's own icons: solid glyphs drawn in code on a 20-unit grid (an SD card, prints, a film strip, an aperture,
/// a canister, an archive box…), crisp from 14 to 20 points. Where a sidebar row or a room names one (`lab.card`,
/// `lab.canister`…), `LabSymbol` draws it; any other name is a system symbol.
enum LabGlyph: String, CaseIterable, Sendable {
    /// Import: a memory card.
    case card
    /// Last Import: the card with an arrow going in.
    case cardIn
    /// The Library: two prints, one over the other.
    case prints
    /// All Photographs: one print.
    case print
    /// The Contact Sheet: a strip of film, torn at one end.
    case strip
    /// Develop: the lens's aperture.
    case aperture
    /// Compare: an eye with an iris for a pupil.
    case eye
    /// Recipes: a flask.
    case flask
    /// Stocks: a canister with its film drawn out.
    case stocks
    /// A Roll: a canister and its leader.
    case canister
    /// A Smart Roll: the canister, with a spark in the lab's red.
    case smartCanister
    /// The Archives: an archive box seen from the front, its hand hole and label holder.
    case archive
    /// A Box: the archive box in three quarters, its label on the front.
    case box
    /// By Date: a calendar.
    case calendar
    /// Picks: the pencil's ring.
    case ring

    /// The name a row or a room gives it.
    var symbol: String { "lab." + rawValue }

    init?(symbol: String) {
        guard symbol.hasPrefix("lab.") else { return nil }
        self.init(rawValue: String(symbol.dropFirst(4)))
    }

    /// Draws the glyph in `rect` (square) in `ink`; `mark` is the lab's red, for the few that carry it.
    func draw(_ context: GraphicsContext, in rect: CGRect, ink: Color, mark: Color = Theme.accent) {
        let g = Grid(rect)
        let shading = GraphicsContext.Shading.color(ink)
        // Cuts through what's drawn: the gaps between parts, the windows of a print, the holes of the film.
        func cut(_ path: Path) {
            var c = context
            c.blendMode = .destinationOut
            c.fill(path, with: .color(.black))
        }
        func cutLine(_ path: Path, width: CGFloat) {
            var c = context
            c.blendMode = .destinationOut
            c.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: g.s * width, lineCap: .round, lineJoin: .round))
        }
        switch self {
        case .card, .cardIn:
            var body = Path()
            body.move(to: g.p(5.6, 2))
            body.addLine(to: g.p(12.4, 2))
            body.addLine(to: g.p(15.6, 5.2))
            body.addLine(to: g.p(15.6, 16.6))
            body.addQuadCurve(to: g.p(14.2, 18), control: g.p(15.6, 18))
            body.addLine(to: g.p(5.8, 18))
            body.addQuadCurve(to: g.p(4.4, 16.6), control: g.p(4.4, 18))
            // The notch of the lock, on the left.
            body.addLine(to: g.p(4.4, 10.4))
            body.addLine(to: g.p(5.2, 9.8))
            body.addLine(to: g.p(5.2, 8.2))
            body.addLine(to: g.p(4.4, 7.6))
            body.addLine(to: g.p(4.4, 3.2))
            body.addQuadCurve(to: g.p(5.6, 2), control: g.p(4.4, 2))
            body.closeSubpath()
            context.fill(body, with: shading)
            // The contacts.
            for x in stride(from: 6.4, through: 12.4, by: 2) {
                cut(Path(roundedRect: g.r(x, 3.6, 1.15, 3.2), cornerRadius: g.s * 0.3))
            }
            if self == .cardIn {
                // An arrow going down into the card.
                var arrow = Path()
                arrow.move(to: g.p(10, 9))
                arrow.addLine(to: g.p(10, 15))
                arrow.move(to: g.p(7.6, 12.8))
                arrow.addLine(to: g.p(10, 15.3))
                arrow.addLine(to: g.p(12.4, 12.8))
                cutLine(arrow, width: 1.5)
            } else {
                cut(Path(roundedRect: g.r(7, 13.3, 6, 1.5), cornerRadius: g.s * 0.5))
            }

        case .print:
            drawPrint(context, g, x: 2.5, y: 3, w: 15, h: 14, shading: shading, cut: cut)

        case .prints:
            drawPrint(context, g, x: 6, y: 1.8, w: 12.2, h: 11.4, shading: shading, cut: cut, picture: false)
            // The front print stands clear of the one behind.
            cut(Path(roundedRect: g.r(0.6, 5.6, 14.2, 13.6), cornerRadius: g.s * 1.4))
            drawPrint(context, g, x: 1.8, y: 6.8, w: 11.8, h: 11.4, shading: shading, cut: cut)

        case .strip:
            var film = Path()
            film.move(to: g.p(1.2, 4))
            film.addLine(to: g.p(16.6, 4))
            // Torn at the right end.
            let tear: [(CGFloat, CGFloat)] = [(17.4, 5.2), (16.8, 6.6), (18.2, 8), (17.3, 9.6), (18.6, 11.1), (17.6, 12.5), (18.4, 14.2), (17.5, 16)]
            for (x, y) in tear { film.addLine(to: g.p(x, y)) }
            film.addLine(to: g.p(1.2, 16))
            film.closeSubpath()
            context.fill(film, with: shading)
            for x in stride(from: 2.2, through: 15.4, by: 2.4) {
                cut(Path(roundedRect: g.r(x, 5, 1.3, 1.6), cornerRadius: g.s * 0.3))
                cut(Path(roundedRect: g.r(x, 13.4, 1.3, 1.6), cornerRadius: g.s * 0.3))
            }
            cut(Path(roundedRect: g.r(2.4, 7.6, 6.2, 4.8), cornerRadius: g.s * 0.5))
            cut(Path(roundedRect: g.r(9.8, 7.6, 6.2, 4.8), cornerRadius: g.s * 0.5))

        case .aperture:
            context.drawLayer { layer in
                drawAperture(layer, g, centre: (10, 10), radius: 7.1, opening: 2.9, shading: shading)
            }
            context.stroke(Path(ellipseIn: g.r(1.1, 1.1, 17.8, 17.8)), with: shading, lineWidth: g.s * 1.3)

        case .eye:
            var lids = Path()
            lids.move(to: g.p(1, 10))
            lids.addQuadCurve(to: g.p(19, 10), control: g.p(10, 0.2))
            lids.addQuadCurve(to: g.p(1, 10), control: g.p(10, 19.8))
            lids.closeSubpath()
            context.fill(lids, with: shading)
            cut(Path { p in
                p.move(to: g.p(3.1, 10))
                p.addQuadCurve(to: g.p(16.9, 10), control: g.p(10, 2.5))
                p.addQuadCurve(to: g.p(3.1, 10), control: g.p(10, 17.5))
                p.closeSubpath()
            })
            // In a layer of its own, so the blades' lines cut the iris only.
            context.drawLayer { layer in
                drawAperture(layer, g, centre: (10, 10), radius: 4.9, opening: 1.9, shading: shading, blades: 0.6)
            }

        case .flask:
            var flask = Path()
            flask.move(to: g.p(7.6, 3.4))
            flask.addLine(to: g.p(7.6, 8))
            flask.addLine(to: g.p(3, 15.6))
            flask.addQuadCurve(to: g.p(4.6, 18), control: g.p(2.3, 18))
            flask.addLine(to: g.p(15.4, 18))
            flask.addQuadCurve(to: g.p(17, 15.6), control: g.p(17.7, 18))
            flask.addLine(to: g.p(12.4, 8))
            flask.addLine(to: g.p(12.4, 3.4))
            context.stroke(flask, with: shading, style: StrokeStyle(lineWidth: g.s * 1.5, lineCap: .round, lineJoin: .round))
            // The rim.
            context.fill(Path(roundedRect: g.r(6.2, 1.6, 7.6, 1.9), cornerRadius: g.s * 0.6), with: shading)
            // What's in it, up to the line.
            var liquid = Path()
            liquid.move(to: g.p(5.5, 11.6))
            liquid.addLine(to: g.p(14.5, 11.6))
            liquid.addLine(to: g.p(17, 15.6))
            liquid.addQuadCurve(to: g.p(15.4, 18), control: g.p(17.7, 18))
            liquid.addLine(to: g.p(4.6, 18))
            liquid.addQuadCurve(to: g.p(3, 15.6), control: g.p(2.3, 18))
            liquid.closeSubpath()
            context.fill(liquid, with: shading)
            cut(Path(ellipseIn: g.r(8.2, 13.6, 1.8, 1.8)))
            cut(Path(ellipseIn: g.r(11.4, 15.2, 1.2, 1.2)))

        case .stocks:
            drawCanister(context, g, x: 1.6, shading: shading, cut: cut)
            // The film drawn out, perforated, cut to its tongue.
            var film = Path()
            film.move(to: g.p(9.4, 5.4))
            film.addLine(to: g.p(14.2, 5.4))
            film.addQuadCurve(to: g.p(15.6, 8.6), control: g.p(15.4, 5.6))
            film.addLine(to: g.p(17.6, 8.6))
            film.addQuadCurve(to: g.p(18.6, 9.6), control: g.p(18.6, 8.6))
            film.addLine(to: g.p(18.6, 14.6))
            film.addLine(to: g.p(9.4, 14.6))
            film.closeSubpath()
            context.fill(film, with: shading)
            for x in stride(from: 10.4, through: 16.4, by: 2.1) {
                cut(Path(roundedRect: g.r(x, 12.6, 1.1, 1.2), cornerRadius: g.s * 0.25))
            }
            for x in [10.4, 12.5] { cut(Path(roundedRect: g.r(x, 6.2, 1.1, 1.2), cornerRadius: g.s * 0.25)) }

        case .canister, .smartCanister:
            drawCanister(context, g, x: 4.4, shading: shading, cut: cut)
            // A short leader at the lip.
            var tongue = Path()
            tongue.move(to: g.p(12.2, 6.6))
            tongue.addLine(to: g.p(14, 6.6))
            tongue.addQuadCurve(to: g.p(15, 9.4), control: g.p(15, 6.8))
            tongue.addLine(to: g.p(16.2, 9.4))
            tongue.addQuadCurve(to: g.p(17, 10.2), control: g.p(17, 9.4))
            tongue.addLine(to: g.p(17, 13.4))
            tongue.addLine(to: g.p(12.2, 13.4))
            tongue.closeSubpath()
            context.fill(tongue, with: shading)
            if self == .smartCanister {
                // The spark of a Roll filled by rules, clear of the canister.
                cut(Path(ellipseIn: g.r(12.6, -0.6, 8.2, 8.2)))
                context.fill(spark(g, centre: (16.7, 3.5), radius: 3.4), with: .color(mark))
            }

        case .archive:
            // Lid, its band overhanging the body.
            context.fill(Path(roundedRect: g.r(1.4, 3, 17.2, 4.4), cornerRadius: g.s * 0.8), with: shading)
            context.fill(Path(roundedRect: g.r(2.4, 8.2, 15.2, 9.6), cornerRadius: g.s * 0.8), with: shading)
            // The hand hole in the lid's band, the label holder and its card on the front.
            cut(Path(roundedRect: g.r(7.4, 4.5, 5.2, 1.5), cornerRadius: g.s * 0.75))
            cut(Path(roundedRect: g.r(5.4, 10.6, 9.2, 5), cornerRadius: g.s * 0.6))
            context.fill(Path(roundedRect: g.r(6.6, 11.8, 6.8, 2.6), cornerRadius: g.s * 0.3), with: shading)
            cut(Path(roundedRect: g.r(7.6, 12.7, 4.8, 0.8), cornerRadius: g.s * 0.4))

        case .box:
            // Three quarters: the front, the side going back to the right, the lid on top.
            var side = Path()
            side.move(to: g.p(13.6, 8))
            side.addLine(to: g.p(18.4, 4.8))
            side.addLine(to: g.p(18.4, 14.4))
            side.addLine(to: g.p(13.6, 17.8))
            side.closeSubpath()
            context.fill(side, with: shading)
            var lid = Path()
            lid.move(to: g.p(1, 5.2))
            lid.addLine(to: g.p(5.6, 2))
            lid.addLine(to: g.p(19, 2))
            lid.addLine(to: g.p(19, 5))
            lid.addLine(to: g.p(14.4, 8.4))
            lid.addLine(to: g.p(1, 8.4))
            lid.closeSubpath()
            context.fill(lid, with: shading)
            context.fill(Path(g.r(1.6, 8.4, 12, 9.4)), with: shading)
            // The edges, cut thin: lid from body, front from side, the lid's top from its band.
            var edges = Path()
            edges.move(to: g.p(1, 8.6)); edges.addLine(to: g.p(14.2, 8.6)); edges.addLine(to: g.p(18.8, 5.4))
            edges.move(to: g.p(13.6, 8.8)); edges.addLine(to: g.p(13.6, 17.8))
            edges.move(to: g.p(1.4, 5.3)); edges.addLine(to: g.p(14.4, 5.3)); edges.addLine(to: g.p(18.6, 2.3))
            cutLine(edges, width: 0.75)
            // The label on the front.
            cut(Path(roundedRect: g.r(3.6, 11, 7.8, 4.4), cornerRadius: g.s * 0.4))
            cut(Path(roundedRect: g.r(15.4, 9.2, 1.6, 3), cornerRadius: g.s * 0.8))

        case .calendar:
            context.stroke(Path(roundedRect: g.r(2.6, 4.6, 14.8, 13), cornerRadius: g.s * 1.6), with: shading, lineWidth: g.s * 1.4)
            context.fill(Path(g.r(2.6, 4.6, 14.8, 4.2)), with: shading)
            context.fill(Path(roundedRect: g.r(1.9, 3.9, 16.2, 5), cornerRadius: g.s * 2), with: shading)
            for x in [6.2, 12.4] {
                cut(Path(roundedRect: g.r(x - 0.4, 1, 2.2, 4.6), cornerRadius: g.s * 1.1))
                context.fill(Path(roundedRect: g.r(x, 1.6, 1.4, 4.4), cornerRadius: g.s * 0.7), with: shading)
            }
            for (i, j) in [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1)] {
                context.fill(Path(roundedRect: g.r(5.2 + CGFloat(i) * 3.6, 10.6 + CGFloat(j) * 3.3, 2.2, 2), cornerRadius: g.s * 0.35), with: shading)
            }
            context.fill(Path(roundedRect: g.r(12.4, 13.9, 2.2, 2), cornerRadius: g.s * 0.35), with: .color(mark))

        case .ring:
            // A ring drawn in one stroke, as the pencil does: a little more than round, its end past its start.
            var ring = Path()
            let steps = 48
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let angle = -2.2 + t * (2 * .pi + 0.55)
                let radius = 6.6 + 0.9 * t - 0.35 * sin(t * .pi * 3)
                let point = g.p(10 + cos(angle) * radius * 1.04, 10.2 + sin(angle) * radius * 0.96)
                if step == 0 { ring.move(to: point) } else { ring.addLine(to: point) }
            }
            context.stroke(ring, with: shading, style: StrokeStyle(lineWidth: g.s * 1.7, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Parts

    /// The 20-unit grid mapped onto a square.
    struct Grid {
        let origin: CGPoint
        let s: CGFloat
        init(_ rect: CGRect) {
            let side = min(rect.width, rect.height)
            s = side / 20
            origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s) }
    }

    /// A print: its border, the picture's window, a hill and the sun in it.
    private func drawPrint(_ context: GraphicsContext, _ g: Grid, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                           shading: GraphicsContext.Shading, cut: (Path) -> Void, picture: Bool = true) {
        context.fill(Path(roundedRect: g.r(x, y, w, h), cornerRadius: g.s * 1.2), with: shading)
        let border = w * 0.12
        let window = g.r(x + border, y + border, w - 2 * border, h - border * 2.6)
        cut(Path(roundedRect: window, cornerRadius: g.s * 0.4))
        guard picture else { return }
        let wx = x + border, wy = y + border, ww = w - 2 * border, wh = h - border * 2.6
        var hill = Path()
        hill.move(to: g.p(wx, wy + wh))
        hill.addLine(to: g.p(wx + ww * 0.36, wy + wh * 0.42))
        hill.addLine(to: g.p(wx + ww * 0.58, wy + wh * 0.72))
        hill.addLine(to: g.p(wx + ww * 0.74, wy + wh * 0.54))
        hill.addLine(to: g.p(wx + ww, wy + wh))
        hill.closeSubpath()
        context.fill(hill, with: shading)
        let sun = ww * 0.15
        context.fill(Path(ellipseIn: g.r(wx + ww * 0.7, wy + wh * 0.14, sun, sun)), with: shading)
    }

    /// An aperture: blades round a six-sided opening, each parted from the next by a thin line.
    private func drawAperture(_ context: GraphicsContext, _ g: Grid, centre: (CGFloat, CGFloat), radius: CGFloat, opening: CGFloat,
                              shading: GraphicsContext.Shading, blades: CGFloat = 0.85) {
        var cutting = context
        cutting.blendMode = .destinationOut
        let (cx, cy) = centre
        context.fill(Path(ellipseIn: g.r(cx - radius, cy - radius, radius * 2, radius * 2)), with: shading)
        func vertex(_ i: Int) -> (CGFloat, CGFloat) {
            let a = CGFloat(i) * .pi / 3 - .pi / 2 + 0.25
            return (cx + cos(a) * opening, cy + sin(a) * opening)
        }
        var hexagon = Path()
        for i in 0..<6 {
            let (x, y) = vertex(i)
            if i == 0 { hexagon.move(to: g.p(x, y)) } else { hexagon.addLine(to: g.p(x, y)) }
        }
        hexagon.closeSubpath()
        cutting.fill(hexagon, with: .color(.black))
        // Each blade's edge runs on from a corner of the opening to the rim.
        var edges = Path()
        for i in 0..<6 {
            let (x0, y0) = vertex(i), (x1, y1) = vertex(i + 1)
            let dx = x1 - x0, dy = y1 - y0, length = (dx * dx + dy * dy).squareRoot()
            let reach = radius * 1.05
            edges.move(to: g.p(x1, y1))
            edges.addLine(to: g.p(x1 + dx / length * reach, y1 + dy / length * reach))
        }
        cutting.stroke(edges, with: .color(.black), style: StrokeStyle(lineWidth: g.s * blades, lineCap: .round))
    }

    /// A 35 mm canister standing, `x` its left: the spool's knob, the caps, the body, the lip the film leaves by.
    private func drawCanister(_ context: GraphicsContext, _ g: Grid, x: CGFloat, shading: GraphicsContext.Shading, cut: (Path) -> Void) {
        context.fill(Path(roundedRect: g.r(x + 2.4, 0.9, 2.4, 2), cornerRadius: g.s * 0.4), with: shading)
        context.fill(Path(roundedRect: g.r(x, 2.6, 7.2, 2.2), cornerRadius: g.s * 0.7), with: shading)
        context.fill(Path(g.r(x + 0.4, 4.2, 6.4, 11.6)), with: shading)
        context.fill(Path(roundedRect: g.r(x, 15.2, 7.2, 2.2), cornerRadius: g.s * 0.7), with: shading)
        context.fill(Path(roundedRect: g.r(x + 2.6, 17, 2, 1.6), cornerRadius: g.s * 0.4), with: shading)
        // The lip, standing out on the right.
        context.fill(Path(roundedRect: g.r(x + 6.2, 4.6, 1.8, 10.8), cornerRadius: g.s * 0.6), with: shading)
        // The caps parted from the body, and a light down the curve.
        cut(Path(g.r(x + 0.2, 4.7, 6, 0.55)))
        cut(Path(g.r(x + 0.2, 14.75, 6, 0.55)))
        cut(Path(roundedRect: g.r(x + 1.5, 6.4, 1, 7), cornerRadius: g.s * 0.5))
    }

    /// A four-pointed spark.
    private func spark(_ g: Grid, centre: (CGFloat, CGFloat), radius: CGFloat) -> Path {
        let (cx, cy) = centre
        var path = Path()
        let waist = radius * 0.28
        path.move(to: g.p(cx, cy - radius))
        path.addQuadCurve(to: g.p(cx + radius, cy), control: g.p(cx + waist, cy - waist))
        path.addQuadCurve(to: g.p(cx, cy + radius), control: g.p(cx + waist, cy + waist))
        path.addQuadCurve(to: g.p(cx - radius, cy), control: g.p(cx - waist, cy + waist))
        path.addQuadCurve(to: g.p(cx, cy - radius), control: g.p(cx - waist, cy - waist))
        path.closeSubpath()
        return path
    }
}

/// One of the lab's glyphs at a size.
struct LabGlyphView: View {
    let glyph: LabGlyph
    var size: CGFloat = 16
    var color: Color = Theme.label

    var body: some View {
        Canvas { context, canvas in
            glyph.draw(context, in: CGRect(origin: .zero, size: canvas), ink: color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row's or a room's symbol: the lab's own glyph for a `lab.` name, else the system's symbol at `points`.
struct LabSymbol: View {
    let symbol: String
    var points: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color

    var body: some View {
        if let glyph = LabGlyph(symbol: symbol) {
            // Drawn a little larger than the text it stands by, as a symbol is.
            LabGlyphView(glyph: glyph, size: (points * 1.38).rounded(), color: color)
        } else if !symbol.isEmpty {
            Image(systemName: symbol).font(.system(size: points, weight: weight)).foregroundStyle(color)
        }
    }
}
