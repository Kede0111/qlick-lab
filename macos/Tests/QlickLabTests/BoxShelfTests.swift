import AppKit
import SwiftUI
import XCTest
@testable import QlickLab

/// R8: an open Box lays its Boxes and Rolls on a shelf above its own photographs, on the frames' columns; and the
/// lab's own glyphs draw inside their squares.
final class BoxShelfTests: XCTestCase {
    private var catalogue: URL!

    override func setUpWithError() throws {
        catalogue = FileManager.default.temporaryDirectory.appendingPathComponent("BoxShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: catalogue) }

    func testObjectsKeepToTheFramesColumns() {
        // Frames 168 wide every 177: a Box takes one column, a Roll two.
        let layout = BoxShelfLayout(spans: [1, 1, 2, 2, 2], width: 6 * 177 - 9 + 24, frame: CGSize(width: 168, height: 112), pitch: 177, lead: 12)
        XCTAssertEqual(layout.columns, 6)
        XCTAssertEqual(layout.unit, 1)
        XCTAssertEqual(layout.art, CGSize(width: 168, height: 112))
        XCTAssertEqual(layout.rects.map(\.minX), [12, 189, 366, 720, 12], "a Roll that doesn't fit goes to the next row, at the first column")
        XCTAssertEqual(layout.rects[2].width, 177 + 168, "a Roll spans two columns")
        XCTAssertEqual(layout.rects[3].minY, 0)
        XCTAssertEqual(layout.rects[4].minY, 112 + BoxShelfLayout.nameBand + BoxShelfLayout.rowGap)
        XCTAssertEqual(layout.height, layout.rects[4].maxY + 8 + BoxShelfLayout.foot)
        XCTAssertEqual(layout.index(at: CGPoint(x: 200, y: 20)), 1)
        XCTAssertNil(layout.index(at: CGPoint(x: 185, y: 20)), "between two objects")
    }

    func testSmallFramesGiveTheObjectsSeveralColumns() {
        let layout = BoxShelfLayout(spans: [1, 2], width: 1000, frame: CGSize(width: 60, height: 40), pitch: 66)
        XCTAssertEqual(layout.unit, 2, "never narrower than \(BoxShelfLayout.smallest)")
        XCTAssertEqual(layout.art.width, 2 * 66 - 6)
        XCTAssertEqual(layout.rects.map(\.width), [126, 4 * 66 - 6])
        XCTAssertEqual(layout.rects[1].minX, 132, "on the third column")
    }

    func testANarrowSheetStillShowsEveryObject() {
        let layout = BoxShelfLayout(spans: [2, 1, 2], width: 200, frame: CGSize(width: 168, height: 112), pitch: 177)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.rects.count, 3)
        XCTAssertTrue(layout.rects.allSatisfy { $0.minX == 0 && $0.width == 168 }, "one per row, as wide as the sheet allows")
        XCTAssertEqual(Set(layout.rects.map(\.minY)).count, 3)
    }

    func testNotesAndAnEmptyShelf() {
        XCTAssertEqual(BoxShelfLayout(spans: [], width: 900, frame: CGSize(width: 168, height: 112), pitch: 177).height, 0, "nothing inside: no shelf")
        let empty = BoxShelfLayout(spans: [], width: 900, frame: CGSize(width: 168, height: 112), pitch: 177, note: .empty)
        XCTAssertEqual(empty.noteRect.minY, 0)
        XCTAssertEqual(empty.height, BoxShelfLayout.emptyBlock + BoxShelfLayout.foot)
        let loose = BoxShelfLayout(spans: [1], width: 900, frame: CGSize(width: 168, height: 112), pitch: 177, note: .nothingLoose)
        XCTAssertEqual(loose.noteRect.minY, loose.rects[0].maxY + 8)
        XCTAssertEqual(loose.height, loose.noteRect.maxY + BoxShelfLayout.foot)
    }

    @MainActor func testABoxShowsItsOwnPhotographsAndItsShelf() throws {
        let store = ProjectStore(directory: catalogue)
        let a = catalogue.appendingPathComponent("A", isDirectory: true)
        let urls = ["A1.DNG", "A2.DNG", "A3.DNG", "A4.DNG"].map { a.appendingPathComponent($0) }
        let spain = try XCTUnwrap(store.createBox(named: "Spain", frames: [urls[0]]))
        let madrid = try XCTUnwrap(store.createBox(named: "Madrid", in: spain.id, frames: [urls[1]]))
        _ = try XCTUnwrap(store.createRoll(named: "Night", in: madrid.id, frames: [urls[2]]))
        let day = try XCTUnwrap(store.createRoll(named: "Day 1", in: spain.id, frames: [urls[3], urls[2], urls[1]]))
        let empty = try XCTUnwrap(store.createRoll(named: "Day 2", in: spain.id))

        XCTAssertEqual(store.ownFrames(of: .box(spain.id)), [urls[0].path], "its own photographs only")
        XCTAssertEqual(store.frames(of: .box(spain.id)).count, 4, "the sidebar still counts everything in it")
        let shelf = store.shelf(of: spain.id)
        XCTAssertEqual(shelf.map(\.name), ["Madrid", "Day 1", "Day 2"], "Boxes first, then Rolls")
        XCTAssertEqual(shelf.map(\.kind), [.box, .roll, .roll])
        XCTAssertEqual(shelf[0].detail, "2 photographs · 1 Roll")
        XCTAssertEqual(shelf[1].leader, [urls[3].path, urls[2].path], "two frames out of the canister")
        XCTAssertEqual(shelf[1].detail, "3 photographs")
        XCTAssertTrue(shelf[2].leader.isEmpty)
        XCTAssertEqual(shelf[1].drag, .roll(day.id, box: spain.id))
        XCTAssertEqual(shelf[2].target, .roll(empty.id, box: spain.id))

        // Taking a photograph out of the Box leaves the Rolls inside it alone.
        store.addFrames([urls[3]], to: .box(spain.id))
        store.removeFrames([urls[3]], from: .box(spain.id))
        XCTAssertEqual(store.frames(of: .roll(day.id, box: spain.id)).first, urls[3].path)
        XCTAssertTrue(store.holdsAnything(spain.id))
        XCTAssertFalse(store.holdsAnything(try XCTUnwrap(store.createBox(named: "Nothing")).id))
    }

    @MainActor func testGlyphsDrawInsideTheirSquare() throws {
        let side = 40
        for glyph in LabGlyph.allCases {
            let renderer = ImageRenderer(content: LabGlyphView(glyph: glyph, size: CGFloat(side), color: .white).background(Color.black))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage, glyph.rawValue)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var lit = 0, edge = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    guard let colour = bitmap.colorAt(x: x, y: y), colour.brightnessComponent > 0.3 else { continue }
                    lit += 1
                    if x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 { edge += 1 }
                }
            }
            XCTAssertGreaterThan(lit, side * side / 25, "\(glyph) draws something (a fine line)")
            XCTAssertLessThan(lit, side * side * 3 / 4, "\(glyph) isn't a solid square")
            XCTAssertLessThanOrEqual(edge, 4, "\(glyph) stays inside its square")
            XCTAssertEqual(LabGlyph(symbol: glyph.symbol), glyph)
        }
        XCTAssertNil(LabGlyph(symbol: "folder"), "a system symbol stays one")

        // QLICK_GLYPH_SHEET=<file.png>: every glyph at 14, 16, 20 and 48 points, at 2×, to look at.
        if let path = ProcessInfo.processInfo.environment["QLICK_GLYPH_SHEET"] {
            let sheet = VStack(alignment: .leading, spacing: 10) {
                ForEach([14, 16, 20, 48], id: \.self) { size in
                    HStack(spacing: 12) {
                        ForEach(LabGlyph.allCases, id: \.self) { glyph in
                            LabGlyphView(glyph: glyph, size: CGFloat(size), color: Color(white: 0.78))
                        }
                    }
                }
                HStack(spacing: 12) {
                    ForEach(LabGlyph.allCases, id: \.self) { glyph in LabGlyphView(glyph: glyph, size: 20, color: Theme.accent) }
                }
            }
            .padding(16).background(Color(white: 0.09))
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
