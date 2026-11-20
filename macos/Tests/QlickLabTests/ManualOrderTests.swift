// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// 0.4's finishing touches: photographs put in order by hand in a Box or a Roll, burst stacks, and the sort that
/// belongs to Boxes.
@MainActor final class ManualOrderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private var catalogue: URL { root.appendingPathComponent("catalogue.qlicklab", isDirectory: true) }
    private func photo(_ name: String) -> URL { root.appendingPathComponent("photos/\(name)") }

    func testPhotographsDroppedGoWhereTheLineShows() {
        let list = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(ManualOrder.reordered(list, shown: list, moving: ["a"], slot: 3), ["b", "c", "a", "d", "e"])
        XCTAssertEqual(ManualOrder.reordered(list, shown: list, moving: ["d", "b"], slot: 0), ["b", "d", "a", "c", "e"], "they keep their order")
        XCTAssertEqual(ManualOrder.reordered(list, shown: list, moving: ["a"], slot: 5), ["b", "c", "d", "e", "a"], "to the end")
        // A filter shows some only: the others keep their places around them.
        XCTAssertEqual(ManualOrder.reordered(list, shown: ["a", "c", "e"], moving: ["e"], slot: 1), ["a", "b", "e", "c", "d"])
        // Shown the other way round, before in the view is after in the order.
        XCTAssertEqual(ManualOrder.reordered(list, shown: list.reversed(), moving: ["a"], slot: 1, ascending: false), ["b", "c", "d", "a", "e"], "between e and d in the view")
        XCTAssertEqual(ManualOrder.reordered(list, shown: list, moving: ["z"], slot: 1), list, "nothing of the list, nothing moves")
    }

    func testTheSlotIsBeforeOrAfterTheNearestPhotograph() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 80), CGRect(x: 110, y: 0, width: 100, height: 80), CGRect(x: 0, y: 90, width: 100, height: 80)]
        XCTAssertEqual(ManualOrder.slot(frames, at: CGPoint(x: 20, y: 40)), 0)
        XCTAssertEqual(ManualOrder.slot(frames, at: CGPoint(x: 180, y: 40)), 2)
        XCTAssertEqual(ManualOrder.slot(frames, at: CGPoint(x: 300, y: 40)), 2, "past the end of a row: after its last")
        XCTAssertEqual(ManualOrder.slot(frames, at: CGPoint(x: 90, y: 120)), 3)
        XCTAssertEqual(ManualOrder.bar(frames, slot: 1, gap: 10)?.midX, 105)
        XCTAssertEqual(ManualOrder.bar(frames, slot: 3, gap: 10)?.midX, 105)
    }

    func testOneSpellingOfAPath() {
        XCTAssertEqual(ManualOrder.canonical("/private/tmp/a/L1.DNG"), "/tmp/a/L1.DNG")
        XCTAssertEqual(ManualOrder.canonical("/Volumes/private/tmp"), "/Volumes/private/tmp")
        XCTAssertEqual(ManualOrder.ordered(["a", "b", "c", "d"], by: ["c", "a"]), ["c", "a", "b", "d"], "those not ordered follow, as they come")
    }

    func testAnOrderByHandIsKeptInTheCatalogue() throws {
        let store = ProjectStore(directory: catalogue)
        let box = try XCTUnwrap(store.createBox(named: "Trip", frames: ["a", "b", "c"].map(photo)))
        let roll = try XCTUnwrap(store.createRoll(named: "Day 1", in: box.id, frames: ["d", "e"].map(photo)))
        let paths = store.frames(of: .box(box.id))
        store.setOrder([paths[3], paths[0], paths[4], paths[1], paths[2]], of: .box(box.id))
        store.setOrder(store.frames(of: .roll(roll.id, box: box.id)).reversed(), of: .roll(roll.id, box: box.id))
        let again = ProjectStore(directory: catalogue)
        XCTAssertEqual(again.frames(of: .box(box.id)).map { ($0 as NSString).lastPathComponent }, ["d", "a", "e", "b", "c"],
                       "the Box's order holds what's in its Rolls, as it shows them")
        XCTAssertEqual(again.frames(of: .roll(roll.id, box: box.id)).map { ($0 as NSString).lastPathComponent }, ["e", "d"])
        XCTAssertEqual(LibrarySort.Key.offered(manual: false).contains(.custom), false, "Custom Order is a Box's or a Roll's")
        XCTAssertTrue(LibrarySort.Key.offered(manual: true).contains(.custom))
    }

    func testAClosedStackShowsItsTopAlone() {
        let stacks = [PhotoStack(frames: ["/p/b", "/p/a", "/p/c"]), PhotoStack(frames: ["/p/x", "/p/y"], open: true)]
        XCTAssertEqual(Stacking.collapsed(["/p/a", "/p/b", "/p/c", "/p/d", "/p/x", "/p/y"], stacks: stacks), ["/p/b", "/p/d", "/p/x", "/p/y"])
        XCTAssertEqual(Stacking.collapsed(["/p/a", "/p/c"], stacks: stacks), ["/p/a"], "its top filtered out, the first of it there stands for it")
        XCTAssertEqual(Stacking.collapsed(["/private/p/b"], stacks: stacks), ["/private/p/b"])
    }

    func testBurstsAreFramesUnderTwoSecondsApartFromOneCamera() {
        let runs = Stacking.bursts([("a", 0, "M11"), ("b", 1.5, "M11"), ("c", 2.9, "M11"), ("d", 10, "M11"), ("e", 10.5, "Q3"), ("f", nil, "M11"), ("g", 30, nil), ("h", 30.4, nil)])
        XCTAssertEqual(runs, [["a", "b", "c"], ["g", "h"]])
    }

    func testStacksAreKeptAndUndone() throws {
        let store = ProjectStore(directory: catalogue)
        let before = store.snapshot
        let stack = try XCTUnwrap(store.makeStack(["a", "b", "c"].map(photo)))
        XCTAssertNil(store.makeStack([photo("z")]), "one photograph is no stack")
        XCTAssertEqual(store.stackBadge(photo("a"))?.count, 3)
        XCTAssertEqual(store.stack(holding: photo("b").standardizedFileURL.path)?.id, stack.id)
        // Stacking one of them again takes it out of the first stack.
        store.makeStack(["c", "d"].map(photo))
        XCTAssertEqual(store.stack(holding: photo("a").standardizedFileURL.path)?.frames.count, 2)
        store.setStacksOpen(true, holding: [photo("a")])
        XCTAssertNil(store.stackBadge(photo("b")), "open, only its top is badged")
        XCTAssertEqual(ProjectStore(directory: catalogue).stacks.count, 2, "kept in stacks.json")
        XCTAssertTrue(ProjectStore(directory: catalogue).projects.isEmpty, "stacks.json isn't an Archive")
        store.unstack([photo("d")])
        XCTAssertEqual(store.stacks.count, 1)
        store.restore(before)
        XCTAssertTrue(store.stacks.isEmpty)
    }
}
