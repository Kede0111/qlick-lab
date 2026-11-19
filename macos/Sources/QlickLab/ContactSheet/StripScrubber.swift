// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Holds the filmstrip's scroll view for its scrollbar.
@MainActor final class StripScrubberLink {
    weak var scrollView: NSScrollView? { didSet { if scrollView !== oldValue { view?.attach(scrollView) } } }
    weak var view: StripScrubberView?
}

/// The filmstrip's scrollbar: always there, a thin track along the strip's foot with a thumb as long as the part of
/// the roll in view. Drag the thumb, or click the track to go there.
struct StripScrubber: NSViewRepresentable {
    let link: StripScrubberLink
    func makeNSView(context: Context) -> StripScrubberView {
        let view = StripScrubberView()
        link.view = view
        view.attach(link.scrollView)
        return view
    }
    func updateNSView(_ view: StripScrubberView, context: Context) {
        link.view = view
        if view.scrollView !== link.scrollView { view.attach(link.scrollView) }
    }
}

final class StripScrubberView: NSView {
    private(set) weak var scrollView: NSScrollView?
    // Written on the main actor; read once more by deinit, when nothing else holds the object.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var grab: CGFloat?
    private var hovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ scrollView: NSScrollView?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.scrollView = scrollView
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
        needsDisplay = true
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var track: CGRect { bounds.insetBy(dx: 8, dy: 3) }

    /// The thumb's rectangle, or nil when the whole roll is in view.
    private var thumb: CGRect? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let content = document.frame.width, visible = scrollView.contentView.bounds
        guard content > visible.width + 1 else { return nil }
        let length = max(track.width * visible.width / content, 28)
        let x = track.minX + (track.width - length) * visible.minX / (content - visible.width)
        return CGRect(x: x, y: track.minY, width: length, height: track.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let thumb else { return }
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        NSColor(white: 1, alpha: grab != nil ? 0.75 : hovered ? 0.55 : 0.38).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
    }

    /// Scrolls so the thumb starts at `x`.
    private func scroll(thumbAt x: CGFloat) {
        guard let scrollView, let document = scrollView.documentView, let thumb else { return }
        let content = document.frame.width, visible = scrollView.contentView.bounds
        let t = min(max((x - track.minX) / max(track.width - thumb.width, 1), 0), 1)
        scrollView.contentView.scroll(to: CGPoint(x: t * (content - visible.width), y: visible.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let thumb else { return }
        if thumb.contains(point) { grab = point.x - thumb.minX } else {
            // A click on the track brings the thumb's middle there, then drags it.
            grab = thumb.width / 2
            scroll(thumbAt: point.x - thumb.width / 2)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        scroll(thumbAt: convert(event.locationInWindow, from: nil).x - grab)
    }
    override func mouseUp(with event: NSEvent) { grab = nil; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
