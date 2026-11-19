import AppKit
import QuartzCore
import SwiftUI

/// AppKit owns scrolling and trackpad magnification, including gesture inertia.
/// Core Animation composites the photograph, so zoom and pan never redraw it.
struct PreviewCanvas: NSViewRepresentable {
    /// An IOSurface or CGImage, scaled to fill the photograph's layout size.
    let image: AnyObject
    let size: CGSize
    let rotation: Int
    let crop: CropSettings
    let border: BorderSettings?
    let filmTexture: CGImage?
    let filmStrip: FilmStrip?
    let zoomCommand: UUID
    let fit: Bool
    var scale: CanvasScale?
    /// Where the print is on screen, for the caption and label (§4.1, §4.2).
    var geometry: CanvasGeometry?
    /// T is held: the print on screen turns half a turn (`PhotographView.turned`).
    var upsideDown = false
    /// The image is a settled frame, not one rendered at canvas size while a
    /// slider moves or before a discrete edit's export-size render: fitted,
    /// it's shown resampled to the screen's pixels (`FitDownscale`).
    var settled = true
    /// Qlick Lab: the part of the photograph on screen, developed at its own pixels, and where it lies in the
    /// photograph (its pixels, from the top left): drawn over the image, which has fewer (`EditorModel.detail`).
    var detail: (image: AnyObject, rect: CGRect)?
    /// A double-click on the photograph; true if it's zoomed from fitting.
    var doubleClick: ((_ zoomed: Bool) -> Void)?

    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        // Qlick Lab: its insets are the floating panel's room, not the window's.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        scroll.documentView = PhotographView()
        scroll.setAccessibilityLabel("Photograph preview")
        scroll.setAccessibilityHelp("Pinch to zoom, scroll or drag to pan, double-click to zoom to 1:1 there or back to fit. Hold T to turn it upside down.")
        return scroll
    }

    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        scale?.view = scroll
        scroll.canvasScale = scale
        // Qlick Lab: the floating panel's room, set before this view existed.
        if let scale, scroll.contentInsets.right != scale.trailingObstruction || scroll.contentInsets.left != scale.leadingObstruction {
            scroll.contentInsets = NSEdgeInsets(top: 0, left: scale.leadingObstruction, bottom: 0, right: scale.trailingObstruction)
            DispatchQueue.main.async { if scroll.fitting { scroll.applyZoom() } }
        }
        scroll.geometry = geometry
        scroll.doubleClick = doubleClick
        let photo = scroll.documentView as! PhotographView
        let cropped = crop.size(of: size)
        let displaySize = rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped
        let documentSize = border.map { border in
            let canvas = border.canvas(for: displaySize, strip: filmStrip)
            return border.instagram ? border.instagramCanvas(for: canvas) : canvas
        } ?? displaySize
        let oldSize = photo.frame.size, oldPhotoSize = photo.displaySize
        let commanded = scroll.lastCommand != zoomCommand
        // A different crop (such as an undone one) is a new picture: fit it.
        let recropped = photo.crop != crop && oldSize.width != 0
        if recropped { scroll.fitting = true }
        photo.settled = settled
        photo.show(image, size: size, rotation: rotation, crop: crop, border: border, filmTexture: filmTexture, filmStrip: filmStrip)
        photo.turned = upsideDown
        photo.showDetail(detail?.image, rect: detail?.rect ?? .zero)
        if oldSize != documentSize {
            if commanded || scroll.fitting || oldSize.width == 0 {
                photo.setFrameSize(documentSize)
            } else if oldPhotoSize != displaySize {
                scroll.keepVisibleContent(resizingDocumentFrom: oldSize, to: documentSize)
            } else {
                // Only the border changed: keep the photograph where it is.
                scroll.keepPhotographInPlace(resizingDocumentFrom: oldSize, to: documentSize)
            }
        }
        if commanded {
            scroll.lastCommand = zoomCommand; scroll.fitting = fit
            scroll.applyZoom()
        } else if oldSize != documentSize || recropped, scroll.fitting { scroll.applyZoom() }
    }
}

/// How many screen pixels a pixel of the photograph covers at the canvas's
/// zoom. A render this much smaller than the photograph looks the same on screen.
@MainActor final class CanvasScale {
    fileprivate(set) weak var view: ImageScrollView?
    /// Qlick Lab: the zoom changed (a pinch, a command, the window's size).
    var changed: (() -> Void)?
    /// Qlick Lab: the canvas scrolled or zoomed: another part of the photograph is on screen.
    var moved: (() -> Void)?
    /// The part of the whole photograph on screen, as fractions of its width and height from its top left,
    /// before the crop and the turns; nil with no canvas, or with none of it on screen.
    var visiblePhotoRect: CGRect? { fixedVisible ?? (view?.documentView as? PhotographView)?.visiblePhotoRect() }
    /// Stands in for the canvas in tests, as `fixed`.
    var fixedVisible: CGRect?
    /// Qlick Lab: the floating panel's width over the canvas's right edge. A fitted photograph keeps clear of it; a
    /// zoomed one runs under it and scrolls out from under it.
    var trailingObstruction: CGFloat = 0 { didSet { if trailingObstruction != oldValue { applyObstructions() } } }
    /// Qlick Lab: the same at the left edge, for the information panel.
    var leadingObstruction: CGFloat = 0 { didSet { if leadingObstruction != oldValue { applyObstructions() } } }
    private func applyObstructions() {
        guard let view else { return }
        view.contentInsets = NSEdgeInsets(top: 0, left: leadingObstruction, bottom: 0, right: trailingObstruction)
        view.contentView.bounds = view.contentView.constrainBoundsRect(view.contentView.bounds)
        if view.fitting { view.applyZoom() } else { view.reflectScrolledClipView(view.contentView) }
    }
    /// Qlick Lab: the zoom tool. A click on the photograph zooms in a step there, ⌥-click out a step.
    var loupe = false { didSet { if loupe != oldValue { refreshCursor() } } }
    /// Qlick Lab: the white balance eyedropper: a click on the photograph balances it there.
    var picking = false { didSet { if picking != oldValue { refreshCursor() } } }
    /// The eyedropper's click, as fractions of the whole photograph from its top left, before crop and turns.
    var picked: ((CGPoint) -> Void)?
    /// Qlick Lab: the photograph's right-click menu, for a click at `point` (the document's).
    var contextMenu: ((_ point: CGPoint) -> NSMenu?)?
    /// A room covers the canvas: its pointer isn't the photograph's.
    var covered = false { didSet { if covered != oldValue { refreshCursor() } } }
    /// Space is held: the hand, to drag the photograph about, whatever the tool.
    var spaceHeld = false { didSet { if spaceHeld != oldValue { refreshCursor() } } }
    /// The zoom fitted the photograph (true) or zoomed it (false).
    var loupeZoomed: ((_ fit: Bool) -> Void)?
    /// How scrolling zooms the photograph (Settings › Speed): a mouse's wheel only, every scroll, or only with ⌥.
    enum ScrollZoom: String, CaseIterable { case wheel, always, option }
    static var scrollZoom: ScrollZoom {
        get { UserDefaults.standard.string(forKey: "qlick.scrollZoom").flatMap(ScrollZoom.init) ?? .always }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "qlick.scrollZoom") }
    }
    static var wheelZooms: Bool { scrollZoom != .option }

    /// The zoom's steps, in screen pixels per photograph pixel: Lightroom's, from an eighth to 16 to 1.
    static let steps: [CGFloat] = [0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 2, 3, 4, 8, 16]
    /// The canvas's zoom, in screen pixels per photograph pixel, and whether it's fitted.
    var ratio: CGFloat? { screenPixelsPerPhotoPixel }
    var fitting: Bool { view?.fitting ?? true }
    /// What fitting the photograph would show, in screen pixels per photograph pixel.
    var fitRatio: CGFloat? {
        guard let view, let window = view.window, let document = view.documentView, document.frame.width > 0 else { return nil }
        let backing = window.backingScaleFactor
        return ImageScrollView.magnification(fitting: true, document: document.frame.size, viewport: view.fitViewport, backingScale: backing) * backing
    }
    /// Zooms to `ratio` screen pixels per photograph pixel about the middle of the view (or `point`, the
    /// document's), or fits it when nil.
    func zoom(to ratio: CGFloat?, at point: CGPoint? = nil) {
        guard let view else { return }
        view.zoom(to: ratio, at: point)
        loupeZoomed?(ratio == nil)
    }
    /// A step in or out from the zoom shown; out past fitting fits.
    func step(in zoomIn: Bool, at point: CGPoint? = nil) {
        guard let current = ratio else { return }
        let fit = fitRatio ?? current
        if zoomIn {
            let next = Self.steps.first { $0 > current * 1.01 && $0 > fit * 1.01 } ?? Self.steps.last!
            zoom(to: next, at: point)
        } else {
            guard let next = Self.steps.last(where: { $0 < current * 0.99 }), next > fit * 1.01 else { return zoom(to: nil) }
            zoom(to: next, at: point)
        }
    }
    /// The pointer's look follows the tool, Space and ⌥.
    func refreshCursor() {
        guard let view, let document = view.documentView else { return }
        view.window?.invalidateCursorRects(for: document)
        // Under a still pointer, cursor rects alone don't change it.
        if !covered, let window = view.window, document.bounds.contains(document.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            (document as? PhotographView)?.cursorNow.set()
        }
    }
    /// Stands in for the canvas in tests, which have no window.
    var fixed: CGFloat?
    var debugDescription: String {
        guard let view else { return "no view" }
        return "frame=\(view.contentView.frame) bounds=\(view.contentView.bounds) doc=\(view.documentView?.frame ?? .zero) insets=\(view.contentInsets.right) obstruction=\(trailingObstruction) mag=\(view.magnification) content=\(view.contentSize)"
    }
    /// Qlick Lab: the scale a photograph of this size is fitted at, before it's laid out.
    func fitScale(for photo: CGSize) -> CGFloat? {
        guard let view, let window = view.window, photo.width > 0, photo.height > 0 else { return nil }
        let backing = window.backingScaleFactor
        return ImageScrollView.magnification(fitting: true, document: photo, viewport: view.fitViewport, backingScale: backing) * backing
    }
    var screenPixelsPerPhotoPixel: CGFloat? {
        if let fixed { return fixed }
        guard let view, let window = view.window, view.magnification > 0 else { return nil }
        return view.magnification * window.backingScaleFactor
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        // Qlick Lab: centred in the part the floating panel leaves.
        let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsets()
        let scale = bounds.width / max(frame.width, 1)
        let right = insets.right * scale, left = insets.left * scale
        if bounds.width - right - left > documentView.frame.width { bounds.origin.x = (documentView.frame.width - bounds.width + right - left) / 2 }
        if bounds.height > documentView.frame.height { bounds.origin.y = (documentView.frame.height - bounds.height) / 2 }
        return bounds
    }
}

/// The print's rectangle on the canvas, cut to what's on screen, in the
/// scroll view's top-left coordinates. Zoomed in, it's the whole viewport,
/// so scrolling doesn't move the caption or the label.
@MainActor @Observable final class CanvasGeometry {
    private(set) var print = CGRect.zero
    /// The scroll view's size.
    private(set) var viewport = CGSize.zero
    private(set) var zoomed = false

    func update(print: CGRect, viewport: CGSize, zoomed: Bool) {
        // Whole points: sub-point scroll jitter never reaches SwiftUI.
        let print = print.integral
        if print != self.print { self.print = print }
        if viewport != self.viewport { self.viewport = viewport }
        if zoomed != self.zoomed { self.zoomed = zoomed }
    }
}

final class ImageScrollView: NSScrollView {
    var lastCommand: UUID?
    var fitting = true { didSet { if fitting != oldValue { photograph?.refreshSharp() } } }
    private var photograph: PhotographView? { documentView as? PhotographView }
    var doubleClick: ((_ zoomed: Bool) -> Void)?
    var geometry: CanvasGeometry? { didSet { if geometry !== oldValue { observeBounds(); reportGeometry() } } }
    /// Space left and right of a fitted photograph (§2.3). The caption and
    /// label bands above and below are outside the scroll view.
    nonisolated static let fitInset: CGFloat = 48
    private var lastViewport = CGSize.zero
    override func layout() {
        super.layout()
        if lastViewport != contentSize {
            lastViewport = contentSize
            if fitting { applyZoom() }
        }
        reportGeometry()
    }
    /// The viewport a fitted photograph fills.
    var fitViewport: CGSize {
        let obstruction = (canvasScale?.trailingObstruction ?? 0) + (canvasScale?.leadingObstruction ?? 0)
        return Self.fitViewport(CGSize(width: max(contentSize.width - obstruction, 1), height: contentSize.height))
    }
    static func fitViewport(_ size: CGSize) -> CGSize { CGSize(width: max(size.width - fitInset * 2, 1), height: size.height) }
    func applyZoom() {
        guard let documentView, documentView.frame.width > 0, contentSize.width > 0 else { return }
        let size = documentView.frame.size
        let amount = Self.magnification(fitting: fitting, document: size, viewport: fitViewport, backingScale: window?.backingScaleFactor ?? 2)
        setMagnification(min(max(amount, minMagnification), maxMagnification), centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        reportGeometry()
        photograph?.refreshSharp()
    }
    /// Every scroll and zoom, gestures included, moves the clip view's bounds.
    weak var canvasScale: CanvasScale?
    private var reportedMagnification: CGFloat = 0
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if magnification != reportedMagnification { reportedMagnification = magnification; canvasScale?.changed?() }
        canvasScale?.moved?()
        photograph?.refreshSharp()
    }

    // Written on the main actor; read once more by deinit, when nothing else holds the object.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    private func observeBounds() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        guard geometry != nil else { return }
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportGeometry() }
        }
    }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func reportGeometry() {
        guard let geometry, let documentView, documentView.frame.width > 0 else { return }
        var print = documentView.convert(documentView.bounds, to: self)
        if !isFlipped { print.origin.y = bounds.height - print.maxY }
        geometry.update(print: print.intersection(CGRect(origin: .zero, size: bounds.size)), viewport: bounds.size, zoomed: zoomedFromFit)
    }
    /// 1:1 is one photograph pixel per screen pixel. Fitting shows the whole
    /// photograph, but never enlarges a small one past 1:1.
    static func magnification(fitting: Bool, document: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGFloat {
        let oneToOne = 1 / backingScale
        guard fitting else { return oneToOne }
        return min(viewport.width / document.width, viewport.height / document.height, oneToOne)
    }
    /// Zoomed in or out from fitting the window. A zoom that happens to
    /// match the fit, such as 1:1 on a small photograph, isn't.
    var zoomedFromFit: Bool {
        guard !fitting, let documentView else { return false }
        return Self.zoomed(magnification, minimum: minMagnification, maximum: maxMagnification, document: documentView.frame.size,
                           viewport: fitViewport, backingScale: window?.backingScaleFactor ?? 2)
    }
    static func zoomed(_ magnification: CGFloat, minimum: CGFloat, maximum: CGFloat, document: CGSize, viewport: CGSize, backingScale: CGFloat) -> Bool {
        guard document.width > 0, document.height > 0, viewport.width > 0, viewport.height > 0 else { return false }
        let fit = min(max(Self.magnification(fitting: true, document: document, viewport: viewport, backingScale: backingScale), minimum), maximum)
        return abs(magnification / fit - 1) > 0.005
    }
    /// A double-click fits a zoomed photograph. On a fitted one at `point` (the document's) it zooms to 1:1
    /// there, keeping that place under the pointer.
    func doubleClicked(at point: CGPoint? = nil) {
        if let point, !zoomedFromFit {
            zoomKeeping(point, at: 1 / (window?.backingScaleFactor ?? 2))
            reportGeometry()
            return
        }
        if let doubleClick { doubleClick(zoomedFromFit) } else { fitting = true; applyZoom() }
    }
    /// A higher-resolution render of the same photograph replaces the shown
    /// one; keep the same region on screen at the same apparent scale.
    func keepVisibleContent(resizingDocumentFrom old: CGSize, to new: CGSize) {
        guard let documentView else { return }
        let visible = contentView.bounds
        let center = CGPoint(x: visible.midX / old.width, y: visible.midY / old.height)
        let ratio = old.width / new.width
        documentView.setFrameSize(new)
        magnification = min(max(magnification * ratio, minMagnification), maxMagnification)
        let bounds = contentView.bounds
        contentView.scroll(to: CGPoint(x: center.x * new.width - bounds.width / 2, y: center.y * new.height - bounds.height / 2))
        reflectScrolledClipView(contentView)
    }
    func keepPhotographInPlace(resizingDocumentFrom old: CGSize, to new: CGSize) {
        guard let documentView else { return }
        let origin = contentView.bounds.origin
        documentView.setFrameSize(new)
        contentView.scroll(to: CGPoint(x: origin.x + (new.width - old.width) / 2, y: origin.y + (new.height - old.height) / 2))
        reflectScrolledClipView(contentView)
    }
    override func magnify(with event: NSEvent) { fitting = false; super.magnify(with: event) }
    /// Qlick Lab: a right-click on the photograph or beside it opens Develop's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let canvasScale, !canvasScale.covered, let documentView else { return super.menu(for: event) }
        return canvasScale.contextMenu?(documentView.convert(event.locationInWindow, from: nil)) ?? super.menu(for: event)
    }
    /// Qlick Lab: the zoom tool's click at `point` (the document's): a step in, or out with ⌥.
    func loupeClick(at point: CGPoint, out: Bool) {
        canvasScale?.step(in: !out, at: point)
        reportGeometry()
    }
    /// Qlick Lab: to `ratio` screen pixels per photograph pixel about `point` (the document's; else the middle of
    /// what's shown), or fitted when nil.
    func zoom(to ratio: CGFloat?, at point: CGPoint? = nil) {
        guard let ratio else { fitting = true; applyZoom(); return }
        let backing = window?.backingScaleFactor ?? 2
        let visible = contentView.bounds
        fitting = false
        setMagnification(min(max(ratio / backing, minMagnification), maxMagnification), centeredAt: point ?? CGPoint(x: visible.midX, y: visible.midY))
        reportGeometry()
    }
    /// Qlick Lab: a zoom to `target` (the scroll view's magnification) that keeps `point` (the document's) where it
    /// is on screen; down to fitting, which it then is. Shift-drag and the wheel zoom this way.
    func zoomKeeping(_ point: CGPoint, at target: CGFloat) {
        let fit = Self.magnification(fitting: true, document: documentView?.frame.size ?? .zero, viewport: fitViewport, backingScale: window?.backingScaleFactor ?? 2)
        if target <= fit * 1.005 {
            if !fitting { fitting = true; applyZoom(); canvasScale?.loupeZoomed?(true) }
            return
        }
        fitting = false
        setMagnification(min(max(target, minMagnification), maxMagnification), centeredAt: point)
        canvasScale?.loupeZoomed?(false)
    }

    override func scrollWheel(with event: NSEvent) {
        // Qlick Lab: scrolling zooms about the pointer (Settings › Speed): a mouse's wheel, with or without smooth
        // scrolling, or every scroll; ⌥ always does. Its momentum is let go, so the zoom stops with the fingers.
        let mode = CanvasScale.scrollZoom
        let wheel = !event.hasPreciseScrollingDeltas && event.phase == [] && event.momentumPhase == []
        let zooms = event.modifierFlags.contains(.option) || mode == .always || (mode == .wheel && wheel)
        guard zooms, event.scrollingDeltaY != 0 || event.momentumPhase != [] else { return super.scrollWheel(with: event) }
        if event.momentumPhase != [] { return }
        let center = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        // Whole lines are a notch each; smooth deltas are points.
        let amount = event.hasPreciseScrollingDeltas ? max(min(event.scrollingDeltaY, 40), -40) * 0.008 : max(min(event.scrollingDeltaY, 6), -6) * 0.14
        var target = magnification * exp(amount)
        // Zooming out stops at fitting, which it then is.
        let fit = Self.magnification(fitting: true, document: documentView?.frame.size ?? .zero, viewport: fitViewport, backingScale: window?.backingScaleFactor ?? 2)
        if amount < 0, target <= fit * 1.005 {
            if !fitting { fitting = true; applyZoom(); canvasScale?.loupeZoomed?(true) }
            return
        }
        target = min(max(target, minMagnification), maxMagnification)
        fitting = false
        setMagnification(target, centeredAt: center)
        canvasScale?.loupeZoomed?(false)
    }
}

extension NSWindow {
    /// A point in the window's coordinates, in its backing pixels.
    func backingPoint(_ point: CGPoint) -> CGPoint { convertToBacking(CGRect(origin: point, size: .zero)).origin }
    func pointFromBacking(_ point: CGPoint) -> CGPoint { convertFromBacking(CGRect(origin: point, size: .zero)).origin }
}

final class PhotographView: NSView {
    /// The print, with its border: turned half a turn about the middle of
    /// what's on screen while T is held. Only the layers turn; the
    /// photograph, its layout and the caption and label over it don't change.
    private let turn = CALayer()
    /// The crop: it clips the photograph and takes the quarter turns.
    private let clip = CALayer()
    /// The whole photograph, straightened inside the crop.
    private let photo = CALayer()
    /// Over `photo` once the fitted view settles: the whole photograph
    /// resampled to the physical pixels it covers, drawn 1:1 on the pixel
    /// grid (`FitDownscale`). Hidden whenever it doesn't match the canvas.
    let sharp = CALayer()
    /// Qlick Lab: over `photo`, the part of it on screen at its own pixels (`showDetail`), in the photograph's
    /// own layer, so the crop, the straightening and the turns carry it.
    private let detail = CALayer()
    private var detailRect = CGRect.zero
    private var borderLayers: BorderLayers!
    private var image: AnyObject?
    private var size = CGSize.zero
    private var rotation = 0
    private(set) var crop = CropSettings()
    private var border: BorderSettings?
    private var filmTexture: CGImage?
    private var filmStrip: FilmStrip?
    /// Upside down, while T is held.
    var turned = false { didSet { if turned != oldValue { placeTurn() } } }
    /// The photograph's size on the canvas, after cropping and rotation.
    var displaySize: CGSize {
        let cropped = crop.size(of: size)
        return rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped
    }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.magnificationFilter = .linear
        photo.isOpaque = true
        // Drawn 1:1, so no mipmaps.
        sharp.contentsGravity = .resize
        sharp.minificationFilter = .linear
        sharp.magnificationFilter = .linear
        sharp.isOpaque = true
        sharp.isHidden = true
        detail.contentsGravity = .resize
        detail.minificationFilter = .trilinear
        detail.magnificationFilter = .linear
        detail.isOpaque = true
        detail.isHidden = true
        let none = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        photo.actions = none; clip.actions = none; turn.actions = none; sharp.actions = none; detail.actions = none
        clip.masksToBounds = true
        photo.addSublayer(detail)
        clip.addSublayer(photo)
        clip.addSublayer(sharp)
        turn.addSublayer(clip)
        layer?.addSublayer(turn)
        borderLayers = BorderLayers(in: turn, around: clip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: AnyObject, size: CGSize, rotation: Int, crop: CropSettings = CropSettings(), border: BorderSettings? = nil, filmTexture: CGImage? = nil, filmStrip: FilmStrip? = nil) {
        guard image !== self.image || size != self.size || rotation != self.rotation || crop != self.crop
            || border != self.border || filmTexture !== self.filmTexture || filmStrip != self.filmStrip else { return }
        self.image = image; self.size = size; self.rotation = rotation; self.crop = crop
        self.border = border; self.filmTexture = filmTexture; self.filmStrip = filmStrip
        photo.contents = image
        needsLayout = true
        // A new picture never shows the last one's resample, not even for a frame.
        refreshSharp()
    }

    /// Qlick Lab: shows `image` over the photograph's `rect` (its pixels, from the top left), or nothing.
    func showDetail(_ image: AnyObject?, rect: CGRect) {
        guard image !== detail.contents as AnyObject? || rect != detailRect || (image == nil) != detail.isHidden else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        detailRect = rect
        detail.contents = image
        detail.isHidden = image == nil
        placeDetail()
        CATransaction.commit()
    }
    /// Layers are y-up: the rectangle's top-left origin flips.
    private func placeDetail() {
        detail.frame = CGRect(x: detailRect.minX, y: size.height - detailRect.maxY, width: detailRect.width, height: detailRect.height)
    }
    /// Qlick Lab: the part of the whole photograph on screen, as fractions of its width and height from its top
    /// left, before the crop and the turns: the box around the canvas's corners, as the photograph's layer sees them.
    func visiblePhotoRect() -> CGRect? {
        guard let layer, size.width > 0, size.height > 0, let clipView = enclosingScrollView?.contentView else { return nil }
        let visible = convert(clipView.bounds, from: clipView).intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0, photo.bounds.width > 0, photo.bounds.height > 0 else { return nil }
        let corners = [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                       CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)]
            .map { layer.convert($0, to: photo) }
        let bounds = photo.bounds
        let xs = corners.map { ($0.x - bounds.minX) / bounds.width }, ys = corners.map { 1 - ($0.y - bounds.minY) / bounds.height }
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return box.isNull || box.width <= 0 || box.height <= 0 ? nil : box
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        turn.bounds = CGRect(origin: .zero, size: bounds.size)
        placeTurn()
        Self.layout(clip: clip, photo: photo, size: size, crop: crop, rotation: rotation, center: CGPoint(x: bounds.midX, y: bounds.midY))
        placeDetail()
        borderLayers.layout(border, photo: displaySize, host: turn, texture: filmTexture, filmStrip: filmStrip)
        refreshSharp()
        CATransaction.commit()
    }

    // MARK: The fitted photograph, resampled

    /// Set by the canvas: false for frames rendered at canvas size.
    var settled = true { didSet { if settled != oldValue { refreshSharp() } } }
    private struct SharpKey: Equatable {
        let source: ObjectIdentifier, seed: UInt32, width: Int, height: Int
    }
    private struct Resampled {
        weak var source: IOSurface?
        let key: SharpKey
        let surface: IOSurface
    }
    /// The last two resamples (the developed photograph's and the original's,
    /// for Before and After), dropped with their sources.
    private var resampled: [Resampled] = []
    private var shownSharp: SharpKey?
    /// The resample on its way, and the one waiting for the canvas to settle.
    private var resampling: SharpKey?
    private var pendingSharp: DispatchWorkItem?
    private var failedSharp: SharpKey?
    private var lastSharpSize: (width: Int, height: Int)?
    /// The last picture checked for `FitDownscale.canResample`, which reads its tag.
    private weak var checkedSource: IOSurface?
    private var checkedResamples = false
    /// After the canvas changes size, the resample waits this long for it to
    /// stop, as while the inspector slides in.
    static let sharpSettle: TimeInterval = 0.15

    /// What the fitted view would show resampled now, or nil for Core
    /// Animation's own scaling: zoomed, in a live resize, a straightened
    /// photograph, a frame rendered at canvas size, or nothing to downscale.
    private func wantedSharp() -> (source: IOSurface, key: SharpKey, scale: CGFloat)? {
        guard settled, crop.angle == 0, let source = image as? IOSurface, let window, !inLiveResize,
              let scroll = enclosingScrollView as? ImageScrollView, scroll.fitting, scroll.magnification > 0 else { return nil }
        if checkedSource !== source { checkedSource = source; checkedResamples = FitDownscale.canResample(source) }
        guard checkedResamples else { return nil }
        let scale = scroll.magnification * window.backingScaleFactor
        guard let target = FitDownscale.targetSize(photo: size, scale: scale), source.width > target.width, source.height > target.height else { return nil }
        return (source, SharpKey(source: ObjectIdentifier(source), seed: source.seed, width: target.width, height: target.height), scale)
    }

    /// Shows, places, hides or asks for the resampled photograph. Cheap; called
    /// on every change to the picture, its layout, the zoom or the window.
    func refreshSharp() {
        resampled.removeAll { $0.source == nil }
        guard let wanted = wantedSharp() else {
            hideSharp(); pendingSharp?.cancel(); pendingSharp = nil
            return
        }
        let key = wanted.key
        if shownSharp != key {
            if let hit = resampled.first(where: { $0.key == key && $0.source === wanted.source }) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                sharp.contents = hit.surface
                shownSharp = key
                CATransaction.commit()
            } else {
                hideSharp()
                requestSharp(wanted.source, key: key)
                return
            }
        }
        placeSharp(scale: wanted.scale)
    }

    private func hideSharp() {
        guard shownSharp != nil || !sharp.isHidden else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sharp.isHidden = true; sharp.contents = nil
        shownSharp = nil
        CATransaction.commit()
    }

    private func requestSharp(_ source: IOSurface, key: SharpKey) {
        guard resampling != key, failedSharp != key else { return }
        let resized = lastSharpSize.map { $0 != (key.width, key.height) } ?? true
        lastSharpSize = (key.width, key.height)
        pendingSharp?.cancel()
        let work = DispatchWorkItem { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                self.pendingSharp = nil
                // Still wanted: the canvas may have moved on meanwhile.
                guard let wanted = self.wantedSharp(), wanted.key == key, self.resampling != key else { return }
                self.resampling = key
                FitResampler.shared.resample(source, width: key.width, height: key.height) { [weak self, weak source] surface in
                    guard let self else { return }
                    if self.resampling == key { self.resampling = nil }
                    guard let surface, let source else { if surface == nil { self.failedSharp = key }; return }
                    self.resampled.removeAll { $0.key == key || $0.source == nil }
                    self.resampled.append(Resampled(source: source, key: key, surface: surface))
                    if self.resampled.count > 2 { self.resampled.removeFirst(self.resampled.count - 2) }
                    self.refreshSharp()
                }
            }
        }
        pendingSharp = work
        // A new picture at the same size goes at once; a new size waits for
        // the canvas to stop changing.
        DispatchQueue.main.asyncAfter(deadline: .now() + (resized ? Self.sharpSettle : 0), execute: work)
    }

    /// Sizes the resample to its pixels and puts its corner on a physical
    /// pixel, where the photograph's corner is to within half a pixel.
    private func placeSharp(scale: CGFloat) {
        guard let shownSharp, let window else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let extent = CGSize(width: CGFloat(shownSharp.width) / scale, height: CGFloat(shownSharp.height) / scale)
        let corner = CGPoint(x: photo.position.x - photo.bounds.width / 2, y: photo.position.y - photo.bounds.height / 2)
        let snapped = FitDownscale.snapped(corner, toBacking: { window.backingPoint(self.convert(self.turn.convert($0, from: self.clip), to: nil)) },
                                           fromBacking: { self.clip.convert(self.convert(window.pointFromBacking($0), from: nil), from: self.turn) })
        sharp.bounds = CGRect(origin: .zero, size: extent)
        sharp.position = CGPoint(x: snapped.x + extent.width / 2, y: snapped.y + extent.height / 2)
        sharp.isHidden = false
        CATransaction.commit()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshSharp()
    }
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        refreshSharp()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshSharp()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSharp()
    }

    /// Turns the print about the middle of the part on screen, so zoomed in
    /// the same place stays in view, upside down. At once, as the original shows.
    /// The middle is on a whole or half physical pixel, so the turn keeps the
    /// resampled photograph on the pixel grid.
    private func placeTurn() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let clipView = enclosingScrollView?.contentView
        let visible = clipView.map { convert($0.bounds, from: $0) }
        var centre = Self.turnCentre(visible: visible, bounds: CGRect(origin: .zero, size: bounds.size))
        if let window {
            centre = FitDownscale.snappedHalf(centre, toBacking: { window.backingPoint(self.convert($0, to: nil)) },
                                              fromBacking: { self.convert(window.pointFromBacking($0), from: nil) })
        }
        turn.anchorPoint = bounds.width > 0 && bounds.height > 0 ? CGPoint(x: centre.x / bounds.width, y: centre.y / bounds.height) : CGPoint(x: 0.5, y: 0.5)
        turn.position = centre
        turn.setAffineTransform(turned ? CGAffineTransform(rotationAngle: .pi) : .identity)
        CATransaction.commit()
    }
    /// The middle of the photograph's part on screen: all of it when fitted.
    static func turnCentre(visible: CGRect?, bounds: CGRect) -> CGPoint {
        let shown = visible.map { $0.intersection(bounds) } ?? bounds
        let area = shown.isNull || shown.isEmpty ? bounds : shown
        return CGPoint(x: area.midX, y: area.midY)
    }

    /// Places a photograph of `size` in `clip`, cropped, straightened and
    /// turned as the exporter does, centred on `center`. The edited
    /// thumbnails use it too. `cut`: the photograph's image is the crop
    /// already, straightened.
    static func layout(clip: CALayer, photo: CALayer, size: CGSize, crop: CropSettings, rotation: Int, center: CGPoint, cut: Bool = false) {
        // The crop's pixels, as the exporter cuts them. Layers are y-up, so
        // the rectangle's top-left origin flips, and clockwise is negative.
        let pixels = crop.pixels(in: size)
        clip.bounds = CGRect(origin: .zero, size: pixels.size)
        clip.position = center
        clip.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(rotation)))
        if cut {
            photo.bounds = clip.bounds
            photo.position = CGPoint(x: pixels.width / 2, y: pixels.height / 2)
            photo.setAffineTransform(.identity)
            return
        }
        photo.bounds = CGRect(origin: .zero, size: size)
        photo.position = CGPoint(x: size.width / 2 - pixels.minX, y: pixels.height - (size.height / 2 - pixels.minY))
        photo.setAffineTransform(CGAffineTransform(rotationAngle: -crop.angle * .pi / 180))
    }

    private var grabbing = false
    /// The zoom tool is on, and Space isn't held for the hand.
    private var loupeOn: Bool {
        guard let scale = (enclosingScrollView as? ImageScrollView)?.canvasScale else { return false }
        return scale.loupe && !scale.spaceHeld
    }
    /// The zoom tool's click, unless the mouse moved (then it pans).
    private var loupeDown: CGPoint?
    /// The pointer for the tool: a magnifier in (−, with ⌥) for the zoom tool, the hand otherwise.
    var cursorNow: NSCursor {
        if picking { return Self.eyedropper }
        guard loupeOn else { return grabbing ? .closedHand : .openHand }
        if #available(macOS 15.0, *) { return NSEvent.modifierFlags.contains(.option) ? .zoomOut : .zoomIn }
        return .crosshair
    }
    /// Qlick Lab: the white balance picker's pointer, an eyedropper whose tip (bottom left) is the point sampled:
    /// white with a dark edge, so it shows on any photograph.
    static let eyedropper: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return .crosshair }
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true
            }
        }
        let white = tinted(.white), dark = tinted(NSColor(white: 0, alpha: 0.85))
        let image = NSImage(size: size, flipped: false) { _ in
            let origin = NSPoint(x: 2, y: 2)
            // The dark edge: the symbol drawn a pixel around, then the white one over it.
            for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                dark.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1)
            } }
            white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // The symbol's tip is at its bottom left; a cursor's hot spot counts from the top left.
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: size.height - 3))
    }()

    override func resetCursorRects() {
        guard (enclosingScrollView as? ImageScrollView)?.canvasScale?.covered != true else { return }
        addCursorRect(bounds, cursor: cursorNow)
    }
    private var picking: Bool {
        guard let scale = (enclosingScrollView as? ImageScrollView)?.canvasScale else { return false }
        return scale.picking && !scale.spaceHeld
    }

    /// Qlick Lab: where `point` (the view's) falls on the whole photograph, as fractions of its width and height
    /// from its top left, before the crop and the turns; nil off it.
    func photoFraction(at point: CGPoint) -> CGPoint? {
        guard let layer, size.width > 0, size.height > 0 else { return nil }
        let inPhoto = layer.convert(point, to: photo)
        let bounds = photo.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Layers are y-up: the photograph's top row is at the top.
        let fraction = CGPoint(x: (inPhoto.x - bounds.minX) / bounds.width, y: 1 - (inPhoto.y - bounds.minY) / bounds.height)
        guard (0...1).contains(fraction.x), (0...1).contains(fraction.y) else { return nil }
        return fraction
    }

    /// Qlick Lab: Shift-drag zooms, right in, left out, about where it began: where the press was, the zoom it
    /// started from, and the photograph's point under it.
    private var scrub: (x: CGFloat, magnification: CGFloat, point: CGPoint)?

    override func menu(for event: NSEvent) -> NSMenu? { enclosingScrollView?.menu(for: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), event.clickCount == 1, let scroll = enclosingScrollView as? ImageScrollView,
           !(scroll.canvasScale?.spaceHeld ?? false) {
            scrub = (event.locationInWindow.x, scroll.magnification, convert(event.locationInWindow, from: nil))
            if #available(macOS 15.0, *) { NSCursor.zoomIn.push() } else { NSCursor.resizeLeftRight.push() }
            return
        }
        if picking {
            let point = convert(event.locationInWindow, from: nil)
            if let fraction = photoFraction(at: point) { (enclosingScrollView as? ImageScrollView)?.canvasScale?.picked?(fraction) }
            else { NSSound.beep() }
            return
        }
        if loupeOn { loupeDown = event.locationInWindow; return }
        if event.clickCount == 2, let scroll = enclosingScrollView as? ImageScrollView {
            scroll.doubleClicked(at: convert(event.locationInWindow, from: nil))
        } else if !grabbing { grabbing = true; NSCursor.closedHand.push() }
    }
    override func mouseDragged(with event: NSEvent) {
        if let scrub, let scroll = enclosingScrollView as? ImageScrollView {
            // Twice as large every 120 points to the right, half every 120 to the left.
            let target = scrub.magnification * pow(2, (event.locationInWindow.x - scrub.x) / 120)
            scroll.zoomKeeping(scrub.point, at: target)
            scroll.reportGeometry()
            return
        }
        if let down = loupeDown, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > 4 { loupeDown = nil }
        guard let scroll = enclosingScrollView else { return }
        var point = scroll.contentView.bounds.origin
        point.x -= event.deltaX / scroll.magnification
        point.y += event.deltaY / scroll.magnification
        scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func mouseUp(with event: NSEvent) {
        if scrub != nil {
            scrub = nil
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
            return
        }
        if loupeDown != nil, let scroll = enclosingScrollView as? ImageScrollView {
            loupeDown = nil
            scroll.loupeClick(at: convert(event.locationInWindow, from: nil), out: event.modifierFlags.contains(.option))
            window?.invalidateCursorRects(for: self)
        }
        if grabbing { grabbing = false; NSCursor.pop() }
    }
}
