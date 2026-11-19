import XCTest
@testable import QlickLab

/// The Binder reads the folders that hold photographs, or lead to some, and follows the disk.
@MainActor final class BinderTests: XCTestCase {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-binder-\(UUID().uuidString)").appendingPathComponent("Film")
        let fm = FileManager.default
        for folder in ["2026/Coast/Roll 01", "2026/Coast/Roll 02", "2026/Nothing here", ".hidden/Roll", "Old.qlicklab/Views"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["2026/Coast/Roll 01/A.DNG", "2026/Coast/Roll 01/B.DNG", "2026/Coast/Roll 02/C.jpg", "2026/Coast/Roll 02/C.jpg.qlick",
                     ".hidden/Roll/D.DNG", "2026/Nothing here/notes.txt", "loose.tif"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        addTeardownBlock { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testReadsTheFoldersThatLeadToPhotographs() throws {
        let root = try tree()
        let read = try XCTUnwrap(Binder.read(root))
        XCTAssertEqual(read.photos, 1, "loose.tif")
        XCTAssertEqual(read.all.map(\.name), ["Film", "2026", "Coast", "Roll 01", "Roll 02"], "no hidden folder, no package, no folder without photographs")
        XCTAssertEqual(read.all.map(\.photos), [1, 0, 0, 2, 1])
        XCTAssertNil(Binder.read(root.appendingPathComponent("gone")))
    }

    func testRootsAreChosenOnceAndFollowTheDisk() async throws {
        let root = try tree()
        let suite = "qlick-binder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The import's old Recent list seeds the roots, the outermost of them.
        defaults.set([root.appendingPathComponent("2026/Coast/Roll 01").path, root.path], forKey: "qlick.importRecent")
        let binder = Binder(defaults: defaults)
        XCTAssertEqual(binder.roots.map(\.path), [root.standardizedFileURL.path])
        XCTAssertNil(defaults.object(forKey: "qlick.importRecent"))
        XCTAssertEqual(Binder(defaults: defaults).roots, binder.roots, "kept")

        binder.add(root.appendingPathComponent("2026"))
        XCTAssertEqual(binder.roots.count, 1, "a folder already in the Binder isn't added twice")

        binder.start()
        defer { binder.remove(binder.roots[0]) }
        for _ in 0..<60 where binder.trees.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(binder.trees.values.first?.all.count, 5)
        // A new roll copied in shows by itself.
        let added = root.appendingPathComponent("2026/Coast/Roll 03")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data().write(to: added.appendingPathComponent("E.DNG"))
        for _ in 0..<100 where binder.trees.values.first?.all.count != 6 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(binder.trees.values.first?.all.map(\.name).last, "Roll 03")

        binder.remove(binder.roots[0])
        XCTAssertTrue(binder.roots.isEmpty)
        XCTAssertTrue(binder.trees.isEmpty)
        binder.add(root)
    }
}
