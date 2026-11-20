import AppKit

// The title bar (§3): 38 pt of `bg` across the window, holding only the
// traffic lights and the file name, in Newsreader 15 600 `paper`. There's
// no toolbar; its items have homes of their own (§5.6).

/// The window's content: the title band over the split view. The columns,
/// the grid's sheet and the alert's dimming all start under the band.
@MainActor final class EditorFrame: NSViewController {
    let split: NSSplitViewController
    let band = TitleBand()

    init(split: NSSplitViewController, size: NSSize) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
        let view = EditorFrameView(band: band, content: split.view)
        view.frame = NSRect(origin: .zero, size: size)
        self.view = view
        addChild(split)
        view.addSubview(split.view)
        view.addSubview(band)
        view.place()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class EditorFrameView: NSView {
    let band: TitleBand
    let content: NSView

    init(band: TitleBand, content: NSView) {
        self.band = band
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.bg.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The band takes no clicks: they go to the window's title bar under
    // it, which drags and zooms the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === band ? nil : hit
    }

    // Placed as the frame changes, not on the next layout pass, so the
    // columns never have a moment at the wrong size.
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    func place() {
        let height = min(Theme.Size.titleBar, bounds.height)
        band.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
    }
}

/// The band behind the traffic lights, with the trail of where the lab is beside them: Project › Roll › file. The
/// earlier words are links (the project opens whole, the roll on its sheet); the rest of the band takes no clicks,
/// so the window drags and zooms from it as from any title bar.
final class TitleBand: NSView {
    struct Crumb: Equatable {
        var text: String
        var clickable = false
    }

    /// A click on the word at this index of `crumbs`.
    var onCrumb: ((Int) -> Void)?
    /// The Library · Lab · Print selector, in the middle of the window (the main window only).
    var selector: PartSelector? {
        didSet {
            oldValue?.removeFromSuperview()
            if let selector { addSubview(selector) }
            needsLayout = true
        }
    }
    /// Between the trail and the selector.
    static let selectorGap: CGFloat = 16
    private(set) var words: [CrumbWord] = []
    private var separators: [NSTextField] = []
    /// Between the zoom button and the name (`.lights`' 14 pt padding).
    static let gap: CGFloat = 14
    /// Where the name starts in full screen, with no traffic lights.
    static let fullScreenInset: CGFloat = Theme.Size.gutter
    static let separator = "›"
    static let font = Theme.serifFont(15, weight: 600) as NSFont

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.bg.cgColor
        crumbs = [Crumb(text: "Qlick Lab")]
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var crumbs: [Crumb] = [] {
        didSet { if crumbs != oldValue { rebuild() } }
    }

    /// The trail as one line, for a window with no links (Settings).
    var title: String {
        get { crumbs.map(\.text).joined(separator: "  \(Self.separator)  ") }
        set { crumbs = [Crumb(text: newValue)] }
    }

    private func rebuild() {
        words.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        words = crumbs.enumerated().map { index, crumb in
            let word = CrumbWord(text: crumb.text, clickable: crumb.clickable, last: index == crumbs.count - 1)
            word.pressed = { [weak self] in self?.onCrumb?(index) }
            addSubview(word)
            return word
        }
        separators = crumbs.dropFirst().map { _ in
            let mark = NSTextField(labelWithString: Self.separator)
            mark.font = Self.font
            mark.textColor = Theme.NS.faint
            mark.setAccessibilityElement(false)
            addSubview(mark)
            return mark
        }
        needsLayout = true
    }

    /// Only the links and the selector's segments take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is PartSegment { return hit }
        return (hit as? CrumbWord)?.clickable == true ? hit : nil
    }
    override var mouseDownCanMoveWindow: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// Where the word at `index` lies, in the window, for automation.
    func centre(ofCrumb index: Int) -> NSPoint? {
        guard words.indices.contains(index) else { return nil }
        let frame = words[index].frame
        return convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    override func layout() {
        super.layout()
        // Level with the traffic lights, after the zoom button.
        var left = Self.fullScreenInset, middle = bounds.midY
        if let window, !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton),
           let close = window.standardWindowButton(.closeButton), zoom.superview != nil {
            // Qlick Lab: with the sidebar shown the lights are in it, left of the band.
            left = max(convert(zoom.bounds, from: zoom).maxX + Self.gap, Self.fullScreenInset)
            middle = convert(close.bounds, from: close).midY
        }
        // From the text itself: a label's own size can lag a new name.
        func size(_ field: NSTextField) -> NSSize {
            let text = field.attributedStringValue.size()
            return NSSize(width: ceil(text.width) + 4, height: ceil(text.height))
        }
        let markWidth = separators.first.map { size($0).width + 10 } ?? 0
        var widths = words.map { size($0).width }
        // The selector in the middle of the window; a long trail pushes it right, as far as the band allows, before
        // its words give way.
        var right = bounds.width - Theme.Size.gutter
        if let selector {
            let size = selector.fittingSize
            let windowMiddle = window.map { convert(NSPoint(x: $0.frame.width / 2, y: 0), from: nil).x } ?? bounds.midX
            let trail = left + widths.reduce(0, +) + markWidth * CGFloat(separators.count) + Self.selectorGap
            let x = min(max(windowMiddle - size.width / 2, trail, left), max(bounds.width - Theme.Size.gutter - size.width, left))
            selector.frame = NSRect(x: x.rounded(), y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
            right = x - Self.selectorGap
        }
        let room = max(right - left - markWidth * CGFloat(separators.count), 0)
        // Too long: the earlier words give way first, down to a few letters, then the last.
        var over = widths.reduce(0, +) - room
        for index in widths.indices where over > 0 {
            let floor = index == widths.count - 1 ? 0 : min(widths[index], 44)
            let give = min(widths[index] - floor, over)
            widths[index] -= give
            over -= give
        }
        var x = left
        for (index, word) in words.enumerated() {
            if index > 0 {
                let mark = separators[index - 1], height = size(mark).height
                mark.frame = NSRect(x: (x + 5).rounded(), y: (middle - height / 2).rounded(), width: markWidth - 10, height: height)
                x += markWidth
            }
            let height = size(word).height
            word.frame = NSRect(x: x.rounded(), y: (middle - height / 2).rounded(), width: max(widths[index], 0), height: height)
            x += widths[index]
        }
    }
}

/// A word of the title's trail. A link is grey and lights at the pointer, the last word (where the lab is) white.
final class CrumbWord: NSTextField {
    let clickable: Bool
    private let last: Bool
    var pressed: () -> Void = {}
    private var hovered = false { didSet { colour() } }

    init(text: String, clickable: Bool, last: Bool) {
        self.clickable = clickable
        self.last = last
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = TitleBand.font
        lineBreakMode = last ? .byTruncatingMiddle : .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        colour()
        if clickable {
            setAccessibilityRole(.link)
            setAccessibilityLabel(text)
            toolTip = nil
        } else {
            // The window's title says it; VoiceOver reads that.
            setAccessibilityElement(false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func colour() {
        textColor = !clickable && last ? Theme.NS.paper : hovered ? Theme.NS.paper : Theme.NS.dim
    }

    override var mouseDownCanMoveWindow: Bool { !clickable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickable }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard clickable else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard clickable else { return super.mouseDown(with: event) }
        hovered = false
        pressed()
    }

    override func accessibilityPerformPress() -> Bool {
        guard clickable else { return false }
        pressed()
        return true
    }
}

/// The lab's three parts in one capsule, in the middle of the title band: Library · Lab · Print. The part chosen is
/// filled with the lab's red. A segment acts as the mouse goes down, with no animation: the part shows at once.
final class PartSelector: NSView {
    private(set) var segments: [PartSegment] = []
    /// A segment pressed (or chosen by VoiceOver).
    var onChoose: ((LabPart) -> Void)?
    static let height: CGFloat = 24
    static let inset: CGFloat = 2

    var chosen: LabPart = .lab {
        didSet { if chosen != oldValue { segments.forEach { $0.on = $0.part == chosen } } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        segments = LabPart.allCases.map { part in
            let segment = PartSegment(part: part)
            segment.on = part == chosen
            segment.pressed = { [weak self] in self?.onChoose?(part) }
            addSubview(segment)
            return segment
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Library, Lab, Print")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var fittingSize: NSSize {
        NSSize(width: segments.reduce(0) { $0 + $1.width } + Self.inset * 2, height: Self.height)
    }

    override func layout() {
        super.layout()
        var x = Self.inset
        for segment in segments {
            segment.frame = NSRect(x: x, y: Self.inset, width: segment.width, height: bounds.height - Self.inset * 2)
            x += segment.width
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Where a segment lies, in the window, for automation.
    func centre(of part: LabPart) -> NSPoint? {
        guard let segment = segments.first(where: { $0.part == part }) else { return nil }
        return segment.convert(NSPoint(x: segment.bounds.midX, y: segment.bounds.midY), to: nil)
    }
}

/// One part of the selector: its name in spaced capitals, white on red when chosen.
final class PartSegment: NSView {
    let part: LabPart
    var pressed: () -> Void = {}
    var on = false { didSet { if on != oldValue { needsDisplay = true; setAccessibilityValue(on) } } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    static let padding: CGFloat = 13
    static let size = Theme.Caps.size

    init(part: LabPart) {
        self.part = part
        super.init(frame: .zero)
        toolTip = part.help
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(part.title)
        setAccessibilityValue(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func text(on: Bool) -> NSAttributedString {
        NSAttributedString(string: part.title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: Self.size, weight: on ? .semibold : .medium),
            .kern: Self.size * Theme.Caps.tracking,
            .foregroundColor: on ? Theme.NS.onAccent : hovered ? Theme.NS.paper : Theme.NS.dim,
        ])
    }

    /// Wide enough for the name in semibold, so the segments never shift when one is chosen.
    var width: CGFloat { ceil(text(on: true).size().width) + Self.padding * 2 }

    override func draw(_ dirtyRect: NSRect) {
        if on {
            Theme.NS.accent.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let string = text(on: on), size = string.size()
        string.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// On the way down, not on release.
    override func mouseDown(with event: NSEvent) { pressed() }

    override func accessibilityPerformPress() -> Bool { pressed(); return true }
}
