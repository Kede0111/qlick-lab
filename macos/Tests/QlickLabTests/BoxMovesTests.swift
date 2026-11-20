import XCTest
@testable import QlickLab

/// 0.4's R2: what a drop in the sidebar does (said before it's done), drag and drop, copy and paste between Boxes and
/// Rolls, each one undo step; nothing ever moves on the disk.
@MainActor final class BoxMovesTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-boxmoves-\(UUID().uuidString)", isDirectory: true)
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

    private func names(_ paths: [String]) -> [String] { paths.map { ($0 as NSString).lastPathComponent } }

    /// The Boxes as names and photographs (the file keeps dates to the second).
    private func shape(_ boxes: [LabBox]?) -> String {
        (boxes ?? []).map { box in
            "[\(box.name): \(names(box.frames).joined(separator: ",")) \(shape(box.boxes)) \(box.rolls.map { "(\($0.name): \(names($0.frames).joined(separator: ",")))" }.joined())]"
        }.joined()
    }

    private func disk() throws -> [String] {
        let walk = FileManager.default.enumerator(atPath: root.appendingPathComponent("photos").path)
        return (walk?.allObjects as? [String] ?? []).sorted()
    }

    func testPhotographsFromAnArchiveAreAddedOnceWithTheCopyWording() throws {
        let a = try photos("A", ["A1.DNG", "A2.DNG", "A3.DNG"])
        let store = ProjectStore(directory: catalogue)
        let rue = try XCTUnwrap(store.createBox(named: "Rue", frames: [a.appendingPathComponent("A1.DNG")]))
        let urls = ["A1.DNG", "A2.DNG", "A3.DNG"].map { a.appendingPathComponent($0) }

        let plan = try XCTUnwrap(store.plan(.photos(urls, from: nil), onto: .box(rue.id), at: 0.5, copying: false))
        XCTAssertEqual(plan.operation, .copy, "from an Archive, always added")
        XCTAssertEqual(plan.label, "Copy 2 photographs to “Rue” (1 already in it)")
        XCTAssertTrue(store.apply(try XCTUnwrap(plan.action)))
        XCTAssertEqual(names(store.frames(of: .box(rue.id))), ["A1.DNG", "A2.DNG", "A3.DNG"], "no duplicates")

        let again = try XCTUnwrap(store.plan(.photos(urls, from: nil), onto: .box(rue.id), at: 0.5, copying: false))
        XCTAssertEqual(again.operation, .refused)
        XCTAssertEqual(again.label, "All already in “Rue”")
        XCTAssertNil(again.action)
    }

    func testFromOneBoxToAnotherMovesAndWithOptionCopies() throws {
        let a = try photos("A", ["A1.DNG", "A2.DNG", "A3.DNG"])
        let store = ProjectStore(directory: catalogue)
        let urls = ["A1.DNG", "A2.DNG"].map { a.appendingPathComponent($0) }
        let spain = try XCTUnwrap(store.createBox(named: "Spain"))
        let day = try XCTUnwrap(store.createRoll(named: "Day 1", in: spain.id, frames: urls + [a.appendingPathComponent("A3.DNG")]))
        let rue = try XCTUnwrap(store.createBox(named: "Rue"))
        let source = Holder.roll(day.id, box: spain.id)

        let move = try XCTUnwrap(store.plan(.photos(urls, from: source), onto: .box(rue.id), at: 0.5, copying: false))
        XCTAssertEqual(move.operation, .move)
        XCTAssertEqual(move.label, "Move 2 photographs to “Rue”")
        let copy = try XCTUnwrap(store.plan(.photos(urls, from: source), onto: .box(rue.id), at: 0.5, copying: true))
        XCTAssertEqual(copy.operation, .copy, "⌥ copies")
        XCTAssertEqual(copy.label, "Copy 2 photographs to “Rue”")
        XCTAssertEqual(store.plan(.photos(urls, from: source), onto: .roll(day.id, box: spain.id), at: 0.5, copying: false)?.operation, .refused,
                       "onto the Roll they come from: nothing to do")

        store.apply(try XCTUnwrap(copy.action))
        XCTAssertEqual(names(store.frames(of: .box(rue.id))), ["A1.DNG", "A2.DNG"])
        XCTAssertEqual(names(store.frames(of: source)), ["A1.DNG", "A2.DNG", "A3.DNG"], "copied: in both")

        let other = try XCTUnwrap(store.createBox(named: "Other"))
        store.apply(try XCTUnwrap(store.plan(.photos(urls, from: source), onto: .box(other.id), at: 0.5, copying: false)?.action))
        XCTAssertEqual(names(store.frames(of: .box(other.id))), ["A1.DNG", "A2.DNG"])
        XCTAssertEqual(names(store.frames(of: source)), ["A3.DNG"], "moved: out of the first")
        XCTAssertEqual(try disk(), ["A", "A/A1.DNG", "A/A2.DNG", "A/A3.DNG"], "nothing moves on the disk")
    }

    func testMovingIntoARollInsideTheSourceBoxKeepsThem() throws {
        let a = try photos("A", ["A1.DNG", "A2.DNG"])
        let store = ProjectStore(directory: catalogue)
        let urls = ["A1.DNG", "A2.DNG"].map { a.appendingPathComponent($0) }
        let spain = try XCTUnwrap(store.createBox(named: "Spain", frames: urls))
        let madrid = try XCTUnwrap(store.createRoll(named: "Madrid", in: spain.id))
        store.moveFrames([urls[0]], from: .box(spain.id), to: .roll(madrid.id, box: spain.id))
        XCTAssertEqual(names(store.box(spain.id)?.frames ?? []), ["A2.DNG"])
        XCTAssertEqual(names(store.frames(of: .roll(madrid.id, box: spain.id))), ["A1.DNG"], "the Roll it went to keeps it")
        XCTAssertEqual(names(store.frames(of: .box(spain.id))), ["A2.DNG", "A1.DNG"], "the Box still shows it, inside")
    }

    func testArchivesAndFoldersRefusePhotographs() throws {
        let a = try photos("A", ["A1.DNG"])
        let store = ProjectStore(directory: catalogue)
        let archive = store.create(named: "Leica M11")
        store.addRolls([a], to: archive.id)
        let item = LabDragItem.photos([a.appendingPathComponent("A1.DNG")], from: nil)
        for target in [SidebarTarget.archive(archive.id), .folder(a.standardizedFileURL.path, archive: archive.id)] {
            let plan = try XCTUnwrap(store.plan(item, onto: target, at: 0.5, copying: false))
            XCTAssertEqual(plan.operation, .refused)
            XCTAssertNil(plan.action)
            XCTAssertTrue(plan.label.contains("disk is shown as it is"), plan.label)
        }
    }

    func testAFolderDroppedOnABoxMakesARollOfItsPhotographs() throws {
        let spainFolder = try photos("Spain", [])
        try photos("Spain/Madrid", ["M1.DNG", "M2.DNG"])
        try photos("Spain/Madrid/Night", ["N1.DNG"])
        let store = ProjectStore(directory: catalogue)
        let archive = store.create(named: "Trip")
        store.addRolls([spainFolder], to: archive.id)
        let box = try XCTUnwrap(store.createBox(named: "Portfolio"))
        let madrid = spainFolder.appendingPathComponent("Madrid").standardizedFileURL.path

        let plan = try XCTUnwrap(store.plan(.folder(madrid, archive: archive.id), onto: .box(box.id), at: 0.5, copying: false))
        XCTAssertEqual(plan.operation, .copy)
        XCTAssertTrue(plan.label.hasPrefix("New Roll “Madrid” in “Portfolio”"), plan.label)
        XCTAssertTrue(store.apply(try XCTUnwrap(plan.action)))
        let roll = try XCTUnwrap(store.box(box.id)?.rolls.first)
        XCTAssertEqual(roll.name, "Madrid")
        XCTAssertEqual(names(roll.frames).sorted(), ["M1.DNG", "M2.DNG", "N1.DNG"], "with the folders under it")
        XCTAssertEqual(try disk().count, 6, "nothing on disk")

        // A folder on a folder: the disk is shown as it is.
        XCTAssertEqual(store.plan(.folder(madrid, archive: archive.id), onto: .folder(spainFolder.standardizedFileURL.path, archive: archive.id), at: 0.5, copying: false)?.operation, .refused)
    }

    func testOpeningAFolderWhosePhotographsAreAllBelowListsThem() throws {
        let spainFolder = try photos("Spain", [])
        try photos("Spain/Madrid", ["M1.DNG"])
        let store = ProjectStore(directory: catalogue)
        let archive = store.create(named: "Trip")
        store.addRolls([spainFolder], to: archive.id)
        // The tree isn't read (the tests don't start the watcher): the disk is asked.
        let list = store.viewFolder(for: .folder(spainFolder.standardizedFileURL.path, archive: archive.id))
        XCTAssertEqual(try PhotoFolder.listing(in: list).photos.map(\.name), ["M1.DNG"])
    }

    func testABoxNeverGoesInsideItselfAndBoxesAndRollsMoveAndReorder() throws {
        let store = ProjectStore(directory: catalogue)
        let spain = try XCTUnwrap(store.createBox(named: "Spain"))
        let madrid = try XCTUnwrap(store.createBox(named: "Madrid", in: spain.id))
        let night = try XCTUnwrap(store.createBox(named: "Night", in: madrid.id))
        let rue = try XCTUnwrap(store.createBox(named: "Rue"))
        let roll = try XCTUnwrap(store.createRoll(named: "Day 1", in: rue.id))
        let roll2 = try XCTUnwrap(store.createRoll(named: "Day 2", in: rue.id))

        // No cycles.
        XCTAssertEqual(store.plan(.box(spain.id), onto: .box(night.id), at: 0.5, copying: false)?.operation, .refused)
        XCTAssertEqual(store.plan(.box(spain.id), onto: .box(spain.id), at: 0.5, copying: false)?.operation, .refused)
        XCTAssertFalse(store.moveBox(spain.id, into: night.id, at: 0))
        XCTAssertEqual(store.boxPath(night.id)?.map(\.name), ["Spain", "Madrid", "Night"])

        // Nesting.
        let nest = try XCTUnwrap(store.plan(.box(rue.id), onto: .box(madrid.id), at: 0.5, copying: false))
        XCTAssertEqual(nest.operation, .move)
        XCTAssertEqual(nest.label, "Move “Rue” into “Madrid”")
        store.apply(try XCTUnwrap(nest.action))
        XCTAssertEqual(store.boxPath(rue.id)?.map(\.name), ["Spain", "Madrid", "Rue"])
        XCTAssertEqual(store.box(rue.id)?.rolls.map(\.name), ["Day 1", "Day 2"], "with what's inside it")

        // Back on top, before Spain: a line before the row.
        let place = try XCTUnwrap(store.plan(.box(rue.id), onto: .box(spain.id), at: 0.1, copying: false))
        XCTAssertEqual(place.line, .before)
        XCTAssertEqual(place.label, "Place “Rue” before “Spain”")
        store.apply(try XCTUnwrap(place.action))
        XCTAssertEqual(store.boxes.map(\.name), ["Rue", "Spain"])
        XCTAssertNil(store.plan(.box(rue.id), onto: .box(spain.id), at: 0.1, copying: false), "already there: nothing to say")

        // Rolls: reorder in their Box, move to another.
        let reorder = try XCTUnwrap(store.plan(.roll(roll2.id, box: rue.id), onto: .roll(roll.id, box: rue.id), at: 0.2, copying: false))
        store.apply(try XCTUnwrap(reorder.action))
        XCTAssertEqual(store.box(rue.id)?.rolls.map(\.name), ["Day 2", "Day 1"])
        store.apply(try XCTUnwrap(store.plan(.roll(roll.id, box: rue.id), onto: .box(night.id), at: 0.5, copying: false)?.action))
        XCTAssertEqual(store.box(night.id)?.rolls.map(\.name), ["Day 1"])
        XCTAssertEqual(store.box(holdingRoll: roll.id), night.id)

        // Written as it is.
        XCTAssertEqual(shape(BoxesFile.read(inCatalog: catalogue)), shape(store.boxes))
    }

    func testArchivesKeepTheOrderTheyreDraggedTo() throws {
        let store = ProjectStore(directory: catalogue)
        let first = store.create(named: "First"), second = store.create(named: "Second"), third = store.create(named: "Third")
        let plan = try XCTUnwrap(store.plan(.archive(third.id), onto: .archive(first.id), at: 0.3, copying: false))
        XCTAssertEqual(plan.label, "Place “Third” before “First”")
        store.apply(try XCTUnwrap(plan.action))
        XCTAssertEqual(store.projects.map(\.name), ["Third", "First", "Second"])
        XCTAssertEqual(ProjectStore(directory: catalogue).projects.map(\.name), ["Third", "First", "Second"], "kept in the catalogue")
        store.apply(.placeArchive(third.id, at: 3))
        XCTAssertEqual(store.projects.map(\.name), ["First", "Second", "Third"])
        _ = second
    }

    func testAFolderDroppedOnAnotherArchiveJoinsIt() throws {
        let a = try photos("A", ["A1.DNG"])
        let store = ProjectStore(directory: catalogue)
        let one = store.create(named: "One"), two = store.create(named: "Two")
        store.addRolls([a], to: one.id)
        let path = a.standardizedFileURL.path
        let plan = try XCTUnwrap(store.plan(.folder(path, archive: one.id), onto: .archive(two.id), at: 0.5, copying: false))
        XCTAssertEqual(plan.operation, .move)
        store.apply(try XCTUnwrap(plan.action))
        XCTAssertEqual(store.archive(two.id)?.rolls.map(\.folder), [path])
        XCTAssertEqual(store.archive(one.id)?.rolls.count, 0)
        XCTAssertEqual(try disk(), ["A", "A/A1.DNG"])
    }

    func testEveryGestureIsOneUndoStepAndPasteAdds() throws {
        let a = try photos("A", ["A1.DNG", "A2.DNG"])
        let model = EditorModel()
        let lab = model.lab
        lab.projects.open(directory: catalogue)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let urls = ["A1.DNG", "A2.DNG"].map { a.appendingPathComponent($0) }
        let spain = try XCTUnwrap(lab.projects.createBox(named: "Spain", frames: urls))
        let rue = try XCTUnwrap(lab.projects.createBox(named: "Rue"))

        // A drop: one step back, one step forward.
        let plan = try XCTUnwrap(lab.projects.plan(.photos(urls, from: .box(spain.id)), onto: .box(rue.id), at: 0.5, copying: false))
        undo.beginUndoGrouping(); lab.perform(plan); undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Move 2 Photographs")
        XCTAssertEqual(names(lab.projects.frames(of: .box(rue.id))), ["A1.DNG", "A2.DNG"])
        XCTAssertTrue(lab.projects.frames(of: .box(spain.id)).isEmpty)
        undo.undo()
        XCTAssertEqual(names(lab.projects.frames(of: .box(spain.id))), ["A1.DNG", "A2.DNG"])
        XCTAssertTrue(lab.projects.frames(of: .box(rue.id)).isEmpty)
        XCTAssertEqual(shape(BoxesFile.read(inCatalog: catalogue)), shape(lab.projects.boxes), "the undo is written too")
        undo.redo()
        XCTAssertEqual(names(lab.projects.frames(of: .box(rue.id))), ["A1.DNG", "A2.DNG"])
        undo.undo()

        // Paste adds, never moves.
        lab.copiedPhotos = [urls[0]]
        undo.beginUndoGrouping(); lab.pastePhotos(into: .box(rue.id)); undo.endUndoGrouping()
        XCTAssertEqual(names(lab.projects.frames(of: .box(rue.id))), ["A1.DNG"])
        XCTAssertEqual(names(lab.projects.frames(of: .box(spain.id))), ["A1.DNG", "A2.DNG"], "still where it was")
        XCTAssertEqual(undo.undoActionName, "Paste Photograph")
        undo.undo()
        XCTAssertTrue(lab.projects.frames(of: .box(rue.id)).isEmpty)

        // Reordering and nesting are steps too.
        undo.beginUndoGrouping(); lab.perform(try XCTUnwrap(lab.projects.plan(.box(rue.id), onto: .box(spain.id), at: 0.5, copying: false))); undo.endUndoGrouping()
        XCTAssertEqual(lab.projects.boxPath(rue.id)?.map(\.name), ["Spain", "Rue"])
        undo.undo()
        XCTAssertEqual(lab.projects.boxes.map(\.name), ["Spain", "Rue"])
        XCTAssertEqual(try disk(), ["A", "A/A1.DNG", "A/A2.DNG"])
    }
}
