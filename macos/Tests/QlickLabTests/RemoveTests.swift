import XCTest
@testable import QlickLab

/// 0.4's R3: Remove from Qlick Lab is the catalogue's alone (an exclusion list, out of every Box, undoable and
/// reversible); the files never move. The dialog offers the safest first; Delete from Disk is asked again in red words.
@MainActor final class RemoveTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        PhotoFolder.excluded = []
        try? FileManager.default.removeItem(at: root)
    }

    private var catalogue: URL { root.appendingPathComponent("catalogue.qlicklab", isDirectory: true) }

    private func photos(_ folder: String, _ names: [String]) throws -> URL {
        let url = root.appendingPathComponent("photos/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data("photograph \(name)".utf8).write(to: url.appendingPathComponent(name)) }
        return url
    }

    /// Every file under the photographs, with its bytes and dates: what must not change.
    private func disk() throws -> [String: String] {
        let base = root.appendingPathComponent("photos")
        var files: [String: String] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: base.path) ?? NSEnumerator() {
            let url = base.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values.isDirectory != true else { continue }
            files[path] = "\(try Data(contentsOf: url).base64EncodedString()) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return files
    }

    private func listed(_ folder: URL) throws -> [String] { try PhotoFolder.listing(in: folder).photos.map(\.name) }

    func testRemoveFromQlickLabIsTheCatalogueAloneAndComesBack() throws {
        let a = try photos("A", ["A1.jpg", "A2.jpg", "A3.jpg"])
        let deeper = try photos("A/day 2", ["B1.jpg"])
        let before = try disk()
        let store = ProjectStore(directory: catalogue)
        let made = store.create(named: "Leica")
        store.addRolls([a], to: made.id)
        let archive = try XCTUnwrap(store.archive(made.id))
        let a1 = a.appendingPathComponent("A1.jpg"), a2 = a.appendingPathComponent("A2.jpg"), b1 = deeper.appendingPathComponent("B1.jpg")
        let spain = try XCTUnwrap(store.createBox(named: "Spain", frames: [a1, a2]))
        let madrid = try XCTUnwrap(store.createBox(named: "Madrid", in: spain.id, frames: [a1]))
        let day = try XCTUnwrap(store.createRoll(named: "Day 1", in: madrid.id, frames: [a1, b1]))

        // A duplicate stands for its photograph.
        XCTAssertTrue(store.removeFromLab([a1.variant("x2"), b1]))
        XCTAssertEqual(store.removed, Set([a1, b1].map(\.standardizedFileURL.path)))
        XCTAssertEqual(try listed(a), ["A2.jpg", "A3.jpg"], "out of the listing")
        XCTAssertEqual(try listed(deeper), [])
        XCTAssertEqual(ProjectStore.stats(of: a, store: nil).total, 2, "and of the counts")
        XCTAssertEqual(FolderTrees.read(a)?.total, 2)
        XCTAssertEqual(store.frames(of: .box(spain.id)).map { ($0 as NSString).lastPathComponent }, ["A2.jpg"], "out of every Box")
        XCTAssertEqual(store.frames(of: .roll(day.id, box: madrid.id)), [])
        XCTAssertEqual(store.removed(in: archive).count, 2)
        XCTAssertEqual(try disk(), before, "nothing on the disk changed")

        // Kept in the catalogue.
        let again = ProjectStore(directory: catalogue)
        XCTAssertEqual(again.removed, store.removed)
        XCTAssertNotNil(RemovedFile.read(inCatalog: catalogue))

        // Restore from the Archive: back in the listing (Boxes are put back by Undo, below).
        store.replaceRemoved(store.removed.subtracting(store.removed(in: archive)))
        XCTAssertEqual(try listed(a), ["A1.jpg", "A2.jpg", "A3.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemovedFile.url(inCatalog: catalogue).path), "an empty list leaves no file")
        XCTAssertEqual(try disk(), before)
    }

    func testUndoPutsTheBoxesAndTheListingBack() throws {
        let a = try photos("A", ["A1.jpg", "A2.jpg"])
        let store = ProjectStore(directory: catalogue)
        let a1 = a.appendingPathComponent("A1.jpg")
        let box = try XCTUnwrap(store.createBox(named: "Rue", frames: [a1]))
        let snapshot = store.snapshot
        var told = 0
        store.removedChanged = { told += 1; XCTAssertEqual($0, [a1.standardizedFileURL.path]) }
        store.removeFromLab([a1])
        XCTAssertEqual(told, 1)
        XCTAssertNotEqual(store.snapshot, snapshot)
        XCTAssertEqual(try listed(a), ["A2.jpg"])
        store.restore(snapshot)
        XCTAssertEqual(told, 2)
        XCTAssertEqual(try listed(a), ["A1.jpg", "A2.jpg"])
        XCTAssertEqual(store.frames(of: .box(box.id)), [a1.standardizedFileURL.path])
        XCTAssertTrue(store.removed.isEmpty)
    }

    func testANewerRemovedFileIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        let newer = #"{"qlick": {"schema": 9, "photos": ["/x.jpg"]}}"#
        try Data(newer.utf8).write(to: RemovedFile.url(inCatalog: catalogue))
        let store = ProjectStore(directory: catalogue)
        XCTAssertTrue(store.removed.isEmpty)
        store.replaceRemoved(["/y.jpg"])
        XCTAssertEqual(try String(contentsOf: RemovedFile.url(inCatalog: catalogue), encoding: .utf8), newer)
        XCTAssertTrue(store.removed.isEmpty, "not written, so not taken")
    }

    func testTheDialogOffersTheSafestFirst() {
        let plain = RemoveQuestion(photographs: 12, name: nil, holder: nil)
        XCTAssertEqual(plain.alert.title, "Remove 12 photographs?")
        XCTAssertEqual(plain.alert.buttons.map(\.title), ["Remove from Qlick Lab", "Delete from Disk…", "Cancel"])
        XCTAssertEqual(plain.choices, [.lab, .disk, .cancel])
        XCTAssertEqual(plain.alert.defaultIndex, 0)
        XCTAssertEqual(plain.alert.cancelIndex, 2)
        XCTAssertEqual(plain.alert.buttons[1].role, .destructive)
        XCTAssertTrue(plain.alert.choosing)

        let inBox = RemoveQuestion(photographs: 1, name: "L1004394.DNG", holder: ("Madrid", true), rejected: true)
        XCTAssertEqual(inBox.alert.title, "Remove the rejected photograph “L1004394.DNG”?")
        XCTAssertEqual(inBox.choices, [.holder, .lab, .disk, .cancel])
        XCTAssertEqual(inBox.alert.buttons[0].title, "Remove from “Madrid”")
        XCTAssertEqual(inBox.alert.buttons[0].detail, "Out of this Roll only. It stays in its Archive and in other Boxes.")
        XCTAssertEqual(inBox.choice(0), .holder)
        XCTAssertEqual(inBox.choice(9), .cancel)

        let copies = RemoveQuestion(photographs: 2, name: nil, duplicatesOnly: 2, holder: ("Rue", false))
        XCTAssertEqual(copies.choices, [.duplicates, .cancel], "a duplicate never takes its photograph with it")

        let confirm = RemoveQuestion.diskConfirmation(files: 12, duplicates: 0, following: 1, name: nil)
        XCTAssertEqual(confirm.title, "Delete 12 photographs from the disk?")
        XCTAssertEqual(confirm.warning, "This deletes 12 photographs from the disk. They go to the Trash.")
        XCTAssertEqual(confirm.buttons.map(\.title), ["Cancel", "Delete from Disk"])
        XCTAssertEqual(confirm.defaultIndex, 0, "Return is Cancel")
        XCTAssertEqual(confirm.cancelIndex, 0)
        XCTAssertFalse(confirm.choosing)
    }
}
