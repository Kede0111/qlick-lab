import XCTest
@testable import QlickLab

/// An Archive's Folders are read as the disk has them, every folder at every depth, and followed as it changes.
@MainActor final class FolderTreesTests: XCTestCase {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-trees-\(UUID().uuidString)").appendingPathComponent("Film")
        let fm = FileManager.default
        for folder in ["2026/Coast/Roll 01/a/b/c/d", "2026/Coast/Roll 02", "2026/Nothing here", ".hidden/Roll", "Old.app/Contents"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["2026/Coast/Roll 01/A.DNG", "2026/Coast/Roll 01/B.DNG", "2026/Coast/Roll 01/a/b/c/d/Deep.DNG", "2026/Coast/Roll 02/C.jpg",
                     "2026/Coast/Roll 02/C.jpg.qlick", ".hidden/Roll/D.DNG", "2026/Nothing here/notes.txt", "loose.tif"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        addTeardownBlock { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testReadsEveryFolderAtEveryDepth() throws {
        let root = try tree()
        let read = try XCTUnwrap(FolderTrees.read(root))
        XCTAssertEqual(read.photos, 1, "loose.tif")
        XCTAssertEqual(read.all.map(\.name), ["Film", "2026", "Coast", "Roll 01", "a", "b", "c", "d", "Roll 02", "Nothing here"],
                       "every folder, however deep, none hidden, no package")
        XCTAssertEqual(read.all.map(\.photos), [1, 0, 0, 2, 0, 0, 0, 1, 1, 0])
        XCTAssertEqual(read.total, 5)
        XCTAssertEqual(read.all.first { $0.name == "Roll 01" }?.total, 3, "with the folders under it")
        XCTAssertTrue(read.all.first { $0.name == "Roll 01" }!.photosBelow)
        XCTAssertFalse(read.all.first { $0.name == "Roll 02" }!.photosBelow)
        XCTAssertNil(FolderTrees.read(root.appendingPathComponent("gone")))
    }

    func testTheTreesFollowTheDisk() async throws {
        let root = try tree()
        let trees = FolderTrees()
        trees.follow([root])
        XCTAssertTrue(trees.trees.isEmpty, "nothing read before the start")
        trees.start()
        defer { trees.follow([]) }
        for _ in 0..<60 where trees.trees.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(trees.trees[root.standardizedFileURL.path]?.all.count, 10)
        // A folder copied in shows by itself.
        let added = root.appendingPathComponent("2026/Coast/Roll 03")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data().write(to: added.appendingPathComponent("E.DNG"))
        for _ in 0..<100 where trees.trees.values.first?.all.count != 11 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(trees.trees.values.first?.all.map(\.name).contains("Roll 03") == true)
        XCTAssertEqual(trees.trees.values.first?.total, 6)

        trees.follow([])
        XCTAssertTrue(trees.trees.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.appendingPathComponent("E.DNG").path), "read only")
    }
}
