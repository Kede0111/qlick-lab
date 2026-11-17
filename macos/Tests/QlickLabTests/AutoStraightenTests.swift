// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import XCTest
@testable import QlickLab

/// Auto straighten: the lean it reads from a photograph's lines, and which reading it believes.
final class AutoStraightenTests: XCTestCase {
    /// A level street: facades with rows of windows and a pavement, drawn then turned `lean` degrees clockwise
    /// on screen, with the middle kept.
    private func street(lean: Double) -> CGImage {
        let width = 1500, height = 1000
        let drawn = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        drawn.setFillColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1)); drawn.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawn.setFillColor(CGColor(gray: 0.35, alpha: 1)); drawn.fill(CGRect(x: 0, y: 0, width: width, height: 220))
        for block in 0..<4 {
            let x = CGFloat(block) * 375 + 25, top = CGFloat(520 + block * 110)
            drawn.setFillColor(CGColor(gray: 0.55 + CGFloat(block) * 0.08, alpha: 1)); drawn.fill(CGRect(x: x, y: 210, width: 320, height: top - 210))
            drawn.setFillColor(CGColor(gray: 0.15, alpha: 1))
            var y: CGFloat = 260
            while y < top - 70 { for k in 0..<4 { drawn.fill(CGRect(x: x + 25 + CGFloat(k) * 74, y: y, width: 42, height: 52)) }; y += 86 }
        }
        let level = drawn.makeImage()!
        let turned = CGContext(data: nil, width: 1050, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        turned.interpolationQuality = .high
        turned.translateBy(x: 525, y: 350)
        // A context's y runs up: a negative angle turns clockwise on screen.
        turned.rotate(by: -lean * .pi / 180)
        turned.draw(level, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return turned.makeImage()!
    }

    func testReadsTheLeanOfStraightLines() throws {
        for lean in [0.0, 1.3, -2.6, 4.0, -6.5] {
            let (gray, width, height) = try XCTUnwrap(AutoStraighten.luminance(street(lean: lean)))
            let found = try XCTUnwrap(AutoStraighten.estimate(gray: gray, width: width, height: height), "lean \(lean)")
            XCTAssertEqual(found.lean, lean, accuracy: 0.15, "lean \(lean)")
            XCTAssertGreaterThanOrEqual(found.strength, AutoStraighten.clear, "lean \(lean)")
        }
    }

    func testNothingStraightIsNoAnswer() {
        // A soft blob has edges at every angle alike.
        let width = 400, height = 300
        let gray = (0..<width * height).map { index -> Float in
            let x = Double(index % width) - 200, y = Double(index / width) - 150
            return Float(255 * exp(-(x * x + y * y) / 9000))
        }
        XCTAssertNil(AutoStraighten.estimate(gray: gray, width: width, height: height))
    }

    func testWhichReadingIsBelieved() {
        let clear = AutoStraighten.Estimate(lean: 2, strength: 5, source: .both)
        let faint = AutoStraighten.Estimate(lean: 2.9, strength: 1.4, source: .horizontals)
        func horizon(_ lean: Double) -> AutoStraighten.Estimate { .init(lean: lean, strength: 1, source: .horizon) }
        XCTAssertEqual(AutoStraighten.choose(lines: clear) { horizon(-7) }, clear, "Clear lines need no second opinion")
        XCTAssertEqual(AutoStraighten.choose(lines: faint) { horizon(1) }, horizon(1), "Faint lines give way to a horizon near level")
        XCTAssertEqual(AutoStraighten.choose(lines: faint) { horizon(7.5) }, faint, "But not to a large turn they don't back")
        XCTAssertEqual(AutoStraighten.choose(lines: nil) { horizon(7.5) }, horizon(7.5))
        XCTAssertEqual(AutoStraighten.choose(lines: faint) { nil }, faint)
        XCTAssertNil(AutoStraighten.choose(lines: nil) { nil })
    }
}

/// Turning the photograph by dragging outside the crop.
@MainActor final class CropTurnTests: XCTestCase {
    func testOutsideTheCropTurns() {
        let crop = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(CropGeometry.action(at: CGPoint(x: 300, y: 250), frame: crop), .move)
        XCTAssertEqual(CropGeometry.action(at: CGPoint(x: 102, y: 101), frame: crop), CropGeometry.Handle(x: -1, y: -1))
        XCTAssertEqual(CropGeometry.action(at: CGPoint(x: 60, y: 60), frame: crop), CropGeometry.turn)
        XCTAssertEqual(CropGeometry.action(at: CGPoint(x: 300, y: 450), frame: crop), CropGeometry.turn)
    }

    func testTheSweepIsClockwiseOnScreen() throws {
        let middle = CGPoint(x: 0, y: 0)
        // From the right to below, on a screen whose y runs down: a quarter turn clockwise.
        XCTAssertEqual(try XCTUnwrap(CropGeometry.sweep(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 100), about: middle)), 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CropGeometry.sweep(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: -5), about: middle)), -2.862, accuracy: 0.01)
        // Across the left, the shortest way.
        XCTAssertEqual(try XCTUnwrap(CropGeometry.sweep(from: CGPoint(x: -100, y: 1), to: CGPoint(x: -100, y: -1), about: middle)), 1.146, accuracy: 0.01)
        XCTAssertNil(CropGeometry.sweep(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 100, y: 0), about: middle), "Too near the middle to tell")
    }
}
