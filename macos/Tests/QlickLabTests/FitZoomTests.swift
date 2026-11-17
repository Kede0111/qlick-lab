import AppKit
import XCTest
@testable import QlickLab

/// Fitting shows the whole photograph, but never past 1:1 (one photograph
/// pixel per screen pixel, half a point on Retina).
@MainActor final class FitZoomTests: XCTestCase {
    private let viewport = CGSize(width: 1000, height: 750)

    func testLargePhotographsFitTheViewport() {
        let amount = ImageScrollView.magnification(fitting: true, document: CGSize(width: 6000, height: 4000), viewport: viewport, backingScale: 2)
        XCTAssertEqual(amount, 1000.0 / 6000, accuracy: 1e-9)
    }

    func testSmallPhotographsStopAtOneToOne() {
        let retina = ImageScrollView.magnification(fitting: true, document: CGSize(width: 1600, height: 1067), viewport: viewport, backingScale: 2)
        XCTAssertEqual(retina, 0.5, accuracy: 1e-9, "Fit would enlarge to 0.625; 1:1 on Retina is 0.5")
        let standard = ImageScrollView.magnification(fitting: true, document: CGSize(width: 800, height: 600), viewport: viewport, backingScale: 1)
        XCTAssertEqual(standard, 1, accuracy: 1e-9)
    }

    func testActualSizeIgnoresTheViewport() {
        let amount = ImageScrollView.magnification(fitting: false, document: CGSize(width: 6000, height: 4000), viewport: viewport, backingScale: 2)
        XCTAssertEqual(amount, 0.5, accuracy: 1e-9)
    }

    /// A double-click fits a zoomed photograph and shows the grid from a fitted one.
    func testZoomedIsAnyMagnificationButTheFit() {
        func zoomed(_ magnification: CGFloat, _ document: CGSize) -> Bool {
            ImageScrollView.zoomed(magnification, minimum: 0.005, maximum: 16, document: document, viewport: viewport, backingScale: 2)
        }
        let large = CGSize(width: 6000, height: 4000), small = CGSize(width: 800, height: 600)
        XCTAssertFalse(zoomed(1000.0 / 6000, large), "fitted")
        XCTAssertFalse(zoomed(1000.0 / 6000 * 1.001, large), "a pinch back to the fit")
        XCTAssertTrue(zoomed(0.5, large), "1:1")
        XCTAssertTrue(zoomed(0.1, large), "smaller than the fit")
        XCTAssertFalse(zoomed(0.5, small), "1:1 is the fit of a small photograph")
        XCTAssertTrue(zoomed(2, small))
        XCTAssertFalse(zoomed(1, .zero), "no photograph yet")
    }

    func testTheCanvasTellsTheDoubleClickWhetherItsZoomed() {
        let scroll = ImageScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        scroll.documentView = PhotographView(frame: NSRect(x: 0, y: 0, width: 6000, height: 4000))
        var clicks: [Bool] = []
        scroll.doubleClick = { clicks.append($0) }
        scroll.applyZoom()
        scroll.doubleClicked()
        scroll.fitting = false; scroll.magnification = 0.5
        scroll.doubleClicked()
        XCTAssertEqual(clicks, [false, true])
    }

    /// Qlick Lab: a double-click on the fitted photograph zooms to 1:1 where it was, and a second fits it again.
    func testADoubleClickZoomsToOneToOneWhereItWas() {
        let scroll = ImageScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        let photo = PhotographView(frame: NSRect(x: 0, y: 0, width: 6000, height: 4000))
        scroll.documentView = photo
        var clicks: [Bool] = []
        scroll.doubleClick = { clicks.append($0) }
        scroll.applyZoom()
        let place = CGPoint(x: 1500, y: 3000)
        let before = scroll.convert(place, from: photo)
        scroll.doubleClicked(at: place)
        XCTAssertFalse(scroll.fitting)
        // Without a window the backing scale is taken as 2: 1:1 is a magnification of a half.
        XCTAssertEqual(scroll.magnification, 0.5, accuracy: 1e-6)
        let after = scroll.convert(place, from: photo)
        XCTAssertEqual(after.x, before.x, accuracy: 1)
        XCTAssertEqual(after.y, before.y, accuracy: 1)
        XCTAssertEqual(clicks, [], "Zooming in isn't the photograph's own double-click")
        scroll.doubleClicked(at: place)
        XCTAssertEqual(clicks, [true], "Zoomed, it fits again")
    }
}
