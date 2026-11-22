import AppKit
import XCTest
@testable import QlickLab

/// One catalogue at a time: opening another, or closing it (File › Close Catalog), leaves nothing of the one before
/// on screen or in memory; removing an Archive closes what was open of it; a photograph is reopened at launch only in
/// the catalogue it was open in.
@MainActor final class CatalogIsolationTests: XCTestCase {
    private var root: URL!
    private var savedDefaults: [String: Any?] = [:]
    private let keys = ["qlick.catalog", "qlick.recentCatalogs"]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-catalogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = savedDefaults[key] ?? nil { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        PhotoFolder.excluded = []
        EditorSession.unnamedNeedCatalog = false
        try? FileManager.default.removeItem(at: root)
    }

    private func catalogue(_ name: String) -> URL { root.appendingPathComponent("\(name).qlicklab", isDirectory: true) }

    private func photos(_ folder: String, count: Int) throws -> [URL] {
        let url = root.appendingPathComponent("photos/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try (1...count).map { index in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3,
                                                        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 36, bitsPerPixel: 24))
            let file = url.appendingPathComponent(String(format: "F%04d.png", index))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            return file
        }
    }

    func testTheStoreForgetsTheCatalogueBefore() throws {
        let frames = try photos("A", count: 3)
        let store = ProjectStore(directory: catalogue("One"))
        let archive = store.create(named: "Leica")
        store.addRolls([frames[0].deletingLastPathComponent()], to: archive.id)
        _ = try XCTUnwrap(store.createBox(named: "Spain", frames: [frames[0]]))
        store.removeFromLab([frames[2]])
        XCTAssertTrue(store.holds(frames[0]))
        XCTAssertFalse(store.holds(frames[2]), "removed from the lab: not its own")

        store.open(directory: catalogue("Two"))
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.boxes.isEmpty)
        XCTAssertTrue(store.removed.isEmpty)
        XCTAssertTrue(PhotoFolder.excluded.isEmpty, "the other catalogue's removed photographs aren't left out here")
        XCTAssertFalse(store.holds(frames[0]))

        store.close()
        XCTAssertFalse(store.isOpen)
        XCTAssertEqual(store.directory, ProjectStore.noCatalogDirectory)
        XCTAssertFalse(store.holds(frames[0]))

        store.open(directory: catalogue("One"))
        XCTAssertTrue(store.isOpen)
        XCTAssertEqual(store.projects.map(\.name), ["Leica"], "back as it was: nothing of it was lost")
        XCTAssertEqual(store.boxes.map(\.name), ["Spain"])
        XCTAssertTrue(store.holds(frames[0]))
    }

    func testOpeningAnotherCatalogueClosesEverythingOfTheFirst() throws {
        let frames = try photos("A", count: 3)
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        let lab = model.lab
        lab.openCatalog(catalogue("One"))
        let archive = lab.projects.create(named: "Leica")
        lab.projects.addRolls([frames[0].deletingLastPathComponent()], to: archive.id)
        lab.open(.all)
        let list = try XCTUnwrap(model.libraryRoot)
        XCTAssertTrue(PhotoFolder.isList(list))
        XCTAssertEqual(model.source?.lastPathComponent, "F0001.png")
        lab.loupe = frames[1]
        lab.copiedPhotos = [frames[2]]
        XCTAssertTrue(lab.places.count > 0)

        lab.openCatalog(catalogue("Two"))
        XCTAssertEqual(lab.catalogName, "Two")
        XCTAssertTrue(lab.projects.projects.isEmpty)
        XCTAssertNil(model.source, "the first catalogue's photograph closed")
        XCTAssertNil(model.libraryRoot, "and its contact sheet")
        XCTAssertTrue(model.library.files.isEmpty)
        XCTAssertFalse(PhotoFolder.isList(list), "its lists forgotten")
        XCTAssertNil(lab.loupe)
        XCTAssertTrue(lab.copiedPhotos.isEmpty)
        XCTAssertFalse(lab.canGoBack, "Back can't lead into the other catalogue")
        XCTAssertEqual(lab.workspace, .library)

        // Its All Photographs is its own: empty, it doesn't open.
        lab.open(.all)
        XCTAssertNil(model.source)

        // Back in the first, everything is there again.
        lab.openCatalog(catalogue("One"))
        XCTAssertEqual(lab.projects.projects.map(\.name), ["Leica"])
    }

    func testClosingTheCatalogueLeavesTheLabEmpty() throws {
        let frames = try photos("A", count: 2)
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        let lab = model.lab
        lab.openCatalog(catalogue("One"))
        let archive = lab.projects.create(named: "Leica")
        lab.projects.addRolls([frames[0].deletingLastPathComponent()], to: archive.id)
        lab.open(.archive(archive.id))
        XCTAssertNotNil(model.source)

        lab.closeCatalog()
        XCTAssertFalse(lab.projects.isOpen)
        XCTAssertEqual(lab.catalogName, "No Catalog")
        XCTAssertNil(model.source)
        XCTAssertNil(model.libraryRoot)
        XCTAssertTrue(lab.projects.projects.isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "qlick.catalog"), catalogue("One").labStandardized.path,
                       "the next launch opens the last catalogue open")

        lab.openCatalog(catalogue("One"))
        XCTAssertTrue(lab.projects.isOpen)
        XCTAssertEqual(lab.projects.projects.map(\.name), ["Leica"])
    }

    func testRemovingTheLastArchiveClosesAllPhotographs() throws {
        let frames = try photos("A", count: 3)
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        let lab = model.lab
        lab.openCatalog(catalogue("One"))
        let archive = lab.projects.create(named: "Leica")
        lab.projects.addRolls([frames[0].deletingLastPathComponent()], to: archive.id)
        lab.open(.all)
        XCTAssertNotNil(model.libraryRoot)

        let project = try XCTUnwrap(lab.projects.archive(archive.id))
        lab.projects.remove(archive.id)
        lab.closeWhatLeftTheCatalog(gone: project.rolls.map { URL(fileURLWithPath: $0.folder, isDirectory: true) })
        XCTAssertNil(model.libraryRoot, "All Photographs holds nothing now: it closes")
        XCTAssertNil(model.source)
    }

    func testRemovingAnArchiveClosesItsFolderButNotAFolderOpenedFromTheDisk() throws {
        let frames = try photos("A", count: 2)
        let other = try photos("Elsewhere", count: 2)
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        let lab = model.lab
        lab.openCatalog(catalogue("One"))
        let archive = lab.projects.create(named: "Leica")
        let folder = frames[0].deletingLastPathComponent()
        lab.projects.addRolls([folder], to: archive.id)

        lab.open(folder: other[0].deletingLastPathComponent())
        XCTAssertNotNil(model.source)
        let project = try XCTUnwrap(lab.projects.archive(archive.id))
        lab.projects.remove(archive.id)
        lab.closeWhatLeftTheCatalog(gone: project.rolls.map { URL(fileURLWithPath: $0.folder, isDirectory: true) })
        XCTAssertEqual(model.source?.lastPathComponent, "F0001.png", "a folder opened by hand, not the Archive's, stays")

        let again = lab.projects.create(named: "Leica")
        lab.projects.addRolls([folder], to: again.id)
        lab.open(folder: folder)
        XCTAssertEqual(model.source?.deletingLastPathComponent().labStandardized.path, folder.labStandardized.path)
        let removed = try XCTUnwrap(lab.projects.archive(again.id))
        lab.projects.remove(again.id)
        lab.closeWhatLeftTheCatalog(gone: removed.rolls.map { URL(fileURLWithPath: $0.folder, isDirectory: true) })
        XCTAssertNil(model.source, "the removed Archive's folder closes")
    }

    func testTheLastPhotographIsReopenedOnlyInItsCatalogue() throws {
        let frames = try photos("A", count: 1)
        let model = EditorModel(sidecars: nil)
        defer { model.shutdown() }
        let lab = model.lab
        lab.openCatalog(catalogue("One"))
        let archive = lab.projects.create(named: "Leica")
        lab.projects.addRolls([frames[0].deletingLastPathComponent()], to: archive.id)

        var session = EditorSession(source: frames[0])
        session.catalog = catalogue("One").labStandardized.path
        XCTAssertTrue(model.restores(session))
        session.catalog = catalogue("Two").labStandardized.path
        XCTAssertFalse(model.restores(session), "saved in another catalogue")

        // Saved before sessions named their catalogue: only one of this catalogue's photographs.
        EditorSession.unnamedNeedCatalog = true
        session.catalog = nil
        XCTAssertTrue(model.restores(session))
        let stranger = try photos("B", count: 1)[0]
        XCTAssertFalse(model.restores(EditorSession(source: stranger)))

        lab.closeCatalog()
        session.catalog = catalogue("One").labStandardized.path
        XCTAssertFalse(model.restores(session), "no catalogue open, nothing reopens")

        // The catalogue's name goes with the session, and back.
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(EditorSession.self, from: data).catalog, session.catalog)
    }
}
