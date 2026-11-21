// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import QlickLab

/// Print's colour check: what an output space can't hold, and the photograph's colours on the xy diagram.
final class GamutTests: XCTestCase {
    /// QLICK_GAMUT_SHEET=<file.png>: the diagram, to look at.
    @MainActor func testTheDiagramDraws() throws {
        let extra: [Gamut.Dot] = (0..<400).map { (i: Int) -> Gamut.Dot in
            Gamut.Dot(x: CGFloat(0.3 + 0.1 * sin(Double(i))), y: CGFloat(0.33 + 0.1 * cos(Double(i) * 1.3)), r: 1, g: Float(i % 7) / 7, b: Float(i % 5) / 5)
        }
        let cloud = Gamut.cloud(try picture()) + extra
        let renderer = ImageRenderer(content: GamutDiagram(space: "sRGB", cloud: cloud).frame(width: 240).padding(10).background(Theme.panel))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(image.width, 200)
        if let path = ProcessInfo.processInfo.environment["QLICK_GAMUT_SHEET"],
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Half a pure Rec. 2020 green (far out of sRGB, inside ProPhoto), half a mid grey.
    private func picture() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma))
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.5, 0.5, 1])!)
        context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        return try XCTUnwrap(context.makeImage())
    }

    func testWhatASpaceCantHoldIsMarked() throws {
        let image = try picture()
        let srgb = try XCTUnwrap(Gamut.check(image, against: "sRGB", marking: true))
        XCTAssertEqual(srgb.fraction, 0.5, accuracy: 0.01, "the green is out of sRGB, the grey in")
        XCTAssertNotNil(srgb.marks)
        XCTAssertEqual(srgb.marks?.width, 20)
        let prophoto = try XCTUnwrap(Gamut.check(image, against: "ProPhoto RGB", marking: false))
        XCTAssertEqual(prophoto.fraction, 0, accuracy: 0.001, "ProPhoto RGB holds Rec. 2020's green")
        XCTAssertNil(prophoto.marks)
        XCTAssertEqual(Gamut.markHex == Theme.Hex.accent, false, "the marks aren't the lab's red")
    }

    func testTheCloudLiesOnTheDiagram() throws {
        let cloud = Gamut.cloud(try picture())
        XCTAssertFalse(cloud.isEmpty)
        // The grey near the white point, the green near Rec. 2020's green primary (0.170, 0.797).
        XCTAssertTrue(cloud.contains { abs($0.x - 0.3127) < 0.01 && abs($0.y - 0.329) < 0.01 })
        XCTAssertTrue(cloud.contains { abs($0.x - 0.170) < 0.02 && abs($0.y - 0.797) < 0.02 })
        // Each dot keeps its colour: the green is green at full brightness, the grey neutral.
        XCTAssertTrue(cloud.contains { $0.g == 1 && $0.r < 0.05 && $0.b < 0.05 })
        XCTAssertTrue(cloud.contains { abs($0.r - $0.g) < 0.02 && abs($0.g - $0.b) < 0.02 })
        for name in SaveSettings.colorSpaces { XCTAssertEqual(Gamut.primaries(name)?.count, 3, name); XCTAssertNotNil(Gamut.space(name), name) }
        XCTAssertGreaterThan(Gamut.locus.count, 30)
    }
}
