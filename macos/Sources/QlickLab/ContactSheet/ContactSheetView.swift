// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// The contact sheet itself: strips of film on a sheet, worked on with a red grease pencil.
///
/// One AppKit view draws the whole sheet with `ContactSheetRenderer` (only what's on screen), so a roll of thousands
/// of frames scrolls like one of thirty-six, and what's printed is drawn by the same code. The photographs, their
/// marks and the selection are NEgs's (`EditorModel`): a ring is a sidecar's `pick`, a cross its `reject`, so marks
/// made here show in NEgs's own grid, on Windows and Linux too, and every undo is the editor's.
@MainActor final class ContactSheetView: NSView {
    let model: EditorModel
    let lab: LabState

    private(set) var files: [PhotoFile] = []
    private var indexOf: [URL: Int] = [:]
    private var numbers: [URL: String] = [:]
    private(set) var layout = ContactSheetLayout(style: .classic, count: 0, width: 1, frameWidth: 168)
    private var heading = SheetHeading()
    private var options = SheetOptions()
    /// Qlick Lab: an open Box's shelf, its Boxes and Rolls above its photographs (`BoxShelfView`), in the space kept
    /// under the heading; it scrolls with the sheet.
    private var shelf: BoxShelfContent?
    private(set) var shelfLayout: BoxShelfLayout?
    private var shelfHost: NSHostingView<BoxShelfView>?

    // Thumbnails: only those near the view are kept.
    private var images: [URL: CGImage] = [:]
    private var loadedKeys: [URL: ThumbnailKey] = [:]
    private var loading: [URL: Task<Void, Never>] = [:]
    private var onScreen: Set<URL> = []
    private var retries: [URL: Int] = [:]

    private struct ThumbnailKey: Equatable {
        var file: PhotoFile
        var size: PhotoThumbnails.Size
        var edited: EditedThumbnail?
        /// The size it is drawn at, in pixels: the thumbnail is scaled to it once, not at every redraw.
        var drawn: CGSize
        var sideways: Bool
    }

    /// `image` scaled down to the size its frame shows it at, so drawing the sheet copies pixels instead of resampling
    /// every thumbnail at every pass. Returned as it is when it's already that small.
    nonisolated private static func fitted(_ image: CGImage, window: CGSize, sideways: Bool) -> CGImage {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let (rect, turned) = ContactSheetLayout.fit(aspect: aspect, in: CGRect(origin: .zero, size: window), sideways: sideways)
        let target = turned ? CGSize(width: rect.height, height: rect.width) : rect.size
        let width = Int(target.width.rounded()), height = Int(target.height.rounded())
        // In Display P3 whatever space the thumbnail is in: converted once here, not at every redraw.
        let (w, h) = CGFloat(image.width) > target.width * 1.15 ? (width, height) : (image.width, image.height)
        guard w > 0, h > 0,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    // Marks as last drawn, to animate the ones that change.
    private var drawnFlags: [URL: PhotoSidecar.Flag] = [:]
    private var markAnimations: [URL: CFTimeInterval] = [:]
    private var animationTimer: Timer?
    static let markDuration: CFTimeInterval = 0.24

    // The gesture under way.
    private enum Gesture {
        case none
        /// The pencil passes over frames: each takes `target`.
        case paint(target: PhotoSidecar.Flag?, visited: [URL], last: CGPoint)
        case band(start: CGPoint, base: Set<URL>)
        /// The pointer (or the loupe) pressed on a frame: moved far enough, the photographs are dragged. A frame
        /// already selected is clicked only at the release, so a drag takes the whole selection.
        case lift(url: URL, start: CGPoint, clickOnRelease: Bool)
    }
    private var gesture = Gesture.none
    private var pending: [URL: PhotoSidecar.Flag?] = [:]
    private var band: CGRect?
    /// The last single click of the pencil, which a double-click takes back before opening the photograph.
    private var lastClick: (url: URL, before: PhotoSidecar.Flag?, time: TimeInterval)?
    private var seenCurrent: URL?
    private var tracking = 0

    init(model: EditorModel) {
        self.model = model
        lab = model.lab
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityLabel("Contact sheet")
        // Photographs of the Box or Roll open, dragged on its own sheet, are put in order there (`ManualOrder`).
        registerForDraggedTypes([NSPasteboard.PasteboardType(LabDragItem.type.identifier)])
    }

    /// Where photographs dragged over the sheet would be put in order, while they are.
    private var dropSlot: Int? {
        didSet {
            guard dropSlot != oldValue else { return }
            for slot in [oldValue, dropSlot].compactMap({ $0 }) { if let bar = dropBar(slot) { setNeedsDisplay(bar.insetBy(dx: -4, dy: -4)) } }
        }
    }

    private var pictures: [CGRect] { (0..<min(files.count, layout.count)).map(layout.picture) }

    private func dropBar(_ slot: Int) -> CGRect? { ManualOrder.bar(pictures, slot: slot, gap: layout.pitch - layout.frame.width) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard lab.canReorder(lab.dragging) else { dropSlot = nil; return [] }
        dropSlot = ManualOrder.slot(pictures, at: convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropSlot = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropSlot = nil }
        guard let slot = dropSlot, case .photos(let photos, _)? = lab.dragging, lab.canReorder(lab.dragging) else { return false }
        return lab.reorderOpen(photos, slot: slot, shown: files.map(\.url))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Following the model

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracking += 1
        guard window != nil else {
            for url in onScreen { if let index = indexOf[url] { model.thumbnailShown(files[index], false) } }
            onScreen = []
            loading.values.forEach { $0.cancel() }; loading = [:]
            animationTimer?.invalidate(); animationTimer = nil
            return
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: clip)
        }
        track(tracking)
    }

    /// Reads what the sheet shows from the model, and again whenever any of it changes.
    private func track(_ token: Int) {
        guard token == tracking, window != nil else { return }
        withObservationTracking { sync() } onChange: { [weak self] in
            Task { @MainActor in self?.track(token) }
        }
    }

    private var clipSize: CGSize { enclosingScrollView?.contentView.bounds.size ?? bounds.size }

    private func sync() {
        let shown = lab.frames
        let library = model.library
        let optionsNow = lab.sheet
        // A frame keeps its number whatever the filter shows: its place in the roll.
        if shown != files || numbers.isEmpty {
            var numbers: [URL: String] = [:]
            var count = 0
            for item in library.items {
                if let id = item.url.variantID, let copies = library.duplicates[item.url.photoFile], let copy = copies.firstIndex(of: id) {
                    numbers[item.url] = String(format: "%02d", count) + String(UnicodeScalar(UInt8(98 + min(copy, 24))))
                } else {
                    count += 1
                    numbers[item.url] = String(format: "%02d", count)
                }
            }
            self.numbers = numbers
        }
        let filesChanged = shown != files
        if filesChanged {
            let gone = Set(files.map(\.url)).subtracting(shown.map(\.url))
            for url in gone { images[url] = nil; loadedKeys[url] = nil; loading[url]?.cancel(); loading[url] = nil; markAnimations[url] = nil }
            files = shown
            indexOf = Dictionary(shown.enumerated().map { ($1.url, $0) }) { first, _ in first }
        }
        let headingNow = makeHeading()
        let shelfNow = lab.openShelf
        let shelfChanged = shelfNow != shelf || optionsNow.lightTable != options.lightTable
        shelf = shelfNow
        let relaid = relayout(options: optionsNow, heading: headingNow, force: filesChanged || shelfChanged)
        if optionsNow.tool != .loupe { hideLens() }
        options = optionsNow
        // A sheet always has a frame the keys act on: the first, until another is chosen.
        if model.selection.current == nil, let first = shown.first, window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selection.current == nil, self.files.first?.url == first.url else { return }
                self.model.click(first.url)
            }
        }
        // Marks that changed draw themselves in, as the pencil would.
        var flags: [URL: PhotoSidecar.Flag] = [:]
        for file in files { if let flag = library.summary(for: file.url).flag { flags[file.url] = flag } }
        if !relaid, !filesChanged {
            for file in files where flags[file.url] != drawnFlags[file.url] {
                if flags[file.url] != nil, pending[file.url] == nil { animate(file.url) }
                if let index = indexOf[file.url] { setNeedsDisplay(renderer.markBounds(index)) }
            }
        }
        drawnFlags = flags
        // Read so a change redraws: selection, facts for the detailed view, developed thumbnails.
        _ = model.selection
        _ = model.thumbnailVersions
        _ = model.thumbnailStamp
        _ = library.looks
        if options.style == .detail { _ = lab.facts.facts }
        needsDisplay = true
        let current = model.selection.current
        if current != seenCurrent {
            seenCurrent = current
            if let current, let index = indexOf[current], !isPainting { reveal(index) }
        }
        loadVisible()
    }

    private func makeHeading() -> SheetHeading {
        let counts = lab.counts
        var heading = lab.sheetHeading
        if heading.title.isEmpty { heading.title = model.library.directory?.lastPathComponent ?? "" }
        var parts = [counts.total == 1 ? "1 frame" : "\(counts.total) frames"]
        if counts.picks > 0 { parts.append("\(counts.picks) picked") }
        if counts.rejects > 0 { parts.append("\(counts.rejects) rejected") }
        heading.counts = parts.joined(separator: " · ")
        return heading
    }

    private var edgeLabel: String { lab.current?.roll.film ?? "" }

    private var renderer: ContactSheetRenderer {
        ContactSheetRenderer(layout: layout, palette: options.lightTable ? .lightTable : .dark, sidewaysVerticals: options.sidewaysVerticals,
                             edgeLabel: edgeLabel)
    }

    /// Lays the sheet out for the view's width. True if the layout changed.
    @discardableResult private func relayout(options: SheetOptions, heading: SheetHeading, force: Bool = false) -> Bool {
        let width = max(clipSize.width, 200)
        let headingHeight: CGFloat = heading.notes.isEmpty ? 52 : 70
        func make(header: CGFloat) -> ContactSheetLayout {
            ContactSheetLayout(style: options.style, count: files.count, width: width, frameWidth: options.frameWidth, header: header,
                               showsNames: options.showNames, showsFilm: options.showFilm, namesUnder: options.fileNames == .under)
        }
        // The shelf keeps to the frames' columns: laid out on the strips' length, its height added to the heading's.
        var next = make(header: headingHeight)
        let shelfNext = shelf.map {
            BoxShelfLayout(spans: $0.spans, width: next.stripLength, frame: next.frame, pitch: next.pitch, lead: next.lead, note: $0.note)
        }
        if let shelfNext, shelfNext.height > 0 { next = make(header: headingHeight + shelfNext.height) }
        placeShelf(shelfNext, in: next, below: headingHeight, light: options.lightTable)
        let headingChanged = heading != self.heading
        self.heading = heading
        guard next != layout || force else {
            if headingChanged { setNeedsDisplay(CGRect(x: 0, y: 0, width: bounds.width, height: layout.top)) }
            return false
        }
        // Keep the frame the eye is on where it is.
        let visible = visibleRect
        let anchor: (index: Int, offset: CGFloat)? = {
            guard layout.count > 0, files.count > 0 else { return nil }
            let index: Int? = model.selection.current.flatMap { indexOf[$0] }.flatMap { $0 < layout.count && layout.picture($0).intersects(visible) ? $0 : nil }
                ?? layout.indices(in: visible).first
            return index.flatMap { $0 < layout.count ? ($0, layout.picture($0).minY - visible.minY) : nil }
        }()
        layout = next
        let size = CGSize(width: width, height: max(next.height, clipSize.height))
        if frame.size != size { setFrameSize(size) }
        if let anchor, anchor.index < next.count, let clip = enclosingScrollView?.contentView {
            let y = min(max(next.picture(anchor.index).minY - anchor.offset, 0), max(size.height - clip.bounds.height, 0))
            clip.scroll(to: CGPoint(x: 0, y: y))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        needsDisplay = true
        return true
    }

    /// The shelf's view, under the heading on the strips' left edge; gone when no Box is open.
    private func placeShelf(_ next: BoxShelfLayout?, in sheet: ContactSheetLayout, below heading: CGFloat, light: Bool) {
        guard let shelf, let next, next.height > 0 else {
            shelfLayout = nil
            shelfHost?.removeFromSuperview(); shelfHost = nil
            return
        }
        let frame = CGRect(x: sheet.originX, y: sheet.margin + heading, width: next.width, height: next.height)
        if let host = shelfHost {
            if next != shelfLayout || host.rootView.content != shelf || host.rootView.light != light {
                host.rootView = BoxShelfView(lab: lab, content: shelf, layout: next, light: light)
            }
        } else {
            let host = NSHostingView(rootView: BoxShelfView(lab: lab, content: shelf, layout: next, light: light))
            host.sizingOptions = []
            addSubview(host)
            shelfHost = host
        }
        shelfLayout = next
        if shelfHost?.frame != frame { shelfHost?.frame = frame }
    }

    @objc private func scrolled() { hideLens(); loadVisible() }
    @objc private func resized() {
        relayout(options: options, heading: heading)
        loadVisible()
    }

    /// Scrolls just far enough to show a frame with its bands.
    func reveal(_ index: Int) {
        guard index < layout.count else { return }
        var rect = layout.cell(index).insetBy(dx: 0, dy: -6)
        // The first strip comes with the sheet's heading.
        if layout.row(of: index) == 0 { rect = rect.union(CGRect(x: rect.minX, y: 0, width: rect.width, height: 1)) }
        scrollToVisible(rect)
    }

    // MARK: Thumbnails

    private var thumbnailSize: PhotoThumbnails.Size {
        .grid(points: layout.frame.width, scale: window?.backingScaleFactor ?? 2)
    }

    /// Asks for the thumbnails in and near the view, and lets go of those far from it.
    private func loadVisible() {
        guard window != nil, !files.isEmpty else { return }
        let visible = visibleRect
        let near = Set(layout.indices(in: visible.insetBy(dx: 0, dy: -visible.height * 0.75)))
        let seen = Set(layout.indices(in: visible).map { files[$0].url })
        for url in seen.subtracting(onScreen) { if let index = indexOf[url] { model.thumbnailShown(files[index], true) } }
        for url in onScreen.subtracting(seen) { if let index = indexOf[url] { model.thumbnailShown(files[index], false) } }
        onScreen = seen
        let size = thumbnailSize
        let scale = window?.backingScaleFactor ?? 2, sideways = options.sidewaysVerticals
        let drawn = CGSize(width: layout.frame.width * scale, height: layout.frame.height * scale)
        for index in near {
            let file = files[index], url = file.url
            let edited = model.editedThumbnail(for: url)
            let key = ThumbnailKey(file: file, size: size, edited: edited, drawn: drawn, sideways: options.sidewaysVerticals)
            guard loadedKeys[url] != key else { continue }
            loadedKeys[url] = key
            loading[url]?.cancel()
            loading[url] = Task { [weak self] in
                let request = Task.detached(priority: .utility) {
                    guard let image = await PhotoThumbnails.shared.image(for: file, size: size, look: edited?.look, edited: edited?.store) else { return nil as CGImage? }
                    return Self.fitted(image, window: drawn, sideways: sideways)
                }
                let image = await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
                guard let self, !Task.isCancelled else { return }
                self.loading[url] = nil
                guard let image, let index = self.indexOf[url] else {
                    if image == nil, self.loadedKeys[url] == key, self.images[url] == nil {
                        self.loadedKeys[url] = nil
                        // Asked again shortly, a few times: a folder just listed can answer before its files are readable.
                        let tries = self.retries[url, default: 0]
                        if tries < 4 {
                            self.retries[url] = tries + 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(tries + 1)) { [weak self] in self?.loadVisible() }
                        }
                    }
                    return
                }
                self.retries[url] = nil
                self.images[url] = image
                self.model.aspects.note(url, image: image)
                // The marks and the box are drawn round the picture, which now has its size.
                self.setNeedsDisplay(self.renderer.markBounds(index))
            }
        }
        // Far from the view: a few screens are kept, the rest is read again when scrolled to.
        if images.count > 600 {
            let keep = Set(layout.indices(in: visible.insetBy(dx: 0, dy: -visible.height * 3)).map { files[$0].url })
            for url in images.keys where !keep.contains(url) { images[url] = nil; loadedKeys[url] = nil }
        }
    }

    /// The thumbnails held now, for the printed sheet's first pass.
    func heldImage(_ url: URL) -> CGImage? { images[url] }

    // MARK: Drawing

    private func flag(_ url: URL) -> PhotoSidecar.Flag? {
        if let override = pending[url] { return override }
        return model.library.summary(for: url).flag
    }

    private func content(_ index: Int) -> SheetFrameContent {
        let file = files[index], url = file.url
        let summary = model.library.summary(for: url), selection = model.selection
        var content = SheetFrameContent(name: file.name, number: numbers[url] ?? "", image: images[url], flag: flag(url), rating: summary.rating,
                                        edited: summary.edited, selected: selection.selected.contains(url) && selection.selected.count > 1,
                                        current: selection.current == url)
        content.label = summary.label
        content.stack = lab.projects.stackBadge(url)
        if options.style == .detail { content.caption = lab.facts.get(url)?.caption }
        if let start = markAnimations[url] {
            let t = min(max((CACurrentMediaTime() - start) / Self.markDuration, 0), 1)
            // Ease out: the hand slows as it closes the ring.
            content.markProgress = CGFloat(1 - pow(1 - t, 2.2))
        }
        return content
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let renderer = renderer
        renderer.drawSheet(context, in: dirtyRect)
        if dirtyRect.minY < layout.top { renderer.drawHeading(context, heading) }
        // A ring reaches past its strip, so the rows just outside the dirty rectangle are drawn too.
        let reach = layout.frame.height * 0.35 + 8
        let rows = layout.rows(in: dirtyRect.insetBy(dx: 0, dy: -reach))
        guard !rows.isEmpty else { return }
        var contents: [(Int, SheetFrameContent)] = []
        for row in rows {
            renderer.drawStrip(context, row: row)
            for index in layout.frames(inRow: row) where index < files.count {
                let content = content(index)
                renderer.drawFrame(context, index: index, content)
                contents.append((index, content))
            }
        }
        for (index, content) in contents { renderer.drawSelection(context, index: index, content) }
        for (index, content) in contents { renderer.drawMark(context, index: index, content) }
        if let dropSlot, let bar = dropBar(dropSlot) {
            context.setFillColor(Theme.NS.accent.cgColor)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
        if let band {
            context.setFillColor(CGColor(gray: 1, alpha: 0.07))
            context.fill(band)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
            context.setLineWidth(1)
            context.stroke(band.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func animate(_ url: URL) {
        markAnimations[url] = CACurrentMediaTime()
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAnimations() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stepAnimations() {
        let now = CACurrentMediaTime()
        let renderer = renderer
        for (url, start) in markAnimations {
            if let index = indexOf[url] { setNeedsDisplay(renderer.markBounds(index)) }
            if now - start >= Self.markDuration { markAnimations[url] = nil }
        }
        if markAnimations.isEmpty { animationTimer?.invalidate(); animationTimer = nil }
    }

    // MARK: The pencil and the pointer

    private var isPainting: Bool { if case .paint = gesture { return true }; return false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags, clicks: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let frames = photosToDrag(at: point) { return beginPhotoDrag(frames, event: event, at: point) }
        drag(to: point)
        autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) { release() }

    /// The start of a click or stroke. Public so the lab's automation can make the same gestures as the mouse.
    func press(at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        gesture = .none
        guard let index = layout.index(at: point), index < files.count else {
            gesture = .band(start: point, base: modifiers.isDisjoint(with: [.command, .shift]) ? [] : model.selection.selected)
            return
        }
        let url = files[index].url
        if !modifiers.isDisjoint(with: [.command, .shift]) {
            model.click(url, command: modifiers.contains(.command), shift: modifiers.contains(.shift))
            return
        }
        if clicks >= 2 {
            // The first click's mark was the way to the double-click, not a decision: taken back.
            if let last = lastClick, last.url == url, model.library.summary(for: url).flag != last.before {
                model.setFlag(last.before, targets: [url])
            }
            lastClick = nil
            model.click(url)
            lab.show(.develop)
            return
        }
        guard options.tool == .pencil else {
            let keep = model.selection.selected.contains(url) && model.selection.selected.count > 1
            if !keep { model.click(url) }
            if options.tool == .loupe { hover(at: point) }
            gesture = .lift(url: url, start: point, clickOnRelease: keep)
            return
        }
        // The pencil draws its mark (a ring, or a cross: the bar says which), or lifts it from a frame that has it;
        // with ⌥ it draws the other one.
        let before = model.library.summary(for: url).flag
        let crossing = (options.pencilMark == .cross) != modifiers.contains(.option)
        let target: PhotoSidecar.Flag? = crossing ? (before == .reject ? nil : .reject) : (before == .pick ? nil : .pick)
        lastClick = (url, before, ProcessInfo.processInfo.systemUptime)
        pending[url] = .some(target)
        if target != nil { animate(url) }
        setNeedsDisplay(renderer.markBounds(index))
        gesture = .paint(target: target, visited: [url], last: point)
    }

    func drag(to point: CGPoint) {
        switch gesture {
        case .none, .lift: break
        case .paint(let target, var visited, let last):
            // Every frame the stroke crossed, even between two mouse events of a fast one.
            let distance = hypot(point.x - last.x, point.y - last.y)
            let steps = max(Int(distance / max(layout.frame.width / 4, 4)), 1)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let sample = CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t)
                guard let index = layout.index(at: sample, slop: 0), index < files.count else { continue }
                let url = files[index].url
                guard !visited.contains(url) else { continue }
                visited.append(url)
                let had = flag(url)
                pending[url] = .some(target)
                if target != nil, had != target { animate(url) }
                setNeedsDisplay(renderer.markBounds(index))
            }
            gesture = .paint(target: target, visited: visited, last: point)
        case .band(let start, let base):
            guard hypot(point.x - start.x, point.y - start.y) > 3 || band != nil else { return }
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            band = rect
            model.band(layout.indices(in: rect).filter { $0 < files.count }.map { files[$0].url }, adding: base)
            needsDisplay = true
        }
    }

    func release() {
        defer { gesture = .none }
        switch gesture {
        case .none: break
        case .paint(let target, let visited, _):
            // One change, one undo: every frame the stroke crossed.
            let changed = visited.filter { model.library.summary(for: $0).flag != target }
            if let last = visited.last { model.click(last) }
            if visited.count > 1 { lastClick = nil }
            if !changed.isEmpty { model.setFlag(target, targets: changed) }
            // The model has them now; the drawing doesn't start again.
            for url in visited {
                if let target { drawnFlags[url] = target } else { drawnFlags[url] = nil }
                pending[url] = nil
            }
            needsDisplay = true
        case .band:
            if band == nil { model.deselectAll() }
            band = nil
            needsDisplay = true
        case .lift(let url, _, let clickOnRelease):
            if clickOnRelease { model.click(url) }
        }
    }

    // MARK: Dragging the photographs

    /// The photographs a drag takes at `point`, when it's time to start one: the pointer moved past a few points from
    /// a frame; or the pencil's stroke left the sheet sideways (towards the sidebar), its marks taken back, with the
    /// selection if it started on a selected frame, else the frames it crossed.
    private func photosToDrag(at point: CGPoint) -> [URL]? {
        switch gesture {
        case .lift(let url, let start, _):
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return nil }
            return model.contextTargets(url)
        case .paint(_, let visited, _):
            let visible = visibleRect
            guard point.x < visible.minX - 2 || point.x > visible.maxX + 2, let first = visited.first else { return nil }
            for url in visited { pending[url] = nil }
            markAnimations = [:]
            lastClick = nil
            needsDisplay = true
            return model.selection.selected.contains(first) ? model.contextTargets(first) : visited
        default: return nil
        }
    }

    private func beginPhotoDrag(_ frames: [URL], event: NSEvent, at point: CGPoint) {
        gesture = .none
        var seen: Set<URL> = []
        let photos = frames.map(\.photoFile).filter { seen.insert($0).inserted }
        guard !photos.isEmpty else { return }
        lab.dragging = .photos(photos, from: lab.openHolder)
        lab.sidebarDrop.dragStarted()
        let item = NSPasteboardItem()
        item.setData(Data("qlick-lab".utf8), forType: NSPasteboard.PasteboardType(LabDragItem.type.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let picture = PhotoDragPreview.image(frames.first.flatMap { images[$0] }, count: photos.count, scale: window?.backingScaleFactor ?? 2)
        let size = picture.size
        dragging.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), contents: picture)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = layout.index(at: point), index < files.count else { return super.rightMouseDown(with: event) }
        let url = files[index].url
        if !model.selection.selected.contains(url) { model.click(url) }
        NSMenu.popUpContextMenu(SheetMenu(sheet: self, item: url).menu, with: event, for: self)
    }

    override func magnify(with event: NSEvent) {
        let width = lab.sheet.frameWidth * (1 + event.magnification)
        lab.sheet.frameWidth = min(max(width, SheetOptions.widths.lowerBound), SheetOptions.widths.upperBound)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        if modifiers.isDisjoint(with: [.command, .control, .option]) {
            let extending = modifiers.contains(.shift)
            switch event.keyCode {
            case 123: return model.move(by: -1, extending: extending)
            case 124: return model.move(by: 1, extending: extending)
            case 125, 126: return moveRow(event.keyCode == 125 ? 1 : -1, extending: extending)
            case 115: if let first = files.first { model.click(first.url) }; return
            case 119: if let last = files.last { model.click(last.url) }; return
            default: break
            }
            if let action = lab.keys.action(for: event) { return perform(action) }
            // Stars, as in Lightroom: 1 to 5, and 0 for none.
            if !extending, let typed = event.charactersIgnoringModifiers, typed.count == 1, let stars = Int(typed), (0...5).contains(stars) {
                return lab.menuRate(stars)
            }
        }
        super.keyDown(with: event)
    }

    private func moveRow(_ rows: Int, extending: Bool) {
        let selection = model.selection
        let from = extending ? selection.lead ?? selection.current : selection.current
        guard let from, let index = indexOf[from] else {
            if let first = files.first { model.click(first.url) }
            return
        }
        guard let target = layout.vertical(from: index, by: rows), target < files.count else { return }
        model.click(files[target].url, shift: extending)
    }

    /// The frames a key acts on: the selection, as the Photo menu's commands.
    private var targets: [URL] { model.ratingTargets }

    func perform(_ action: SheetAction) {
        switch action {
        case .pick: lab.toggleMark(.pick)
        case .reject: lab.toggleMark(.reject)
        case .unmark: model.setFlag(nil)
        case .loupe: if let current = model.selection.current { lab.loupe = lab.loupe == nil ? current : nil }
        case .develop: if model.selection.current != nil { lab.show(.develop) }
        case .compare: lab.compareSelection()
        case .pencil: lab.sheet.tool = lab.sheet.tool == .pencil ? .pointer : .pencil
        case .loupeTool: lab.sheet.tool = lab.sheet.tool == .loupe ? .pointer : .loupe
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: if let label = action.label { model.toggleLabel(label) }
        case .nextUnmarked:
            let start = model.selection.current.flatMap { indexOf[$0] } ?? -1
            let order = Array(files.indices.dropFirst(start + 1)) + Array(files.indices.prefix(max(start, 0)))
            if let next = order.first(where: { model.library.summary(for: files[$0].url).flag == nil }) { model.click(files[next].url) }
        }
    }

    // MARK: The loupe

    /// The loupe tool's glass: a round lens that follows the pointer over a frame and shows what's under it three
    /// times as large, as a loupe laid on a contact sheet.
    private let lens = CALayer(), lensPicture = CALayer(), lensRim = CALayer()
    private var lensLarge: (url: URL, image: CGImage)?
    private var lensAsked: URL?
    private var hoverArea: NSTrackingArea?
    static let lensSize: CGFloat = 280, lensZoom: CGFloat = 3.2

    private func makeLens() {
        guard lens.superlayer == nil, let layer else { return }
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        for sublayer in [lens, lensPicture, lensRim] { sublayer.actions = none }
        lens.bounds = CGRect(x: 0, y: 0, width: Self.lensSize, height: Self.lensSize)
        lens.cornerRadius = Self.lensSize / 2
        lens.masksToBounds = true
        lens.backgroundColor = CGColor(gray: 0, alpha: 1)
        lens.isHidden = true
        lensPicture.contentsGravity = .resize
        lensPicture.magnificationFilter = .linear
        lensPicture.minificationFilter = .trilinear
        lens.addSublayer(lensPicture)
        lensRim.bounds = lens.bounds.insetBy(dx: -1, dy: -1)
        lensRim.cornerRadius = Self.lensSize / 2 + 1
        lensRim.borderWidth = 2.5
        lensRim.borderColor = CGColor(gray: 0.92, alpha: 1)
        lensRim.shadowColor = CGColor(gray: 0, alpha: 1)
        lensRim.shadowOpacity = 0.6; lensRim.shadowRadius = 14; lensRim.shadowOffset = CGSize(width: 0, height: 6)
        lensRim.isHidden = true
        layer.addSublayer(lens)
        layer.addSublayer(lensRim)
    }

    func hideLens() {
        guard !lens.isHidden else { return }
        lens.isHidden = true; lensRim.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set(); hover(at: convert(event.locationInWindow, from: nil)) }
    /// The arrow, whatever the tool: the pencil and the loupe draw their own marks; the editor's hand under the
    /// sheet isn't the sheet's.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .arrow) }
    override func mouseExited(with event: NSEvent) { hideLens() }

    /// The pointer is at `point`: with the loupe, its glass shows the frame there. Public for the lab's automation.
    func hover(at point: CGPoint) {
        guard options.tool == .loupe, lab.loupe == nil, let index = layout.index(at: point, slop: 0), index < files.count else { return hideLens() }
        let file = files[index], url = file.url
        guard let small = images[url] else { return hideLens() }
        let (rect, turned) = ContactSheetLayout.fit(aspect: CGFloat(small.width) / CGFloat(max(small.height, 1)), in: layout.picture(index), sideways: options.sidewaysVerticals)
        guard rect.contains(point) else { return hideLens() }
        // The frame's large thumbnail, asked once; its small one until it's in.
        if lensLarge?.url != url, lensAsked != url {
            lensAsked = url
            let edited = model.editedThumbnail(for: url)
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    await PhotoThumbnails.shared.image(for: file, size: .large, look: edited?.look, edited: edited?.store)
                }.value
                guard let self, let image, self.lensAsked == url else { return }
                self.lensLarge = (url, image)
                if !self.lens.isHidden, let window = self.window { self.hover(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
            }
        }
        makeLens()
        let image = lensLarge?.url == url ? lensLarge!.image : small
        let size = Self.lensSize, zoom = Self.lensZoom
        let shown = CGSize(width: rect.width * zoom, height: rect.height * zoom)
        let u = (point.x - rect.minX) / rect.width, v = (point.y - rect.minY) / rect.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lensPicture.contents = image
        // An upright frame lying on its side is shown as it lies.
        lensPicture.bounds = CGRect(origin: .zero, size: turned ? CGSize(width: shown.height, height: shown.width) : shown)
        lensPicture.setAffineTransform(turned ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity)
        lensPicture.position = CGPoint(x: size / 2 + (0.5 - u) * shown.width, y: size / 2 + (0.5 - v) * shown.height)
        // Clear of the pointer's own spot when there's room: the glass sits on it, as a loupe does.
        lens.position = point; lensRim.position = point
        lens.isHidden = false; lensRim.isHidden = false
        CATransaction.commit()
    }

    // MARK: For the lab's automation and tests

    /// Draws what's in view `passes` times and says how long one pass takes, with what the sheet holds.
    func benchmark(passes: Int = 30) -> String {
        let visible = visibleRect
        guard let bitmap = bitmapImageRepForCachingDisplay(in: visible) else { return "no bitmap" }
        let layoutStart = CACurrentMediaTime()
        for _ in 0..<200 { _ = ContactSheetLayout(style: options.style, count: files.count, width: bounds.width, frameWidth: options.frameWidth, header: 52) }
        let layoutTime = (CACurrentMediaTime() - layoutStart) / 200
        let start = CACurrentMediaTime()
        for _ in 0..<passes { cacheDisplay(in: visible, to: bitmap) }
        let each = (CACurrentMediaTime() - start) / Double(passes)
        return String(format: "frames=%d inView=%d imagesHeld=%d draw=%.2fms layout=%.4fms height=%.0f", files.count, layout.indices(in: visible).count, images.count,
                      each * 1000, layoutTime * 1000, layout.height)
    }

    func centre(of index: Int) -> CGPoint? {
        guard index >= 0, index < layout.count else { return nil }
        let picture = layout.picture(index)
        return CGPoint(x: picture.midX, y: picture.midY)
    }
}

extension ContactSheetView: NSDraggingSource {
    /// Inside the lab, copy or move (⌥ copies); outside it, nothing: no file ever leaves the lab by a drag.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        lab.sidebarDrop.end()
    }
}

/// The sheet's context menu.
@MainActor final class SheetMenu: NSObject {
    private let sheet: ContactSheetView
    private let item: URL
    private var model: EditorModel { sheet.model }
    let menu = NSMenu()

    init(sheet: ContactSheetView, item: URL) {
        self.sheet = sheet
        self.item = item
        super.init()
        menu.appearance = NSAppearance(named: .darkAqua)
        let keys = sheet.lab.keys
        let count = model.ratingTargets.count
        let several = count > 1 ? " (\(count) frames)" : ""
        add("Pick" + several, #selector(pick), key: keys.key(.pick))
        add("Reject" + several, #selector(reject), key: keys.key(.reject))
        add("Clear the Mark", #selector(unmark), key: keys.key(.unmark))
        menu.addItem(.separator())
        let rating = NSMenu()
        for stars in 0...5 {
            let entry = rating.addItem(withTitle: stars == 0 ? "None" : String(repeating: "★", count: stars), action: #selector(rate(_:)), keyEquivalent: "\(stars)")
            entry.keyEquivalentModifierMask = []; entry.tag = stars; entry.target = self
        }
        menu.addItem(withTitle: "Rating", action: nil, keyEquivalent: "").submenu = rating
        menu.addItem(sheet.lab.labelMenuItem(for: model.ratingTargets))
        menu.addItem(.separator())
        add("Open in Develop", #selector(develop), key: keys.key(.develop))
        add("See Larger", #selector(loupe), key: keys.key(.loupe))
        add(count > 1 ? "Compare the \(count) Frames" : "Compare with the Next", #selector(compare), key: keys.key(.compare))
        for entry in sheet.lab.boxItems(for: sheet.lab.selectionTargets) { menu.addItem(entry) }
        menu.addItem(.separator())
        add("Copy Edits", #selector(copyEdits), enabled: model.canCopyEdits)
        add("Paste Edits" + several, #selector(pasteEdits), enabled: model.canPasteEdits)
        add("Paste from Previous" + several, #selector(pasteFromPrevious), enabled: model.canChangeEdits && model.previousEdits != nil)
        shownPresets = model.presets
        for (title, action) in [("Apply Recipe", #selector(applyPreset(_:))), ("Apply Recipe with Auto WB & Exposure", #selector(applyPresetAdapting(_:)))] {
            let presets = NSMenu()
            for (index, preset) in model.presets.enumerated() {
                let entry = presets.addItem(withTitle: preset.name, action: action, keyEquivalent: "")
                entry.tag = index; entry.target = self; entry.representedObject = self
            }
            presets.addItem(.separator())
            let develop = presets.addItem(withTitle: "Apply Develop Settings Too", action: #selector(toggleRecipeDevelop), keyEquivalent: "")
            develop.target = self; develop.representedObject = self; develop.state = model.recipesApplyDevelop ? .on : .off
            let applying = menu.addItem(withTitle: title + several, action: nil, keyEquivalent: "")
            if model.canChangeEdits, model.canChangePresets, !model.presets.isEmpty { applying.submenu = presets } else { applying.isEnabled = false }
        }
        // Qlick Lab: the user's own Grain and Halation presets, that section alone.
        for section in PresetSection.allCases {
            let presets = NSMenu()
            for preset in SectionPresets.shared.list(section) {
                presets.addItem(ClosureMenuItem(preset.name) { [model] in model.labApplySection(preset, section, to: model.ratingTargets) })
            }
            let applying = menu.addItem(withTitle: "Apply \(section.title)" + several, action: nil, keyEquivalent: "")
            if model.canChangeEdits, presets.numberOfItems > 0 { applying.submenu = presets } else { applying.isEnabled = false }
        }
        add("New Version (Virtual Copy)", #selector(duplicate), enabled: model.canChangeEdits)
        add("Reset Edits" + several, #selector(resetEdits), enabled: model.canChangeEdits)
        menu.addItem(.separator())
        add("Build Thumbnail" + (count > 1 ? "s" : "") + several, #selector(buildThumbnails))
        add("Build Preview" + (count > 1 ? "s" : "") + several, #selector(buildPreviews))
        add("Export" + several + "…", #selector(export), enabled: model.canExport)
        add("Show in Finder", #selector(reveal))
        menu.addItem(.separator())
        add(count > 1 ? "Remove \(count) Photographs…" : "Remove…", #selector(remove), enabled: model.canDelete)
    }

    private func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let entry = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: key == "\r" || key == " " ? "" : key)
        entry.keyEquivalentModifierMask = []
        entry.target = self
        // Keeps the menu's target alive while it's open.
        entry.representedObject = self
    }

    private var shownPresets: [PresetFile] = []
    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard shownPresets.indices.contains(sender.tag) else { return }
        model.labApply(shownPresets[sender.tag], to: model.ratingTargets)
    }
    @objc private func applyPresetAdapting(_ sender: NSMenuItem) {
        guard shownPresets.indices.contains(sender.tag) else { return }
        model.labApply(shownPresets[sender.tag], to: model.ratingTargets, adapting: true)
    }
    @objc private func toggleRecipeDevelop() { model.recipesApplyDevelop.toggle() }
    @objc private func pick() { sheet.lab.toggleMark(.pick) }
    @objc private func reject() { sheet.lab.toggleMark(.reject) }
    @objc private func unmark() { model.setFlag(nil) }
    @objc private func rate(_ sender: NSMenuItem) { model.setRating(sender.tag) }
    @objc private func develop() { model.click(item); sheet.lab.show(.develop) }
    @objc private func loupe() { sheet.lab.loupe = item }
    @objc private func compare() { sheet.lab.compareSelection() }
    @objc private func copyEdits() { model.copyEdits(from: item) }
    @objc private func pasteEdits() { model.pasteEdits() }
    @objc private func duplicate() { model.duplicate() }
    @objc private func resetEdits() { model.resetEdits() }
    @objc private func export() { model.exportPanel() }
    @objc private func buildPreviews() { sheet.lab.previewBuilder.build(model.ratingTargets) }
    @objc private func buildThumbnails() { model.buildThumbnails(model.ratingTargets) }
    @objc private func pasteFromPrevious() { model.pasteFromPrevious(onto: model.ratingTargets) }
    @objc private func remove() { sheet.lab.requestRemove(model.ratingTargets) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(model.ratingTargets.map(\.photoFile)) }
}

/// The sheet in its scroll view, for SwiftUI.
struct ContactSheetHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // Room under the floating bar at the foot.
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 64, right: 0)
        let sheet = ContactSheetView(model: model)
        sheet.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        scroll.documentView = sheet
        model.lab.sheetView = sheet
        DispatchQueue.main.async { sheet.window?.makeFirstResponder(sheet) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
