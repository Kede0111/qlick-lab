import XCTest
@testable import QlickLab

/// Locate Folder: a Folder found elsewhere takes every path the catalogue keeps under it along; nothing else moves.
@MainActor final class LocateFolderTests: XCTestCase {
    func testEveryPathUnderTheFolderFollowsIt() throws {
        let catalogue = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalogue) }
        let store = ProjectStore(directory: catalogue)
        let archive = store.create(named: "Italie")
        store.update(archive.id) {
            $0.rolls.append(LabRoll(name: "Capture", folder: "/Volumes/NAS/Italie/Capture"))
            $0.rolls.append(LabRoll(name: "Day 1", folder: "/Volumes/NAS/Italie/Capture/Day 1"))
            $0.rolls.append(LabRoll(name: "Other", folder: "/Volumes/NAS/Italie/Capture copy"))
        }
        let box = try XCTUnwrap(store.createBox(named: "Best", frames: [URL(fileURLWithPath: "/Volumes/NAS/Italie/Capture/a.RAF", isDirectory: false),
                                                                       URL(fileURLWithPath: "/Volumes/NAS/Italie/Capture copy/b.RAF", isDirectory: false)]))
        XCTAssertEqual(store.knownPhotographs(under: "/Volumes/NAS/Italie/Capture"), ["/Volumes/NAS/Italie/Capture/a.RAF"])
        store.relocate(from: "/Volumes/NAS/Italie/Capture", to: "/Volumes/Backup/Capture")
        let folders = try XCTUnwrap(store.archive(archive.id)).rolls.map(\.folder)
        XCTAssertEqual(folders, ["/Volumes/Backup/Capture", "/Volumes/Backup/Capture/Day 1", "/Volumes/NAS/Italie/Capture copy"])
        XCTAssertEqual(store.box(box.id)?.frames, ["/Volumes/Backup/Capture/a.RAF", "/Volumes/NAS/Italie/Capture copy/b.RAF"])
        // Written: another opening reads the same.
        let again = ProjectStore(directory: catalogue)
        XCTAssertEqual(again.archive(archive.id)?.rolls.first?.folder, "/Volumes/Backup/Capture")
        XCTAssertEqual(again.box(box.id)?.frames.first, "/Volumes/Backup/Capture/a.RAF")
    }

    func testAPathIsMovedOnlyUnderTheFolder() {
        XCTAssertEqual(ProjectStore.moved("/A/B/c.DNG", from: "/A/B", to: "/X"), "/X/c.DNG")
        XCTAssertEqual(ProjectStore.moved("/A/B", from: "/A/B", to: "/X"), "/X")
        XCTAssertEqual(ProjectStore.moved("/A/BC/c.DNG", from: "/A/B", to: "/X"), "/A/BC/c.DNG")
    }
}
