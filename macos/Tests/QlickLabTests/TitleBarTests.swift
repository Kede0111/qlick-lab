import AppKit
import XCTest
@testable import QlickLab

/// No toolbar (§6.7): the title bar holds only the traffic lights and the
/// file name, "Negs" with no photograph, and the columns start under it.
@MainActor final class TitleBarTests: XCTestCase {
    private let frameKey = "NSWindow Frame editor"

    private func window(_ model: EditorModel) throws -> (EditorWindowController, NSWindow) {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: frameKey)
        addTeardownBlock { defaults.set(saved, forKey: self.frameKey) }
        let controller = EditorWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        controller.editorFrame.split.splitView.autosaveName = nil
        window.setFrameAutosaveName("")
        controller.refresh()
        return (controller, window)
    }

    func testNoToolbarAndTheNameBesideTheTrafficLights() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.toolbar?.items.isEmpty ?? true, "no toolbar items")
        XCTAssertFalse(window.toolbar?.allowsUserCustomization ?? false)
        XCTAssertEqual(window.titleVisibility, .hidden, "the band shows the name, not AppKit's title")
        XCTAssertEqual(window.title, "Qlick Lab")
        let band = controller.editorFrame.band
        XCTAssertEqual(band.title, "Qlick Lab")
        XCTAssertEqual(band.words[0].font?.pointSize, 13.5)
        let frame = controller.editorFrame.view
        // Clicks on the band reach the title bar under it, which drags and zooms.
        XCTAssertNil(frame.hitTest(NSPoint(x: 400, y: frame.bounds.height - 19)), "the window drags from the band")
        XCTAssertNotNil(frame.hitTest(NSPoint(x: 400, y: frame.bounds.height - 100)), "the columns take their clicks")
        XCTAssertEqual(band.frame, NSRect(x: 0, y: frame.bounds.height - 38, width: frame.bounds.width, height: 38))
        XCTAssertEqual(controller.editorFrame.split.view.frame,
                       NSRect(x: 0, y: 0, width: frame.bounds.width, height: frame.bounds.height - 38), "the columns start under it")

        // AppKit's title bar, which holds the traffic lights, is about the band's height.
        XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, Theme.Size.titleBar, accuracy: 3)
        band.layoutSubtreeIfNeeded()
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(band.words[0].frame.minX, max(band.convert(zoom.bounds, from: zoom).maxX + TitleBand.gap, TitleBand.fullScreenInset), accuracy: 1, "after the traffic lights, or at the band's edge beside the lab's sidebar")
        XCTAssertEqual(band.words[0].frame.midY, band.convert(close.bounds, from: close).midY, accuracy: 1, "level with them")

        // Resizing keeps the band on top and the columns under it.
        window.setContentSize(NSSize(width: 1000, height: 600))
        XCTAssertEqual(band.frame.minY, frame.bounds.height - 38)
        XCTAssertEqual(controller.editorFrame.split.view.frame.height, frame.bounds.height - 38)
    }

    func testTheTitleIsTheFileNameInTheGridToo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("DSC_2650.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 3,
                                                    hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48 * 3, bitsPerPixel: 24))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)

        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        model.open(photo)
        controller.refresh()
        XCTAssertEqual(window.title, "DSC_2650.png")
        XCTAssertEqual(controller.editorFrame.band.title, "DSC_2650.png")

        model.showGrid()
        controller.refresh()
        XCTAssertEqual(controller.editorFrame.band.title, model.lab.title, "Qlick Lab: the sheet is named after its roll or folder")
        XCTAssertEqual(window.subtitle, "")
    }

    /// Qlick Lab: the title is a trail whose earlier words are links. They take their clicks through the window
    /// (whose title bar would keep them for dragging); the rest of the band still drags the window.
    func testTheTrailsLinksTakeClicks() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let band = controller.editorFrame.band
        var pressed: [Int] = []
        band.onCrumb = { pressed.append($0) }
        band.crumbs = [.init(text: "Coast Trip", clickable: true), .init(text: "Roll 01", clickable: true), .init(text: "L1001001.DNG")]
        band.layoutSubtreeIfNeeded()
        XCTAssertEqual(band.title, "Coast Trip  ›  Roll 01  ›  L1001001.DNG")
        XCTAssertEqual(band.words.map(\.stringValue), ["Coast Trip", "Roll 01", "L1001001.DNG"])
        XCTAssertLessThan(band.words[0].frame.maxX, band.words[1].frame.minX, "side by side, a mark between")

        let frame = controller.editorFrame.view
        func click(_ index: Int) {
            let point = band.words[index].convert(NSPoint(x: band.words[index].bounds.midX, y: band.words[index].bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        }
        click(1); click(0); click(2)
        XCTAssertEqual(pressed, [1, 0], "the links answer; the last word, where the lab is, doesn't")
        let last = band.words[2]
        XCTAssertNil(frame.hitTest(frame.convert(NSPoint(x: last.frame.midX, y: last.frame.midY), from: band)), "the window drags from the last word")
        XCTAssertNil(frame.hitTest(NSPoint(x: frame.bounds.width - 100, y: frame.bounds.height - 19)), "and from the rest of the band")

        // Too long for the band: the words shrink and stay inside it.
        window.setContentSize(NSSize(width: 1000, height: 600))
        band.crumbs = [.init(text: String(repeating: "Very long project ", count: 6), clickable: true), .init(text: String(repeating: "roll ", count: 30), clickable: true), .init(text: "L1001001.DNG")]
        band.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(band.words[2].frame.maxX, band.bounds.width - Theme.Size.gutter + 1)
        XCTAssertGreaterThan(band.words[2].frame.width, 60, "the photograph's name keeps its room")
    }

    /// The smallest window: a 640 pt canvas beside the inspector at 340 (§7).
    func testTheSmallestWindow() throws {
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let (controller, window) = try window(model)
        let split = controller.editorFrame.split
        XCTAssertEqual(split.splitViewItems[0].minimumThickness, 640)
        XCTAssertEqual(split.splitViewItems[1].minimumThickness, 340)
        XCTAssertEqual(window.contentMinSize.height, 560)
    }
}
