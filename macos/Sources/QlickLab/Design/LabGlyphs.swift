// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The lab's own pictograms, in a fine line: one stroke of about 1.5 pt at their usual size, no fill, square or
/// slightly rounded corners, drawn in code on a 24-unit grid (a memory card, prints, a strip of film, a developing
/// tank, an enlarger, a loupe, a 135 cartridge, an archive box…). Each stands beside its word (a sidebar row, a room):
/// a pictogram alone is hard to read. Where a row or a room names one (`lab.card`, `lab.tank`…), `LabSymbol` draws it;
/// any other name is a system symbol. Original drawings in the spirit of the darkroom, traced from nothing.
enum LabGlyph: String, CaseIterable, Sendable {
    /// Import: a memory card.
    case card
    /// Last Import: the card with an arrow going in.
    case cardIn
    /// The Library: two prints, one over the other.
    case prints
    /// All Photographs: one print.
    case print
    /// The Contact Sheet: a strip of film, its frames and sprocket holes.
    case strip
    /// A lens's aperture.
    case aperture
    /// An eye.
    case eye
    /// Recipes: a flask, its liquid's line.
    case flask
    /// Stocks: a 135 cartridge with its film drawn out.
    case stocks
    /// A Roll: the 135 cartridge and its tongue (provisional, until Quentin's drawing).
    case canister
    /// A Smart Roll: the cartridge, with a spark in the lab's red.
    case smartCanister
    /// Where Rolls are dropped: Quentin's cartridge drawing, only for "Drop Rolls here".
    case dropCanister
    /// The Archives: an archive box seen from the front, its hand hole and label holder.
    case archive
    /// A Box: the archive box in three quarters, its label on the front.
    case box
    /// By Date: a calendar.
    case calendar
    /// Picks: the pencil's ring.
    case ring
    /// Develop: the developing tank, its lid and its spiral reel.
    case tank
    /// Print: the enlarger, its head, column and baseboard.
    case enlarger
    /// Compare: the loupe laid on a frame.
    case loupe
    /// The light table.
    case lightTable
    /// A developing tray.
    case tray
    /// A film clip, to hang a strip to dry.
    case clip
    /// Scissors, to cut a strip.
    case scissors
    /// The grease pencil.
    case pencil
    /// A sheet of photographic paper, its corner turned.
    case paper
    /// The safelight.
    case safelight
    /// The frame arrow printed on the film's edge.
    case frameArrow

    /// The name a row or a room gives it.
    var symbol: String { "lab." + rawValue }

    init?(symbol: String) {
        guard symbol.hasPrefix("lab.") else { return nil }
        self.init(rawValue: String(symbol.dropFirst(4)))
    }

    /// The line: 1.5 units of the grid (about 1.1 pt at 18 pt, 1.5 pt at 24 pt), never under 1 pt nor over 1.75 pt, so
    /// a large pictogram keeps the fine line.
    static func lineWidth(side: CGFloat) -> CGFloat { min(1.75, max(1, side / 24 * 1.5)) }

    /// Draws the glyph in `rect` (square) in `ink`; `mark` is the lab's red, for the few that carry it.
    func draw(_ context: GraphicsContext, in rect: CGRect, ink: Color, mark: Color = Theme.accent) {
        let g = Grid(rect)
        let style = StrokeStyle(lineWidth: Self.lineWidth(side: g.side), lineCap: .round, lineJoin: .round)
        func line(_ build: (inout Path) -> Void) {
            var path = Path()
            build(&path)
            context.stroke(path, with: .color(ink), style: style)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 1) {
            line { $0.addRoundedRect(in: g.r(x, y, w, h), cornerSize: CGSize(width: g.s * radius, height: g.s * radius)) }
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat = 1.6, color: Color? = nil) {
            context.fill(Path(ellipseIn: g.r(x - d / 2, y - d / 2, d, d)), with: .color(color ?? ink))
        }
        /// Micro-text in condensed capitals, only where it can be read (48 pt and up).
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            guard g.side >= 44 else { return }
            context.draw(Text(text).font(.system(size: g.s * 2.6, weight: .semibold).width(.condensed)).foregroundColor(ink), at: g.p(x, y))
        }

        switch self {
        case .card, .cardIn:
            line { p in
                p.move(to: g.p(7.5, 3)); p.addLine(to: g.p(15, 3)); p.addLine(to: g.p(18.5, 6.5))
                p.addLine(to: g.p(18.5, 20)); p.addQuadCurve(to: g.p(17.5, 21), control: g.p(18.5, 21))
                p.addLine(to: g.p(6.5, 21)); p.addQuadCurve(to: g.p(5.5, 20), control: g.p(5.5, 21))
                p.addLine(to: g.p(5.5, 12.5)); p.addLine(to: g.p(6.5, 11.8)); p.addLine(to: g.p(6.5, 10.2)); p.addLine(to: g.p(5.5, 9.5))
                p.addLine(to: g.p(5.5, 5)); p.addQuadCurve(to: g.p(7.5, 3), control: g.p(5.5, 3))
                p.closeSubpath()
            }
            line { p in for x in stride(from: 8.5, through: 14.5, by: 2) { p.move(to: g.p(x, 5.5)); p.addLine(to: g.p(x, 8)) } }
            if self == .cardIn {
                line { p in
                    p.move(to: g.p(12, 11)); p.addLine(to: g.p(12, 17.5))
                    p.move(to: g.p(9.5, 15)); p.addLine(to: g.p(12, 17.5)); p.addLine(to: g.p(14.5, 15))
                }
            }

        case .print:
            printShape(g, line: line, x: 3.5, y: 4, w: 17, h: 16, picture: true)

        case .prints:
            line { p in
                p.move(to: g.p(8, 6)); p.addLine(to: g.p(8, 3)); p.addLine(to: g.p(21, 3)); p.addLine(to: g.p(21, 15)); p.addLine(to: g.p(18, 15))
            }
            printShape(g, line: line, x: 3, y: 7, w: 15, h: 14, picture: true)

        case .strip:
            box(2, 5, 20, 14, radius: 0.6)
            line { p in
                for x in stride(from: 3.6, through: 20.4, by: 2.8) {
                    p.move(to: g.p(x, 6.8)); p.addLine(to: g.p(x + 0.9, 6.8))
                    p.move(to: g.p(x, 17.2)); p.addLine(to: g.p(x + 0.9, 17.2))
                }
            }
            box(3.6, 8.8, 7.8, 6.4, radius: 0.5)
            box(12.6, 8.8, 7.8, 6.4, radius: 0.5)

        case .aperture:
            line { $0.addEllipse(in: g.r(3, 3, 18, 18)) }
            line { p in
                for i in 0..<6 {
                    let a = CGFloat(i) * .pi / 3 + 0.3
                    let inner = g.p(12 + cos(a) * 3.6, 12 + sin(a) * 3.6)
                    let b = a + .pi / 3
                    let next = g.p(12 + cos(b) * 3.6, 12 + sin(b) * 3.6)
                    p.move(to: inner); p.addLine(to: next)
                    p.move(to: next); p.addLine(to: g.p(12 + cos(b + 0.55) * 9, 12 + sin(b + 0.55) * 9))
                }
            }

        case .eye:
            line { p in
                p.move(to: g.p(2.5, 12)); p.addQuadCurve(to: g.p(21.5, 12), control: g.p(12, 2.5))
                p.addQuadCurve(to: g.p(2.5, 12), control: g.p(12, 21.5)); p.closeSubpath()
            }
            line { $0.addEllipse(in: g.r(8.5, 8.5, 7, 7)) }
            dot(12, 12, 2.4)

        case .flask:
            line { p in
                p.move(to: g.p(9.5, 3)); p.addLine(to: g.p(14.5, 3))
                p.move(to: g.p(10.3, 3)); p.addLine(to: g.p(10.3, 9.5)); p.addLine(to: g.p(4.6, 18.8))
                p.addQuadCurve(to: g.p(5.8, 21), control: g.p(4, 21)); p.addLine(to: g.p(18.2, 21))
                p.addQuadCurve(to: g.p(19.4, 18.8), control: g.p(20, 21)); p.addLine(to: g.p(13.7, 9.5)); p.addLine(to: g.p(13.7, 3))
            }
            line { p in p.move(to: g.p(7.2, 15.2)); p.addQuadCurve(to: g.p(16.8, 15.2), control: g.p(12, 13.4)) }

        case .stocks:
            cartridge(g, line: line, x: 2.5)
            line { p in
                p.move(to: g.p(11, 8)); p.addLine(to: g.p(21.5, 8)); p.addLine(to: g.p(21.5, 16)); p.addLine(to: g.p(11, 16))
                for x in stride(from: 13, through: 20, by: 2.4) { p.move(to: g.p(x, 9.6)); p.addLine(to: g.p(x + 0.8, 9.6)) }
                for x in stride(from: 13, through: 20, by: 2.4) { p.move(to: g.p(x, 14.4)); p.addLine(to: g.p(x + 0.8, 14.4)) }
            }

        case .canister, .smartCanister:
            // Provisional: the cartridge standing, its tongue of film cut at an angle (Quentin's drawing will replace it).
            cartridge(g, line: line, x: 3)
            line { p in
                p.move(to: g.p(11.5, 8.5)); p.addLine(to: g.p(17, 8.5)); p.addQuadCurve(to: g.p(20.5, 12), control: g.p(20.5, 8.5))
                p.addLine(to: g.p(20.5, 15.5)); p.addLine(to: g.p(11.5, 15.5))
                for x in [13.2, 15.6] { p.move(to: g.p(x, 10)); p.addLine(to: g.p(x + 0.8, 10)) }
            }
            label("135", 7, 12.2)
            if self == .smartCanister {
                context.fill(spark(g, centre: (19.5, 4.5), radius: 3.6), with: .color(mark))
            }

        case .dropCanister:
            // Qlick Lab: the place Rolls are dropped ("Drop Rolls here"): Quentin's own cartridge, traced from his drawing (800 × 560, scaled onto the grid):
            // the spool's knob on top only, two flanged caps, the seam, the film out at the right with its perforations,
            // the leader's lower half cut away in an S.
            let k: CGFloat = 22 / 715
            func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { g.p(1 + (x - 40) * k, (24 - 480 * k) / 2 + (y - 40) * k) }
            func rr(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
                let a = q(x0, y0), b = q(x1, y1); return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            }
            let corner = { (px: CGFloat) in CGSize(width: px * k * g.s, height: px * k * g.s) }
            line { p in
                p.addRoundedRect(in: rr(118, 40, 225, 85), cornerSize: corner(9))
                p.addRoundedRect(in: rr(38, 85, 305, 145), cornerSize: corner(13))
                p.move(to: q(48, 145)); p.addLine(to: q(48, 462))
                p.move(to: q(140, 145)); p.addLine(to: q(140, 462))
                p.move(to: q(295, 145)); p.addLine(to: q(295, 462))
                p.addRoundedRect(in: rr(38, 462, 305, 520), cornerSize: corner(13))
                // The film.
                p.move(to: q(305, 130)); p.addLine(to: q(718, 130)); p.addQuadCurve(to: q(755, 167), control: q(755, 130))
                p.addLine(to: q(755, 382)); p.addQuadCurve(to: q(718, 418), control: q(755, 418))
                p.addLine(to: q(565, 418)); p.addCurve(to: q(500, 470), control1: q(525, 418), control2: q(520, 470))
                p.addLine(to: q(305, 478))
            }
            // The perforations: small rounded windows from 32 pt up, short dashes below.
            let top: [CGFloat] = [311, 388, 463, 542, 622, 702], bottom: [CGFloat] = [318, 395, 472]
            line { p in
                if g.side >= 32 {
                    for x in top { p.addRoundedRect(in: rr(x - 11, 158, x + 11, 190), cornerSize: corner(4)) }
                    for x in bottom { p.addRoundedRect(in: rr(x - 11, 418, x + 11, 450), cornerSize: corner(4)) }
                } else {
                    for x in top.dropFirst().dropLast() { p.move(to: q(x - 14, 174)); p.addLine(to: q(x + 14, 174)) }
                }
            }

        case .archive:
            box(3, 4, 18, 17, radius: 0.8)
            line { p in p.move(to: g.p(3, 7.5)); p.addLine(to: g.p(21, 7.5)) }
            box(8.5, 10, 7, 3.6, radius: 0.4)
            line { p in p.move(to: g.p(9.5, 17)); p.addQuadCurve(to: g.p(14.5, 17), control: g.p(12, 18.8)) }

        case .box:
            line { p in
                p.move(to: g.p(3, 8)); p.addLine(to: g.p(15, 8)); p.addLine(to: g.p(15, 21)); p.addLine(to: g.p(3, 21)); p.closeSubpath()
                p.move(to: g.p(3, 8)); p.addLine(to: g.p(9, 3)); p.addLine(to: g.p(21, 3)); p.addLine(to: g.p(15, 8))
                p.move(to: g.p(21, 3)); p.addLine(to: g.p(21, 16)); p.addLine(to: g.p(15, 21))
            }
            box(5.5, 12, 7, 3.4, radius: 0.4)

        case .calendar:
            box(3.5, 5, 17, 16, radius: 1.4)
            line { p in
                p.move(to: g.p(3.5, 9.5)); p.addLine(to: g.p(20.5, 9.5))
                p.move(to: g.p(8, 3)); p.addLine(to: g.p(8, 6.5)); p.move(to: g.p(16, 3)); p.addLine(to: g.p(16, 6.5))
            }
            for (x, y) in [(8.0, 13.5), (12.0, 13.5), (16.0, 13.5), (8.0, 17.0), (12.0, 17.0)] { dot(x, y, 1.5) }

        case .ring:
            line { p in
                p.addEllipse(in: g.r(3.5, 5, 17, 14))
                p.move(to: g.p(16.5, 5.4)); p.addQuadCurve(to: g.p(20.8, 9.5), control: g.p(21.2, 6))
            }

        case .tank:
            // The lid with its funnel, the tank, and the spiral reel seen through.
            line { p in
                p.move(to: g.p(10, 2.5)); p.addLine(to: g.p(14, 2.5)); p.addLine(to: g.p(14, 5))
                p.move(to: g.p(10, 2.5)); p.addLine(to: g.p(10, 5))
                p.move(to: g.p(4.5, 5)); p.addLine(to: g.p(19.5, 5)); p.addLine(to: g.p(19.5, 7.5)); p.addLine(to: g.p(4.5, 7.5)); p.closeSubpath()
                p.move(to: g.p(5.5, 7.5)); p.addLine(to: g.p(5.5, 20)); p.addQuadCurve(to: g.p(7, 21.5), control: g.p(5.5, 21.5))
                p.addLine(to: g.p(17, 21.5)); p.addQuadCurve(to: g.p(18.5, 20), control: g.p(18.5, 21.5)); p.addLine(to: g.p(18.5, 7.5))
            }
            line { p in
                // The reel's spiral.
                var r: CGFloat = 4.6, a: CGFloat = 0
                p.move(to: g.p(12 + r, 14.5))
                while r > 0.8 { a += 0.35; r -= 0.13; p.addLine(to: g.p(12 + cos(a) * r, 14.5 + sin(a) * r)) }
            }

        case .enlarger:
            line { p in
                // Baseboard, column, the head and its lens, the light falling.
                p.move(to: g.p(2.5, 21)); p.addLine(to: g.p(21.5, 21))
                p.move(to: g.p(18, 21)); p.addLine(to: g.p(18, 2.5))
                p.move(to: g.p(18, 5)); p.addLine(to: g.p(14.5, 5))
                p.move(to: g.p(5, 3.5)); p.addLine(to: g.p(14.5, 3.5)); p.addLine(to: g.p(14.5, 8.5)); p.addLine(to: g.p(5, 8.5)); p.closeSubpath()
                p.move(to: g.p(8, 8.5)); p.addLine(to: g.p(8, 11)); p.addLine(to: g.p(11.5, 11)); p.addLine(to: g.p(11.5, 8.5))
            }
            line { p in
                p.move(to: g.p(8, 13)); p.addLine(to: g.p(5, 19))
                p.move(to: g.p(11.5, 13)); p.addLine(to: g.p(14.5, 19))
            }

        case .loupe:
            line { p in
                // The frame on the light, the loupe standing over it.
                p.move(to: g.p(2.5, 20.5)); p.addLine(to: g.p(21.5, 20.5))
                p.move(to: g.p(6, 20.5)); p.addLine(to: g.p(8, 9)); p.addLine(to: g.p(16, 9)); p.addLine(to: g.p(18, 20.5))
                p.move(to: g.p(8, 9)); p.addQuadCurve(to: g.p(16, 9), control: g.p(12, 2.5))
            }

        case .lightTable:
            line { p in
                p.move(to: g.p(2.5, 13)); p.addLine(to: g.p(21.5, 13)); p.addLine(to: g.p(19.5, 18)); p.addLine(to: g.p(4.5, 18)); p.closeSubpath()
                p.move(to: g.p(6, 18)); p.addLine(to: g.p(6, 21.5)); p.move(to: g.p(18, 18)); p.addLine(to: g.p(18, 21.5))
                for x in [7.0, 12.0, 17.0] { p.move(to: g.p(x, 10.5)); p.addLine(to: g.p(x, 8)) }
                p.move(to: g.p(3.5, 9)); p.addLine(to: g.p(5, 10.5)); p.move(to: g.p(20.5, 9)); p.addLine(to: g.p(19, 10.5))
            }

        case .tray:
            line { p in
                p.move(to: g.p(2.5, 10)); p.addLine(to: g.p(21.5, 10)); p.addLine(to: g.p(19.5, 18.5)); p.addLine(to: g.p(4.5, 18.5)); p.closeSubpath()
                p.move(to: g.p(5.5, 13.5)); p.addQuadCurve(to: g.p(12, 13.5), control: g.p(8.7, 12)); p.addQuadCurve(to: g.p(18.5, 13.5), control: g.p(15.3, 15))
            }
            box(8, 5.5, 8, 6.5, radius: 0.3)

        case .clip:
            line { p in
                p.move(to: g.p(12, 2.5)); p.addLine(to: g.p(12, 5.5))
                p.move(to: g.p(7, 5.5)); p.addLine(to: g.p(17, 5.5)); p.addLine(to: g.p(17, 10)); p.addLine(to: g.p(7, 10)); p.closeSubpath()
                p.move(to: g.p(8.5, 10)); p.addLine(to: g.p(8.5, 21.5)); p.move(to: g.p(15.5, 10)); p.addLine(to: g.p(15.5, 21.5))
                for y in stride(from: 12.5, through: 20, by: 2.6) { p.move(to: g.p(9.8, y)); p.addLine(to: g.p(9.8, y + 0.8)) }
            }

        case .scissors:
            line { p in
                p.addEllipse(in: g.r(3, 14, 6, 6)); p.addEllipse(in: g.r(15, 14, 6, 6))
                p.move(to: g.p(8, 14.8)); p.addLine(to: g.p(17.5, 3))
                p.move(to: g.p(16, 14.8)); p.addLine(to: g.p(6.5, 3))
            }

        case .pencil:
            line { p in
                p.move(to: g.p(4, 20)); p.addLine(to: g.p(5, 15.5)); p.addLine(to: g.p(16.5, 4)); p.addLine(to: g.p(20, 7.5)); p.addLine(to: g.p(8.5, 19)); p.closeSubpath()
                p.move(to: g.p(5, 15.5)); p.addLine(to: g.p(8.5, 19))
                p.move(to: g.p(14, 6.5)); p.addLine(to: g.p(17.5, 10))
            }
            dot(4.6, 19.4, 1.8, color: mark)

        case .paper:
            line { p in
                p.move(to: g.p(5, 3)); p.addLine(to: g.p(15, 3)); p.addLine(to: g.p(19, 7)); p.addLine(to: g.p(19, 21)); p.addLine(to: g.p(5, 21)); p.closeSubpath()
                p.move(to: g.p(15, 3)); p.addLine(to: g.p(15, 7)); p.addLine(to: g.p(19, 7))
            }
            label("RC", 12, 15)

        case .safelight:
            line { p in
                p.move(to: g.p(6, 3.5)); p.addLine(to: g.p(18, 3.5)); p.addLine(to: g.p(20, 13)); p.addLine(to: g.p(4, 13)); p.closeSubpath()
                p.move(to: g.p(9, 13)); p.addLine(to: g.p(9, 15.5)); p.addLine(to: g.p(15, 15.5)); p.addLine(to: g.p(15, 13))
                p.move(to: g.p(7, 18.5)); p.addLine(to: g.p(5.5, 21)); p.move(to: g.p(12, 18.5)); p.addLine(to: g.p(12, 21.5)); p.move(to: g.p(17, 18.5)); p.addLine(to: g.p(18.5, 21))
            }
            context.fill(Path(roundedRect: g.r(8.6, 7, 6.8, 3.4), cornerRadius: g.s * 0.6), with: .color(mark))

        case .frameArrow:
            line { p in p.move(to: g.p(3, 21)); p.addLine(to: g.p(21, 21)) }
            context.fill(Path { p in p.move(to: g.p(5, 7)); p.addLine(to: g.p(16, 12)); p.addLine(to: g.p(5, 17)); p.closeSubpath() }, with: .color(ink))
            label("24", 19, 12)
        }
    }

    // MARK: Parts

    /// The grid: 24 units across the square.
    struct Grid {
        let origin: CGPoint
        let s: CGFloat
        let side: CGFloat
        init(_ rect: CGRect) {
            side = min(rect.width, rect.height)
            s = side / 24
            origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s) }
    }

    /// A print: its border, the picture's window, a hill in it.
    private func printShape(_ g: Grid, line: ((inout Path) -> Void) -> Void, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, picture: Bool) {
        line { p in p.addRoundedRect(in: g.r(x, y, w, h), cornerSize: CGSize(width: g.s * 0.8, height: g.s * 0.8)) }
        guard picture else { return }
        let b: CGFloat = 2, wx = x + b, wy = y + b, ww = w - 2 * b, wh = h - b * 2.8
        line { p in
            p.addRect(g.r(wx, wy, ww, wh))
            p.move(to: g.p(wx, wy + wh)); p.addLine(to: g.p(wx + ww * 0.38, wy + wh * 0.45))
            p.addLine(to: g.p(wx + ww * 0.6, wy + wh * 0.75)); p.addLine(to: g.p(wx + ww * 0.76, wy + wh * 0.58)); p.addLine(to: g.p(wx + ww, wy + wh * 0.9))
        }
    }

    /// A 135 cartridge standing, `x` its left: the spool's knob, the caps, the body, the lip the film leaves by.
    private func cartridge(_ g: Grid, line: ((inout Path) -> Void) -> Void, x: CGFloat) {
        line { p in
            p.addRoundedRect(in: g.r(x + 2.8, 2.5, 2.8, 2), cornerSize: CGSize(width: g.s * 0.5, height: g.s * 0.5))
            // Qlick Lab: one spool end only, on top, as a real 135 cartridge; the bottom is its flat cap.
            p.addRoundedRect(in: g.r(x + 0.5, 4.5, 7.6, 17), cornerSize: CGSize(width: g.s * 1.2, height: g.s * 1.2))
            p.move(to: g.p(x + 0.5, 7)); p.addLine(to: g.p(x + 8.1, 7))
            p.move(to: g.p(x + 0.5, 19)); p.addLine(to: g.p(x + 8.1, 19))
        }
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
