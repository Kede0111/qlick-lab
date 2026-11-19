import XCTest
@testable import QlickLab

/// A whole project and a selection are lists of photographs from several folders: nothing is made on disk.
@MainActor final class LabSelectionTests: XCTestCase {
    private func rolls() throws -> (root: URL, a: URL, b: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-selection-\(UUID().uuidString)")
        let a = root.appendingPathComponent("Roll A", isDirectory: true), b = root.appendingPathComponent("Roll B", isDirectory: true)
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["A1.DNG", "A2.DNG", "A3.jpg"] { try Data().write(to: a.appendingPathComponent(name)) }
        for name in ["B1.DNG", "B2.DNG"] { try Data().write(to: b.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to: b.appendingPathComponent("B2.DNG.qlick"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, a, b)
    }

    func testAWholeProjectListsItsRollsWithoutLinks() throws {
        let (root, a, b) = try rolls()
        let store = ProjectStore(directory: root.appendingPathComponent("catalogue.qlicklab"))
        let project = store.create(named: "Trip")
        store.addRolls([b, a], to: project.id)
        let list = store.viewFolder(for: try XCTUnwrap(store.projects.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: list.path), "nothing made on disk")
        XCTAssertEqual(store.project(viewFolder: list)?.id, project.id)
        let listing = try PhotoFolder.listing(in: list)
        XCTAssertEqual(listing.photos.map(\.name), ["B1.DNG", "B2.DNG", "A1.DNG", "A2.DNG", "A3.jpg"], "roll by roll, in the project's order")
        XCTAssertEqual(listing.photos.first?.url.deletingLastPathComponent().lastPathComponent, "Roll B", "at their own paths")
        XCTAssertNotNil(listing.sidecars[PhotoFolder.sidecarKey(b.appendingPathComponent("B2.DNG"))])
        XCTAssertEqual(PhotoFolder.folders(of: list).map(\.lastPathComponent), ["Roll B", "Roll A"])
    }

    func testASelectionHoldsFramesFromSeveralRolls() throws {
        let (root, a, b) = try rolls()
        let store = ProjectStore(directory: root.appendingPathComponent("catalogue.qlicklab"))
        let selection = store.createSelection(named: "Portfolio", frames: [b.appendingPathComponent("B2.DNG"), a.appendingPathComponent("A1.DNG")])
        XCTAssertTrue(selection.isSelection)
        XCTAssertTrue(store.ordinary.isEmpty, "a selection isn't a project")
        // A version is its photograph; a frame already in stays where it is.
        store.addFrames([a.appendingPathComponent("A3.jpg").variant("x1"), b.appendingPathComponent("B2.DNG")], to: selection.id)
        var list = store.viewFolder(for: try XCTUnwrap(store.selections.first))
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["B2.DNG", "A1.DNG", "A3.jpg"])
        XCTAssertNotNil(try PhotoFolder.listing(in: list).sidecars[PhotoFolder.sidecarKey(b.appendingPathComponent("B2.DNG"))])

        store.removeFrames([a.appendingPathComponent("A1.DNG")], from: selection.id)
        list = store.viewFolder(for: try XCTUnwrap(store.selections.first))
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["B2.DNG", "A3.jpg"])

        // A frame whose file went is left out; the rest still lists.
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["B2.DNG"])

        // Kept in the catalogue, and read back as a selection.
        let again = ProjectStore(directory: root.appendingPathComponent("catalogue.qlicklab"))
        XCTAssertEqual(again.selections.map(\.name), ["Portfolio"])
        XCTAssertEqual(again.selections.first?.frames?.count, 2)
        XCTAssertEqual(store.createSelection(named: "Portfolio").name, "Portfolio 2")
    }

    func testTheOldFoldersOfLinksAreRemoved() throws {
        let (root, a, _) = try rolls()
        let catalogue = root.appendingPathComponent("catalogue.qlicklab")
        let views = catalogue.appendingPathComponent("Views/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: views.appendingPathComponent("000 Roll A"), withDestinationURL: a)
        _ = ProjectStore(directory: catalogue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogue.appendingPathComponent("Views").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path).count, 3, "the photographs the links led to are untouched")
    }
}
