import AppKit
import XCTest
@testable import QlickLab

/// The loupes and Import's comparison lie on the Compare room's canvas.
@MainActor final class FrameCanvasTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Red in the top-left corner, to see where it goes.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 2, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    func testQuarterTurns() throws {
        let picture = try image(30, 20)
        XCTAssertTrue(picture.turned(0) === picture)
        XCTAssertTrue(picture.turned(4) === picture)
        let right = picture.turned(1)
        XCTAssertEqual([right.width, right.height], [20, 30])
        XCTAssertEqual([picture.turned(2).width, picture.turned(2).height], [30, 20])
        XCTAssertEqual([picture.turned(-1).width, picture.turned(-1).height], [20, 30])
        // Clockwise: the top-left corner goes to the top right.
        let data = try XCTUnwrap(right.dataProvider?.data as Data?)
        let row = right.bytesPerRow, last = (right.width - 1) * 4
        XCTAssertGreaterThan(data[last], 200, "red at the top right")
        XCTAssertLessThan(data[row * (right.height - 1)], 50, "not at the bottom left")
    }

    func testTheReadoutFollowsTheCanvas() throws {
        let control = FrameCanvasControl()
        let canvas = CompareCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        control.canvas = canvas
        XCTAssertTrue(control.fitted)
        canvas.panes = [.init(image: try image(800, 600))]
        canvas.setZoom(2)
        XCTAssertEqual(canvas.viewport.zoom, 2, accuracy: 0.001)
        control.fit()
        XCTAssertEqual(canvas.viewport.zoom, 1, accuracy: 0.001)
    }
}
