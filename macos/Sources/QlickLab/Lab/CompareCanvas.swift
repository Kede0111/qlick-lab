// Qlick Lab — GPL-3.0-only.
import AppKit

/// Where a pane looks in its picture: `zoom` 1 fits it whole; `centre` is the point of the picture (0…1 each way)
/// at the pane's middle.
struct CompareViewport: Equatable, Sendable {
    var zoom: CGFloat = 1
    var centre = CGPoint(x: 0.5, y: 0.5)

    /// From a quarter of the fitted size (zoomed out, the whole picture small in the pane) to 32 times it.
    static let zooms: ClosedRange<CGFloat> = 0.25...32
}

/// Pure geometry of the comparison, shared by the canvas, its labels and the tests.
enum CompareGeometry {
    static let gap: CGFloat = 2

    /// The panes' rectangles: side by side up to three, two rows of two for four.
    static func panes(_ count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count == 4 ? 2 : count, rows = count == 4 ? 2 : 1
        let width = (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        return (0..<count).map { index in
            CGRect(x: bounds.minX + CGFloat(index % columns) * (width + gap), y: bounds.minY + CGFloat(index / columns) * (height + gap),
                   width: width, height: height)
        }
    }

    /// The scale (points per pixel) that fits a picture in a pane.
    static func fit(_ picture: CGSize, in pane: CGRect, padding: CGFloat = 0) -> CGFloat {
        guard picture.width > 0, picture.height > 0 else { return 1 }
        return min((pane.width - 2 * padding) / picture.width, (pane.height - 2 * padding) / picture.height)
    }

    /// The viewport kept inside its picture: no further than its edges once it's larger than the pane, centred while smaller.
    static func clamped(_ viewport: CompareViewport, picture: CGSize, pane: CGRect) -> CompareViewport {
        var next = viewport
        next.zoom = min(max(viewport.zoom, CompareViewport.zooms.lowerBound), CompareViewport.zooms.upperBound)
        let scale = fit(picture, in: pane) * next.zoom
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        func clamp(_ centre: CGFloat, shown: CGFloat, pane: CGFloat) -> CGFloat {
            guard shown > pane else { return 0.5 }
            let half = pane / 2 / shown
            return min(max(centre, half), 1 - half)
        }
        next.centre = CGPoint(x: clamp(viewport.centre.x, shown: shown.width, pane: pane.width), y: clamp(viewport.centre.y, shown: shown.height, pane: pane.height))
        return next
    }

    /// Where the picture is drawn in the pane for a viewport.
    static func rect(of picture: CGSize, in pane: CGRect, viewport: CompareViewport) -> CGRect {
        let scale = fit(picture, in: pane) * viewport.zoom
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: pane.midX - viewport.centre.x * shown.width, y: pane.midY - viewport.centre.y * shown.height, width: shown.width, height: shown.height)
    }

    /// The viewport after zooming to `zoom` with the picture's point under `anchor` staying there.
    static func zoomed(_ viewport: CompareViewport, to zoom: CGFloat, about anchor: CGPoint, picture: CGSize, pane: CGRect) -> CompareViewport {
        let before = rect(of: picture, in: pane, viewport: viewport)
        guard before.width > 0, before.height > 0 else { return viewport }
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        var next = viewport
        next.zoom = min(max(zoom, CompareViewport.zooms.lowerBound), CompareViewport.zooms.upperBound)
        let scale = fit(picture, in: pane) * next.zoom
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        // The pane's middle shows the point that keeps `unit` under the anchor.
        next.centre = CGPoint(x: unit.x - (anchor.x - pane.midX) / shown.width, y: unit.y - (anchor.y - pane.midY) / shown.height)
        return clamped(next, picture: picture, pane: pane)
    }
}

/// The comparison's surface: two to four pictures side by side, zoomed and moved together, or one picture split
/// between its two states by a line that's dragged. One view draws them all, so their zoom and position are one
/// state and never drift apart.
@MainActor final class CompareCanvas: NSView {
    struct Pane {
        var image: CGImage?
        /// A lesser image standing in while the real one develops.
        var standIn: CGImage?
        var busy = false
    }

    var panes: [Pane] = [] { didSet { needsDisplay = true } }
    /// The first two panes are one picture's two states, split by a line.
    var split = false { didSet { needsDisplay = true } }
    var splitPosition: CGFloat = 0.5 { didSet { needsDisplay = true } }
    /// Every pane follows the same viewport.
    var linked = true { didSet { if linked { viewports = Array(repeating: viewports[min(focused, viewports.count - 1)], count: 4) }; needsDisplay = true } }
    private(set) var viewports = Array(repeating: CompareViewport(), count: 4)
    var focused = 0 { didSet { needsDisplay = true } }
    var onFocus: (Int) -> Void = { _ in }
    /// A double-click on a pane: back to Develop on it.
    var onOpen: (Int) -> Void = { _ in }
    var onViewport: (CompareViewport) -> Void = { _ in }
    var onSplit: (CGFloat) -> Void = { _ in }
    /// Keys the room handles (marks, arrows); true if taken.
    var onKey: (NSEvent) -> Bool = { _ in false }

    private var dragging: (pane: Int, last: CGPoint, divider: Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var count: Int { split ? 1 : panes.count }
    private var rects: [CGRect] { CompareGeometry.panes(count, in: bounds) }

    private func picture(_ pane: Int) -> CGSize? {
        // A split's two states are the same picture: the developed one gives its size.
        let index = split ? min(1, panes.count - 1) : pane
        guard panes.indices.contains(index), let image = panes[index].image ?? panes[index].standIn ?? (split ? panes.first?.image ?? panes.first?.standIn : nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    var viewport: CompareViewport { viewports[min(focused, viewports.count - 1)] }

    func set(_ viewport: CompareViewport, pane: Int? = nil) {
        if linked || pane == nil { viewports = Array(repeating: viewport, count: 4) } else if let pane { viewports[pane] = viewport }
        clampAll()
        needsDisplay = true
        onViewport(self.viewport)
    }

    private func clampAll() {
        let rects = rects
        for index in rects.indices { if let picture = picture(index) { viewports[index] = CompareGeometry.clamped(viewports[index], picture: picture, pane: rects[index]) } }
        if linked, let first = rects.indices.first { viewports = Array(repeating: viewports[first], count: 4) }
    }

    /// The zoom at which one pixel of the picture is one pixel of the screen.
    func actualZoom(pane: Int) -> CGFloat {
        let rects = rects
        guard rects.indices.contains(pane), let picture = picture(pane) else { return 1 }
        let fit = CompareGeometry.fit(picture, in: rects[pane]) * (window?.backingScaleFactor ?? 2)
        return max(1 / max(fit, 0.0001), 1)
    }

    /// What share of its pixels the focused pane shows: 1 is one screen pixel for one of the picture's.
    var magnification: CGFloat {
        let rects = rects
        let pane = min(focused, max(rects.count - 1, 0))
        guard rects.indices.contains(pane), let picture = picture(pane) else { return 1 }
        return CompareGeometry.fit(picture, in: rects[pane]) * viewports[pane].zoom * (window?.backingScaleFactor ?? 2)
    }

    func zoomToFit() { set(CompareViewport()) }

    /// The focused pane at `zoom` times its fitted size, about its middle.
    func setZoom(_ zoom: CGFloat) {
        let rects = rects
        let pane = min(focused, max(rects.count - 1, 0))
        guard rects.indices.contains(pane), let picture = picture(pane) else { return }
        set(CompareGeometry.zoomed(viewports[pane], to: zoom, about: CGPoint(x: rects[pane].midX, y: rects[pane].midY), picture: picture, pane: rects[pane]), pane: pane)
    }

    func zoomToActual(about point: CGPoint? = nil) {
        let rects = rects
        let pane = min(focused, max(rects.count - 1, 0))
        guard rects.indices.contains(pane), let picture = picture(pane) else { return }
        let anchor = point ?? CGPoint(x: rects[pane].midX, y: rects[pane].midY)
        set(CompareGeometry.zoomed(viewports[pane], to: actualZoom(pane: pane), about: anchor, picture: picture, pane: rects[pane]), pane: pane)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampAll()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0.035, alpha: 1))
        context.fill(bounds)
        let rects = rects
        for (index, rect) in rects.enumerated() {
            context.saveGState()
            context.clip(to: rect)
            context.setFillColor(CGColor(gray: 0.02, alpha: 1))
            context.fill(rect)
            if split {
                drawSplit(context, in: rect)
            } else if panes.indices.contains(index) {
                draw(panes[index], viewport: viewports[index], in: rect, context)
            }
            context.restoreGState()
            if !split, rects.count > 1, index == focused {
                // The pane the keys act on: a thin white line at its foot.
                context.setFillColor(CGColor(gray: 1, alpha: 0.9))
                context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
            }
        }
    }

    private func draw(_ pane: Pane, viewport: CompareViewport, in rect: CGRect, _ context: CGContext) {
        guard let image = pane.image ?? pane.standIn else { return }
        let picture = CGSize(width: image.width, height: image.height)
        let target = CompareGeometry.rect(of: picture, in: rect, viewport: viewport)
        // Pixels as they are once they're seen one for one: sharpness is judged on them.
        let scale = target.width / picture.width * (window?.backingScaleFactor ?? 2)
        context.interpolationQuality = scale >= 0.999 ? .none : .high
        ContactSheetRenderer.draw(image, in: target, context)
    }

    private func drawSplit(_ context: CGContext, in rect: CGRect) {
        guard panes.count >= 2 else { return }
        let x = rect.minX + rect.width * splitPosition
        context.saveGState()
        context.clip(to: CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
        draw(panes[1], viewport: viewports[0], in: rect, context)
        context.restoreGState()
        context.saveGState()
        context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: x - rect.minX, height: rect.height))
        draw(panes[0], viewport: viewports[0], in: rect, context)
        context.restoreGState()
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: x - 0.5, y: rect.minY, width: 1, height: rect.height))
        let handle = CGRect(x: x - 13, y: rect.midY - 13, width: 26, height: 26)
        context.setShadow(offset: .zero, blur: 6, color: CGColor(gray: 0, alpha: 0.5))
        context.fillEllipse(in: handle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        for direction in [-1.0, 1.0] {
            context.move(to: CGPoint(x: x + direction * 3.5, y: handle.midY - 4))
            context.addLine(to: CGPoint(x: x + direction * 7.5, y: handle.midY))
            context.addLine(to: CGPoint(x: x + direction * 3.5, y: handle.midY + 4))
        }
        context.strokePath()
    }

    // MARK: Events

    private func pane(at point: CGPoint) -> Int? { rects.firstIndex { $0.contains(point) } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let pane = pane(at: point) else { return }
        if !split, pane != focused { focused = pane; onFocus(pane) }
        // A double-click goes back to Develop, on the photograph under it.
        if event.clickCount == 2 { onOpen(pane); return }
        let divider = split && abs(point.x - (bounds.minX + bounds.width * splitPosition)) < 16
        dragging = (pane, point, divider)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        defer { drag.last = point; dragging = drag }
        if drag.divider || (split && viewports[0].zoom <= 1.001) {
            splitPosition = min(max((point.x - bounds.minX) / max(bounds.width, 1), 0.02), 0.98)
            onSplit(splitPosition)
            return
        }
        pan(pane: drag.pane, dx: point.x - drag.last.x, dy: point.y - drag.last.y)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    private func pan(pane: Int, dx: CGFloat, dy: CGFloat) {
        let rects = rects
        guard rects.indices.contains(pane), let picture = picture(pane) else { return }
        let shown = CompareGeometry.rect(of: picture, in: rects[pane], viewport: viewports[pane])
        guard shown.width > 0, shown.height > 0 else { return }
        var next = viewports[pane]
        next.centre.x -= dx / shown.width
        next.centre.y -= dy / shown.height
        set(next, pane: pane)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pane = pane(at: point), let picture = picture(pane) else { return }
        // A mouse's wheel zooms, as in Develop (Réglages); a trackpad pans, ⌘ or ⌥ zooms.
        let wheel = !event.hasPreciseScrollingDeltas && event.phase == [] && event.momentumPhase == []
        let zooms = switch CanvasScale.scrollZoom { case .always: true; case .wheel: wheel; case .option: false }
        if event.momentumPhase != [], zooms { return }
        if zooms || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let factor = pow(1.0025, event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
            set(CompareGeometry.zoomed(viewports[pane], to: viewports[pane].zoom * factor, about: point, picture: picture, pane: rects[pane]), pane: pane)
        } else {
            let precise = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
            pan(pane: pane, dx: event.scrollingDeltaX * precise, dy: event.scrollingDeltaY * precise)
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pane = pane(at: point), let picture = picture(pane) else { return }
        set(CompareGeometry.zoomed(viewports[pane], to: viewports[pane].zoom * (1 + event.magnification), about: point, picture: picture, pane: rects[pane]), pane: pane)
    }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }
}
