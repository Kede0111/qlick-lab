// Qlick Lab — GPL-3.0-only.
import AppKit
import XCTest
@testable import QlickLab

/// The three parts, Library · Lab · Print: their rooms, the selector, the sidebar that follows it, and the one key
/// between Develop and the contact sheet.
@MainActor final class LabPartTests: XCTestCase {
    func testEveryRoomBelongsToOnePartAndTheSheetToTheLibraryAndTheLab() {
        for room in Workspace.ordered where room != .library {
            let parts = LabPart.allCases.filter { $0.rooms.contains(room) }
            XCTAssertEqual(parts.count, 1, "\(room) is listed under one part")
        }
        XCTAssertNil(LabPart.of(.contactSheet))
        XCTAssertEqual(LabPart.of(.importer), .library)
        XCTAssertEqual(LabPart.of(.papers), .lab)
        XCTAssertEqual(LabPart.of(.print), .print)
        XCTAssertEqual(LabPart.allCases.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(LabPart.allCases.map(\.title), ["Library", "Lab", "Print"])
    }

    func testChoosingAPartReturnsToItsRoomAndLabAgainSwitchesToTheSheet() {
        let model = EditorModel()
        defer { model.shutdown() }
        let lab = model.lab
        XCTAssertEqual(lab.part, .lab)
        lab.show(.recipes)
        lab.choose(.print)
        XCTAssertEqual(lab.workspace, .print)
        XCTAssertEqual(lab.part, .print)
        lab.choose(.library)
        XCTAssertEqual(lab.workspace, .contactSheet, "the Library opens on the contact sheet the first time")
        XCTAssertEqual(lab.part, .library)
        lab.show(.importer)
        lab.choose(.lab)
        XCTAssertEqual(lab.workspace, .recipes, "back to the Lab's room as it was left")
        lab.choose(.library)
        XCTAssertEqual(lab.workspace, .importer)

        // The Library's room is the Library's, and the Lab comes back to Develop.
        lab.choose(.lab)
        lab.show(.develop)
        lab.choose(.library)
        lab.choose(.print)
        lab.choose(.library)
        XCTAssertEqual(lab.part, .library)
        lab.choose(.lab)
        XCTAssertEqual(lab.workspace, .develop)
        XCTAssertEqual(lab.part, .lab)
        // From Develop, Lab again (or G) shows the contact sheet without leaving the Lab, and back.
        lab.choose(.lab)
        XCTAssertEqual(lab.workspace, .contactSheet)
        XCTAssertEqual(lab.part, .lab)
        lab.toggleSheet()
        XCTAssertEqual(lab.workspace, .develop)
        XCTAssertEqual(lab.part, .lab)
    }

    func testTheSelectorDrawsThePartChosenAndActsAsTheMouseGoesDown() throws {
        let selector = PartSelector()
        var chosen: [LabPart] = []
        selector.onChoose = { chosen.append($0) }
        selector.frame.size = selector.fittingSize
        selector.layoutSubtreeIfNeeded()
        XCTAssertEqual(selector.segments.map(\.part), LabPart.allCases)
        XCTAssertEqual(selector.segments.filter(\.on).map(\.part), [.lab])
        let print = try XCTUnwrap(selector.segments.last)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        print.mouseDown(with: down)
        XCTAssertEqual(chosen, [.print], "on the way down")
        selector.chosen = .print
        XCTAssertEqual(selector.segments.filter(\.on).map(\.part), [.print])
        // The segments keep their widths whichever is chosen.
        let widths = selector.segments.map(\.width)
        selector.chosen = .library
        XCTAssertEqual(selector.segments.map(\.width), widths)
        // The band takes the segments' clicks, and keeps its other clicks for the window.
        let band = TitleBand()
        band.frame = NSRect(x: 0, y: 0, width: 900, height: Theme.Size.titleBar)
        band.selector = selector
        band.layoutSubtreeIfNeeded()
        let middle = NSPoint(x: selector.frame.minX + print.frame.midX, y: selector.frame.midY)
        XCTAssertTrue(band.hitTest(middle) is PartSegment)
        XCTAssertNil(band.hitTest(NSPoint(x: 880, y: 19)))
    }

    /// Compare opened from its sidebar row (not the sheet's Compare) lays the photographs selected side by side.
    func testCompareFromAnywhereTakesTheSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photos: [URL] = []
        for name in ["a.png", "b.png", "c.png"] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 3,
                                                        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 72, bitsPerPixel: 24))
            let url = folder.appendingPathComponent(name)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            photos.append(url)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = EnginePaths(helper: root.appendingPathComponent("target/release/spektrafilm-native"),
                                exporter: root.appendingPathComponent("target/release/spektrafilm-f64"), data: root.appendingPathComponent("data"))
        guard FileManager.default.isExecutableFile(atPath: paths.helper.path) else { throw XCTSkip("Build the release helper first") }
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        await model.start(paths: paths)
        model.open(photos[0])
        let watching = Task { await model.library.watch(folder) }
        defer { watching.cancel() }
        for _ in 0..<500 where model.shownPhotos.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.shownPhotos.count, 3)
        model.selectAll()
        let lab = model.lab
        lab.compare = CompareSetup()
        lab.show(.compare)
        XCTAssertEqual(Set(lab.compare.items.map(\.standardizedFileURL)), Set(photos.map(\.standardizedFileURL)))
    }
}
