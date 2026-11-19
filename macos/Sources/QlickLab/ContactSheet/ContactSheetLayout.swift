// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import Foundation

/// Where everything on a contact sheet goes: strips of 35 mm film cut to the sheet's width, their frames, perforations
/// and edge bands. Pure geometry from a frame count, a width and a frame size, so the window, the printed page and
/// the tests all lay a sheet out the same way, and a sheet of thousands of frames costs nothing until it's drawn.
///
/// The proportions are a 135 film's: a 36 × 24 mm frame every 38 mm, eight perforations to a frame.
struct ContactSheetLayout: Equatable, Sendable {
    typealias Style = SheetOptions.Style

    let style: Style
    let count: Int
    let width: CGFloat
    /// The picture window of one frame.
    let frame: CGSize
    let columns: Int
    /// Space kept at the top for the sheet's heading.
    let header: CGFloat
    let showsNames: Bool
    /// The film under the frames: its base and perforations.
    let showsFilm: Bool

    /// From one frame's left edge to the next.
    let pitch: CGFloat
    /// Film left of the first frame and right of the last.
    let lead: CGFloat
    /// A row of perforations.
    let perforation: CGFloat
    /// The band above the picture, where the frame number is printed.
    let numberBand: CGFloat
    /// The band under the picture: the file's name and the stars.
    let printBand: CGFloat
    /// Sheet showing between two strips (or two rows of the detailed view).
    let gap: CGFloat
    /// Sheet round the strips.
    let margin: CGFloat

    init(style: Style, count: Int, width: CGFloat, frameWidth: CGFloat, header: CGFloat = 0, showsNames: Bool = true, columns fixed: Int? = nil, margin: CGFloat? = nil,
         showsFilm: Bool = true) {
        self.style = style == .grid ? .detail : style
        self.showsFilm = showsFilm
        self.count = max(count, 0)
        self.width = max(width, 1)
        self.header = header
        self.showsNames = showsNames
        var w = max(frameWidth, 24)
        let m = margin ?? (style == .compact ? 14 : 26)
        self.margin = m
        func metrics(_ w: CGFloat) -> (pitch: CGFloat, lead: CGFloat) {
            switch style {
            case .classic, .compact: (w * 38 / 36, showsFilm ? w * 0.07 : 0)
            case .detail, .grid: (w + max(w * 0.09, 14), 0)
            }
        }
        var (pitch, lead) = metrics(w)
        let inner = self.width - 2 * m
        if let fixed {
            // A printed page: so many columns fill the width exactly.
            columns = max(fixed, 1)
            let unit = style == .detail ? (CGFloat(columns) + CGFloat(columns - 1) * 0.09) : (CGFloat(columns) * 38 / 36 + 0.14 - 2.0 / 36)
            w = inner / unit
            (pitch, lead) = metrics(w)
            if style == .detail { pitch = w * 1.09 }
        } else {
            let between = pitch - w
            columns = max(Int(((inner - 2 * lead + between) / pitch).rounded(.down)), 1)
        }
        self.pitch = pitch
        self.lead = lead
        let h = (w * 2 / 3).rounded()
        frame = CGSize(width: w.rounded(), height: h)
        switch style {
        case .classic:
            perforation = showsFilm ? (h * 0.15).rounded() : 0
            numberBand = max((h * 0.125).rounded(), 12)
            printBand = showsNames ? max((h * 0.115).rounded(), 11) : (h * 0.05).rounded()
            gap = max((h * 0.2).rounded(), 14)
        case .compact:
            perforation = showsFilm ? (h * 0.12).rounded() : 0
            numberBand = max((h * 0.115).rounded(), 10)
            printBand = (h * 0.03).rounded()
            gap = 3
        case .detail, .grid:
            perforation = 0
            numberBand = 0
            printBand = 50
            gap = 16
        }
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }
    var stripHeight: CGFloat { 2 * perforation + numberBand + frame.height + printBand }
    var rowPitch: CGFloat { stripHeight + gap }
    /// The length of a full strip.
    var stripLength: CGFloat { style == .detail ? CGFloat(columns) * pitch - (pitch - frame.width) : CGFloat(columns) * pitch - (pitch - frame.width) + 2 * lead }
    /// Strips are centred on the sheet.
    var originX: CGFloat { max(((width - stripLength) / 2).rounded(), margin) }
    var top: CGFloat { margin + header }
    var height: CGFloat { top + CGFloat(rows) * rowPitch - (rows > 0 ? gap : 0) + margin }

    func row(of index: Int) -> Int { index / columns }
    func column(of index: Int) -> Int { index % columns }
    func frames(inRow row: Int) -> Range<Int> { min(row * columns, count)..<min((row + 1) * columns, count) }

    /// The strip of film (or, in the detailed view, the row's band) for a row. The last one is cut after its last frame.
    func strip(_ row: Int) -> CGRect {
        let frames = frames(inRow: row).count
        let length = style == .detail ? stripLength : CGFloat(frames) * pitch - (pitch - frame.width) + 2 * lead
        return CGRect(x: originX, y: top + CGFloat(row) * rowPitch, width: length, height: stripHeight)
    }

    /// A frame's picture window.
    func picture(_ index: Int) -> CGRect {
        let row = row(of: index), column = column(of: index)
        return CGRect(x: originX + lead + CGFloat(column) * pitch, y: top + CGFloat(row) * rowPitch + perforation + numberBand,
                      width: frame.width, height: frame.height)
    }

    /// Everything that is a frame's: its picture, the bands above and under it, and half the space to its neighbours.
    func cell(_ index: Int) -> CGRect {
        let picture = picture(index), between = pitch - frame.width
        return CGRect(x: picture.minX - between / 2, y: top + CGFloat(row(of: index)) * rowPitch - gap / 2, width: pitch, height: rowPitch)
    }

    /// The frame whose picture is under `point`, with a little tolerance round it.
    func index(at point: CGPoint, slop: CGFloat = 3) -> Int? {
        guard count > 0, point.y >= top - slop else { return nil }
        let row = Int(((point.y - top) / rowPitch).rounded(.down))
        let column = Int(((point.x - originX - lead + (pitch - frame.width) / 2) / pitch).rounded(.down))
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        let index = row * columns + column
        guard index < count, picture(index).insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        return index
    }

    /// Rows that reach into `rect`.
    func rows(in rect: CGRect) -> Range<Int> {
        guard rows > 0 else { return 0..<0 }
        let first = Int(((rect.minY - top) / rowPitch).rounded(.down)), last = Int(((rect.maxY - top) / rowPitch).rounded(.down))
        let low = min(max(first, 0), rows), high = min(max(last + 1, 0), rows)
        return low..<max(low, high)
    }

    /// Frames whose pictures touch `rect`.
    func indices(in rect: CGRect) -> [Int] {
        rows(in: rect).flatMap { frames(inRow: $0) }.filter { picture($0).intersects(rect) }
    }

    /// The frame `rows` strips up or down from `index`, in the same column; the last frame for a short last strip.
    func vertical(from index: Int, by rows: Int) -> Int? {
        let target = index + rows * columns
        if target < 0 { return nil }
        if target >= count { return row(of: index) < self.rows - 1 ? count - 1 : nil }
        return target
    }

    // MARK: Perforations

    /// The perforations of a strip's top or bottom row: eight to a frame, as on 135 film.
    func perforations(strip: CGRect, top: Bool) -> [CGRect] {
        guard perforation > 0 else { return [] }
        let step = pitch / 8
        let size = CGSize(width: (step * 0.56).rounded(), height: (perforation * 0.52).rounded())
        let y = top ? strip.minY + (perforation - size.height) / 2 : strip.maxY - perforation + (perforation - size.height) / 2
        var holes: [CGRect] = []
        var x = strip.minX + step * 0.3
        while x + size.width <= strip.maxX - step * 0.1 {
            holes.append(CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height))
            x += step
        }
        return holes
    }

    /// How a picture `aspect` wide for its height sits in a frame's window: fitted whole, never cropped. An upright
    /// one turned a quarter fills the window like the others, as it lies on the film.
    static func fit(aspect: CGFloat, in window: CGRect, sideways: Bool) -> (rect: CGRect, turned: Bool) {
        guard aspect > 0, aspect.isFinite else { return (window, false) }
        let turned = sideways && aspect < 0.98
        let ratio = turned ? 1 / aspect : aspect
        var size = CGSize(width: window.width, height: window.width / ratio)
        if size.height > window.height { size = CGSize(width: window.height * ratio, height: window.height) }
        return (CGRect(x: window.midX - size.width / 2, y: window.midY - size.height / 2, width: size.width, height: size.height), turned)
    }
}
