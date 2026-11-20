import XCTest
@testable import QlickLab

/// 0.4's library: Archives hold their Folders as the disk has them; Boxes, inside Boxes to any depth, hold photographs
/// and Rolls; catalogues from before are converted once, nothing on disk moving.
@MainActor final class ArchiveBoxTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-archives-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private var catalogue: URL { root.appendingPathComponent("catalogue.qlicklab", isDirectory: true) }

    @discardableResult private func photos(_ folder: String, _ names: [String]) throws -> URL {
        let url = root.appendingPathComponent("photos/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data().write(to: url.appendingPathComponent(name)) }
        return url
    }

    private func write(_ json: String, _ id: UUID) throws {
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: catalogue.appendingPathComponent(id.uuidString + ".json"))
    }

    func testACatalogueFromBeforeIsConvertedOnceAndNothingOnDiskMoves() throws {
        let card = try photos("Card", ["L1.DNG", "L2.DNG"])
        let arrivals = UUID(), portfolio = UUID(), trip = UUID()
        try write(#"{"schema":1,"id":"\#(arrivals.uuidString)","name":"Arrivals","notes":"","createdAt":"2026-01-01T00:00:00Z","rolls":[{"id":"\#(UUID().uuidString)","name":"Card","folder":"\#(card.path)","film":"","camera":"","notes":"","addedAt":"2026-01-01T00:00:00Z"}],"archived":false,"kind":"arrivals"}"#, arrivals)
        try write(#"{"schema":1,"id":"\#(trip.uuidString)","name":"Trip","notes":"","createdAt":"2026-01-02T00:00:00Z","rolls":[],"archived":false}"#, trip)
        try write(#"{"schema":1,"id":"\#(portfolio.uuidString)","name":"Portfolio","notes":"","createdAt":"2026-01-03T00:00:00Z","rolls":[],"archived":false,"kind":"selection","frames":["\#(card.path)/L2.DNG"]}"#, portfolio)

        let store = ProjectStore(directory: catalogue)
        XCTAssertEqual(store.projects.map(\.name), ["To Sort", "Trip"], "Arrivals is the Archive To Sort; a selection is no Archive")
        XCTAssertEqual(store.archive(arrivals)?.rolls.map(\.folder), [card.path])
        XCTAssertEqual(store.boxes.map(\.name), ["Portfolio"], "each selection a Box on top, of the same name")
        XCTAssertEqual(store.boxes.first?.id, portfolio)
        XCTAssertEqual(store.boxes.first?.frames, [card.appendingPathComponent("L2.DNG").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogue.appendingPathComponent(portfolio.uuidString + ".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogue.appendingPathComponent(BoxesFile.fileName).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: card.path).sorted(), ["L1.DNG", "L2.DNG"], "nothing on disk moves")

        // Once: read again, the same.
        let again = ProjectStore(directory: catalogue)
        XCTAssertEqual(again.projects.map(\.name), ["To Sort", "Trip"])
        XCTAssertEqual(again.boxes.map(\.name), ["Portfolio"])
        XCTAssertTrue(again.projects.allSatisfy { $0.kind == nil })
        // The converted Archive is written in the new schema; an untouched one keeps its file as it was.
        let data = try Data(contentsOf: catalogue.appendingPathComponent(arrivals.uuidString + ".json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schema"] as? Int, LabProject.schema)
    }

    func testAnEmptyArrivalsGoesAway() throws {
        let id = UUID()
        try write(#"{"schema":1,"id":"\#(id.uuidString)","name":"Arrivals","notes":"","createdAt":"2026-01-01T00:00:00Z","rolls":[],"archived":false,"kind":"arrivals"}"#, id)
        XCTAssertTrue(ProjectStore(directory: catalogue).projects.isEmpty)
    }

    func testBoxesNestToAnyDepthAndShowEverythingUnderThem() throws {
        let a = try photos("A", ["A1.DNG", "A2.DNG", "A3.DNG"]), b = try photos("B", ["B1.DNG"])
        let store = ProjectStore(directory: catalogue)
        let spain = try XCTUnwrap(store.createBox(named: "Spain", frames: [a.appendingPathComponent("A1.DNG")]))
        let madrid = try XCTUnwrap(store.createBox(named: "Madrid", in: spain.id, frames: [b.appendingPathComponent("B1.DNG")]))
        let night = try XCTUnwrap(store.createBox(named: "Night", in: madrid.id))
        let day = try XCTUnwrap(store.createRoll(named: "Day 1", in: night.id, frames: [a.appendingPathComponent("A3.DNG"), a.appendingPathComponent("A1.DNG")]))
        XCTAssertEqual(store.boxes.map(\.name), ["Spain"], "Madrid is inside Spain")
        XCTAssertEqual(store.boxPath(night.id)?.map(\.name), ["Spain", "Madrid", "Night"])
        XCTAssertEqual(store.name(of: .roll(day.id, box: night.id)), "Spain › Madrid › Night › Day 1")
        XCTAssertEqual(store.allBoxes.count, 3)

        // Opening a Box lists its own photographs (R8: those under it are on its shelf); it holds everything under it.
        let list = store.viewFolder(for: .box(spain.id))
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["A1.DNG"])
        XCTAssertEqual(store.frames(of: .box(spain.id)).map { ($0 as NSString).lastPathComponent }, ["A1.DNG", "B1.DNG", "A3.DNG"])
        XCTAssertEqual(try PhotoFolder.listing(in: store.viewFolder(for: .roll(day.id, box: night.id))).photos.map(\.name), ["A3.DNG", "A1.DNG"])
        XCTAssertEqual(store.view(of: store.viewFolder(for: .roll(day.id, box: night.id))), .roll(day.id, box: night.id))

        // Taking a photograph out of a Box takes it out of the Box itself (R8: the Rolls under it keep theirs); the file stays.
        store.removeFrames([a.appendingPathComponent("A1.DNG")], from: .box(spain.id))
        XCTAssertEqual(store.frames(of: .box(spain.id)), [b.appendingPathComponent("B1.DNG").path, a.appendingPathComponent("A3.DNG").path,
                                                          a.appendingPathComponent("A1.DNG").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("A1.DNG").path))

        // Names are unique beside each other only.
        XCTAssertEqual(store.createBox(named: "Madrid")?.name, "Madrid", "on top, beside Spain")
        XCTAssertEqual(store.createBox(named: "Madrid", in: spain.id)?.name, "Madrid 2")
        store.renameBox(night.id, to: "Noche")
        store.renameRoll(day.id, in: night.id, to: "Día 1")

        // Kept, read back, and deleted with what's inside: the photographs stay.
        let again = ProjectStore(directory: catalogue)
        XCTAssertEqual(again.name(of: .roll(day.id, box: night.id)), "Spain › Madrid › Noche › Día 1")
        again.deleteBox(madrid.id)
        XCTAssertNil(again.box(night.id))
        XCTAssertNil(again.view(of: list.deletingLastPathComponent().appendingPathComponent(madrid.id.uuidString)))
        XCTAssertEqual(ProjectStore(directory: catalogue).allBoxes.map(\.name), ["Spain", "Madrid 2", "Madrid"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path).count, 3)
    }

    func testAnArchiveShowsItsFoldersAtEveryDepth() throws {
        let deep = try photos("Trip/2026/09/19", ["D1.DNG"])
        try photos("Trip/2026/09", ["M1.DNG"])
        try photos("Trip/Empty/Nothing", [])
        let trip = root.appendingPathComponent("photos/Trip", isDirectory: true)
        let store = ProjectStore(directory: catalogue)
        let archive = store.create(named: "Trip")
        store.addRolls([trip], to: archive.id)
        // A folder already under one of its Folders isn't one on top.
        store.addRolls([deep], to: archive.id)
        let found = try XCTUnwrap(store.archive(archive.id))
        XCTAssertEqual(store.roots(of: found).map(\.lastPathComponent), ["Trip"])

        store.folders.readNow()
        XCTAssertEqual(store.photoFolders(of: found).map(\.lastPathComponent), ["09", "19"])
        XCTAssertEqual(try PhotoFolder.listing(in: store.viewFolder(for: found)).photos.map(\.name), ["M1.DNG", "D1.DNG"])
        XCTAssertEqual(store.node(trip.appendingPathComponent("Empty").path)?.total, 0, "an empty folder is in the tree too")

        // A folder with folders under it opens as a list of them all; the lab knows where it is.
        let month = trip.appendingPathComponent("2026/09").path
        let list = store.viewFolder(for: .folder(month, archive: archive.id))
        XCTAssertEqual(store.view(of: list), .folder(month, archive: archive.id))
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["M1.DNG", "D1.DNG"])
        XCTAssertEqual(store.place(of: month)?.archive.id, archive.id)
        XCTAssertEqual(store.place(of: deep.path)?.entry.folder, deep.path, "the deepest Folder holding it")
        XCTAssertEqual(store.folder(month, in: found).name, "09", "the disk's name for a folder without a card")

        // A card on a folder under a Folder gives it an entry; the disk isn't touched otherwise.
        store.updateRoll(store.archive(archive.id)!.rolls[0].id, in: archive.id) { $0.film = "Portra 400" }
        XCTAssertEqual(store.folder(month, in: store.archive(archive.id)!).film, "Portra 400", "the film of the Folder holding it")
        let entry = try XCTUnwrap(store.folderEntry(month, in: archive.id))
        XCTAssertEqual(store.folderEntry(month, in: archive.id)?.id, entry.id, "made once")
        XCTAssertEqual(store.roots(of: store.archive(archive.id)!).map(\.lastPathComponent), ["Trip"])
    }

    func testANewerBoxesFileIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        let newer = #"{"qlick":{"schema":99,"boxes":[]}}"#
        try Data(newer.utf8).write(to: BoxesFile.url(inCatalog: catalogue))
        let store = ProjectStore(directory: catalogue)
        XCTAssertTrue(store.boxes.isEmpty)
        store.createBox(named: "New")
        XCTAssertEqual(try String(contentsOf: BoxesFile.url(inCatalog: catalogue), encoding: .utf8), newer, "never written over")
    }
}
