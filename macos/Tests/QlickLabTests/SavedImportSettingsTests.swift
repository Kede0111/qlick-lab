import XCTest
@testable import QlickLab

/// The import's Saved Settings live in the catalogue, and move there from the preferences once.
@MainActor final class SavedImportSettingsTests: XCTestCase {
    func testKeptInTheCatalogueAndMovedFromThePreferences() throws {
        let catalogue = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-saved-\(UUID().uuidString).qlicklab")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-saved-\(UUID().uuidString).qlicklab")
        defer { try? FileManager.default.removeItem(at: catalogue); try? FileManager.default.removeItem(at: other) }
        let suite = "qlick-saved-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var card = ImportOptions()
        card.rename = "{job}-{seq}"
        card.keywords = "Leica, M11"
        defaults.set(try JSONEncoder().encode(["Card": card]), forKey: SavedImportSettings.oldKey)

        // The first catalogue read takes them, and the preferences forget them.
        XCTAssertEqual(SavedImportSettings.read(inCatalog: catalogue, defaults: defaults), ["Card": card])
        XCTAssertNil(defaults.data(forKey: SavedImportSettings.oldKey))
        let text = try String(contentsOf: SavedImportSettings.file(inCatalog: catalogue), encoding: .utf8)
        XCTAssertTrue(text.contains("\"qlick\""), "top-level key qlick")
        XCTAssertEqual(SavedImportSettings.read(inCatalog: catalogue, defaults: defaults), ["Card": card], "read again from the file")
        // Another catalogue starts with none.
        XCTAssertEqual(SavedImportSettings.read(inCatalog: other, defaults: defaults), [:])

        // The projects' list doesn't take the file for a project.
        let store = ProjectStore(directory: catalogue)
        XCTAssertTrue(store.projects.isEmpty)
        store.create(named: "Coast Trip")
        XCTAssertEqual(ProjectStore(directory: catalogue).projects.map(\.name), ["Coast Trip"])

        // A newer file is left alone.
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"qlick":{"schema":2,"importSettings":{}}}"#.write(to: SavedImportSettings.file(inCatalog: other), atomically: true, encoding: .utf8)
        XCTAssertEqual(SavedImportSettings.read(inCatalog: other, defaults: defaults), [:])
    }
}
