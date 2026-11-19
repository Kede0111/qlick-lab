import XCTest
@testable import QlickLab

/// A roll's card lives in its folder and goes where the folder goes.
@MainActor final class RollCardFileTests: XCTestCase {
    private func folder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-card-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return folder
    }

    func testWrittenReadAndUnknownKeysKept() throws {
        let roll = try folder("Roll 01")
        XCTAssertNil(RollCardFile.read(in: roll))
        let card = RollCardFile(name: "Coast", film: "Portra 400, pushed +1", camera: "Leica M6", notes: "Low sun")
        XCTAssertTrue(card.write(in: roll))
        XCTAssertEqual(RollCardFile.read(in: roll), card)

        // A key a newer version wrote stays.
        let url = RollCardFile.file(in: roll)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var qlick = try XCTUnwrap(root["qlick"] as? [String: Any])
        qlick["developer"] = "Rodinal 1+50"
        root["qlick"] = qlick
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        var changed = card
        changed.notes = "Low sun, wind"
        XCTAssertTrue(changed.write(in: roll))
        XCTAssertEqual(RollCardFile.read(in: roll), changed)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((after["qlick"] as? [String: Any])?["developer"] as? String, "Rodinal 1+50")

        // A newer card is left alone.
        try #"{"qlick":{"schema":2,"roll":{"film":"X"}}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(RollCardFile.read(in: roll))
        XCTAssertFalse(card.write(in: roll))
    }

    func testAFolderBringsItsCardIntoAProject() throws {
        let roll = try folder("Roll 02")
        try Data().write(to: roll.appendingPathComponent("L1000001.DNG"))
        RollCardFile(name: "Harbour", film: "HP5 at 1600", camera: "M6", notes: "").write(in: roll)
        let catalogue = roll.deletingLastPathComponent().appendingPathComponent("catalogue.qlicklab")
        let store = ProjectStore(directory: catalogue)
        let project = store.create(named: "Trip")
        let added = store.addRolls([roll], to: project.id)
        XCTAssertEqual(added.first?.name, "Harbour")
        XCTAssertEqual(added.first?.film, "HP5 at 1600")
    }

    func testEditingARollWritesItsCard() async throws {
        let roll = try folder("Roll 03")
        try Data().write(to: roll.appendingPathComponent("L1000001.DNG"))
        let catalogue = roll.deletingLastPathComponent().appendingPathComponent("catalogue.qlicklab")
        let store = ProjectStore(directory: catalogue)
        let project = store.create(named: "Trip")
        let id = try XCTUnwrap(store.addRolls([roll], to: project.id).first?.id)
        store.updateRoll(id, in: project.id) { $0.film = "Tri-X" }
        store.updateRoll(id, in: project.id) { $0.film = "Tri-X 400" }
        for _ in 0..<40 where RollCardFile.read(in: roll) == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(RollCardFile.read(in: roll)?.film, "Tri-X 400", "written once, after the last change")
    }
}
