// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// The lab's own pieces: the sheet's geometry, the pencil, projects, keys, pages, comparison, search.
final class ContactSheetLayoutTests: XCTestCase {
    func testColumnsFollowTheWidthAndEveryFrameHasItsPlace() {
        let layout = ContactSheetLayout(style: .classic, count: 38, width: 1200, frameWidth: 168, header: 52)
        XCTAssertGreaterThan(layout.columns, 1)
        XCTAssertEqual(layout.rows, (38 + layout.columns - 1) / layout.columns)
        // Strips stay inside the sheet, and frames never overlap.
        for row in 0..<layout.rows {
            XCTAssertGreaterThanOrEqual(layout.strip(row).minX, layout.margin - 0.5)
            XCTAssertLessThanOrEqual(layout.strip(row).maxX, 1200 - layout.margin + 0.5)
        }
        for index in 1..<38 where layout.row(of: index) == layout.row(of: index - 1) {
            XCTAssertGreaterThan(layout.picture(index).minX, layout.picture(index - 1).maxX)
        }
        XCTAssertEqual(layout.picture(0).width / layout.picture(0).height, 1.5, accuracy: 0.02)
        XCTAssertEqual(layout.height, layout.strip(layout.rows - 1).maxY + layout.margin, accuracy: 0.5)
    }

    func testAPointFindsItsFrameAndTheFilmBetweenFramesFindsNone() {
        let layout = ContactSheetLayout(style: .classic, count: 20, width: 1000, frameWidth: 160, header: 40)
        for index in [0, 3, layout.columns, 19] {
            let picture = layout.picture(index)
            XCTAssertEqual(layout.index(at: CGPoint(x: picture.midX, y: picture.midY)), index)
        }
        let first = layout.picture(0), second = layout.picture(1)
        XCTAssertNil(layout.index(at: CGPoint(x: (first.maxX + second.minX) / 2, y: first.midY), slop: 0))
        XCTAssertNil(layout.index(at: CGPoint(x: first.midX, y: 2)))
        // The last strip is cut after its last frame: nothing beyond it.
        let last = layout.picture(19)
        XCTAssertNil(layout.index(at: CGPoint(x: last.maxX + layout.pitch, y: last.midY)))
    }

    func testRowsAndFramesInARectangle() {
        let layout = ContactSheetLayout(style: .compact, count: 100, width: 900, frameWidth: 120)
        let second = layout.strip(1)
        XCTAssertEqual(layout.rows(in: second.insetBy(dx: 0, dy: 4)), 1..<2)
        XCTAssertEqual(layout.indices(in: second.insetBy(dx: 0, dy: 4)), Array(layout.frames(inRow: 1)))
        XCTAssertTrue(layout.rows(in: CGRect(x: 0, y: -500, width: 900, height: 100)).isEmpty)
        XCTAssertEqual(layout.rows(in: CGRect(x: 0, y: 0, width: 900, height: 1_000_000)), 0..<layout.rows)
    }

    func testUpAndDownKeepTheColumn() {
        let layout = ContactSheetLayout(style: .classic, count: 14, width: 1000, frameWidth: 160)
        let columns = layout.columns
        XCTAssertEqual(layout.vertical(from: 1, by: 1), 1 + columns)
        XCTAssertNil(layout.vertical(from: 1, by: -1))
        // Down from the row above a short last strip goes to its last frame.
        let above = (layout.rows - 2) * columns + columns - 1
        XCTAssertEqual(layout.vertical(from: above, by: 1), 13)
        XCTAssertNil(layout.vertical(from: 13, by: 1))
    }

    func testAPrintedPageFillsItsWidthWithTheColumnsAsked() {
        for columns in 3...9 {
            let layout = ContactSheetLayout(style: .classic, count: columns * 2, width: 595, frameWidth: 100, columns: columns, margin: 28)
            XCTAssertEqual(layout.columns, columns)
            XCTAssertEqual(layout.strip(0).minX, 28, accuracy: 1.5)
            XCTAssertEqual(layout.strip(0).maxX, 595 - 28, accuracy: 1.5)
        }
    }

    func testEightPerforationsToAFrame() {
        let layout = ContactSheetLayout(style: .classic, count: 6, width: 1400, frameWidth: 200, columns: 6, margin: 20)
        let holes = layout.perforations(strip: layout.strip(0), top: true)
        XCTAssertEqual(Double(holes.count) / 6, 8, accuracy: 0.5)
        XCTAssertTrue(holes.allSatisfy { layout.strip(0).contains($0) })
        XCTAssertTrue(ContactSheetLayout(style: .detail, count: 6, width: 1400, frameWidth: 200).perforations(strip: .zero, top: true).isEmpty)
    }

    func testAPictureIsFittedWholeAndAnUprightOneTurnsOnlyWhenAsked() {
        let window = CGRect(x: 0, y: 0, width: 150, height: 100)
        let upright = ContactSheetLayout.fit(aspect: 2.0 / 3, in: window, sideways: false)
        XCTAssertFalse(upright.turned)
        XCTAssertEqual(upright.rect.height, 100, accuracy: 0.01)
        XCTAssertEqual(upright.rect.width, 100 * 2 / 3, accuracy: 0.01)
        let lying = ContactSheetLayout.fit(aspect: 2.0 / 3, in: window, sideways: true)
        XCTAssertTrue(lying.turned)
        XCTAssertEqual(lying.rect.width, 150, accuracy: 0.01)
        XCTAssertFalse(ContactSheetLayout.fit(aspect: 1.5, in: window, sideways: true).turned)
    }
}

final class GreasePencilTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 180, height: 120)

    func testAFrameAlwaysCarriesTheSameMarkAndTwoFramesDifferentOnes() {
        let a = GreasePencil.ring(in: frame, seed: "DSCF4101.jpg", weight: 3), again = GreasePencil.ring(in: frame, seed: "DSCF4101.jpg", weight: 3)
        let other = GreasePencil.ring(in: frame, seed: "DSCF4102.jpg", weight: 3)
        XCTAssertEqual(a.map(\.points), again.map(\.points))
        XCTAssertNotEqual(a.map(\.points), other.map(\.points))
        XCTAssertNotEqual(GreasePencil.cross(in: frame, seed: "a", weight: 3).map(\.points), GreasePencil.cross(in: frame, seed: "b", weight: 3).map(\.points))
    }

    func testARingGoesRoundItsFrameAndStaysNearIt() {
        for seed in (0..<40).map({ "IMG_\($0).CR3" }) {
            let ring = GreasePencil.ring(in: frame, seed: seed, weight: 3)[0]
            let bounds = ring.bounds
            // Round the whole frame, within a sixth of its size either way.
            XCTAssertLessThan(abs(bounds.midX - frame.midX), frame.width * 0.08, seed)
            XCTAssertGreaterThan(bounds.width, frame.width * 0.9, seed)
            XCTAssertLessThan(bounds.width, frame.width * 1.25, seed)
            XCTAssertGreaterThan(bounds.height, frame.height * 0.9, seed)
            XCTAssertLessThan(bounds.height, frame.height * 1.25, seed)
            // A hand's line: its weight varies, and it ends thinner than it runs.
            XCTAssertLessThan(ring.widths.last!, ring.widths[ring.widths.count / 2])
            XCTAssertGreaterThan(Set(ring.widths.map { ($0 * 100).rounded() }).count, 10)
        }
    }

    func testACrossIsTwoStrokesCornerToCorner() {
        let strokes = GreasePencil.cross(in: frame, seed: "x", weight: 3).filter { $0.opacity > 0.5 }
        XCTAssertEqual(strokes.count, 2)
        for stroke in strokes {
            let first = stroke.points.first!, last = stroke.points.last!
            XCTAssertGreaterThan(abs(last.x - first.x), frame.width * 0.6)
            XCTAssertGreaterThan(abs(last.y - first.y), frame.height * 0.6)
        }
    }

    func testAMarkCanBeDrawnPartWay() {
        let stroke = GreasePencil.ring(in: frame, seed: "progress", weight: 3)[0]
        let half = stroke.path(progress: 0.5).boundingBoxOfPath, whole = stroke.path().boundingBoxOfPath
        XCTAssertFalse(stroke.path(progress: 0).isEmpty)
        XCTAssertLessThan(half.width * half.height, whole.width * whole.height)
        XCTAssertTrue(whole.insetBy(dx: -1, dy: -1).contains(half))
    }

    func testThePencilGrowsWithTheFrameWithinLimits() {
        XCTAssertLessThan(GreasePencil.weight(forFrameWidth: 90), GreasePencil.weight(forFrameWidth: 240))
        XCTAssertEqual(GreasePencil.weight(forFrameWidth: 20), GreasePencil.weight(forFrameWidth: 30))
        XCTAssertEqual(GreasePencil.weight(forFrameWidth: 2000), GreasePencil.weight(forFrameWidth: 3000))
    }
}

@MainActor final class ProjectStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func roll(_ name: String, photographs: Int) throws -> URL {
        let folder = root.appendingPathComponent("photos/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<photographs { try Data([0xff, 0xd8, 0xff]).write(to: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", index))) }
        return folder
    }

    func testAProjectKeepsItsRollsBetweenLaunchesAndNeverTouchesTheFiles() throws {
        let store = ProjectStore(directory: root.appendingPathComponent("projects"))
        let project = store.create(named: "Provence 2026")
        let folder = try roll("Marseille", photographs: 3)
        XCTAssertEqual(store.addRolls([folder], to: project.id).map(\.name), ["Marseille"])
        // The same folder twice is one roll.
        XCTAssertTrue(store.addRolls([folder], to: project.id).isEmpty)
        store.updateRoll(store.projects[0].rolls[0].id, in: project.id) { $0.film = "Portra 400"; $0.notes = "Vieux-Port" }

        let again = ProjectStore(directory: root.appendingPathComponent("projects"))
        XCTAssertEqual(again.projects.map(\.name), ["Provence 2026"])
        XCTAssertEqual(again.projects[0].rolls.map(\.film), ["Portra 400"])
        XCTAssertEqual(again.find(folder: folder)?.roll.notes, "Vieux-Port")

        again.removeRoll(again.projects[0].rolls[0].id, from: project.id)
        again.remove(project.id)
        XCTAssertTrue(ProjectStore(directory: root.appendingPathComponent("projects")).projects.isEmpty)
        // Forgetting a roll and a project leaves every photograph where it was.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testAFolderOfFoldersGivesARollForEachThatHoldsPhotographs() throws {
        let a = try roll("Séance/Jour 1", photographs: 2), b = try roll("Séance/Jour 2", photographs: 1)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("photos/Séance/Vide"), withIntermediateDirectories: true)
        let found = ProjectStore.rollFolders(in: root.appendingPathComponent("photos/Séance"))
        XCTAssertEqual(found.map(\.lastPathComponent), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertEqual(ProjectStore.rollFolders(in: a).map(\.path), [a.path])
        XCTAssertTrue(ProjectStore.rollFolders(in: root.appendingPathComponent("nowhere")).isEmpty)
    }

    func testNamesStayUniqueAndCountsComeFromTheFolder() throws {
        let store = ProjectStore(directory: root.appendingPathComponent("projects"))
        store.create(named: "Rouleau")
        XCTAssertEqual(store.create(named: "rouleau").name, "rouleau 2")
        XCTAssertEqual(store.create(named: "  ").name, "New Project")
        let stats = ProjectStore.stats(of: try roll("Compte", photographs: 5), store: nil)
        XCTAssertEqual(stats.total, 5)
        XCTAssertEqual(stats.names.first, "IMG_0000.jpg")
        XCTAssertEqual(stats.unmarked, 5)
        XCTAssertTrue(ProjectStore.stats(of: root.appendingPathComponent("gone"), store: nil).missing)
    }

    func testAProjectFromANewerLabIsLeftAlone() throws {
        let directory = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newer = #"{"schema": 99, "id": "\#(UUID().uuidString)", "name": "Futur", "notes": "", "createdAt": "2030-01-01T00:00:00Z", "rolls": [], "archived": false}"#
        try Data(newer.utf8).write(to: directory.appendingPathComponent("futur.json"))
        XCTAssertTrue(ProjectStore(directory: directory).projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("futur.json").path))
    }
}

@MainActor final class ShortcutStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "qlick-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheSortingKeysStartAsNegsAndCanBeChanged() {
        let defaults = defaults()
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.key(.pick), "p")
        XCTAssertEqual(store.key(.reject), "x")
        XCTAssertTrue(store.isStandard)
        XCTAssertTrue(store.set("S", for: .pick))
        XCTAssertEqual(store.key(.pick), "s")
        XCTAssertEqual(ShortcutStore(defaults: defaults).key(.pick), "s")
        store.reset()
        XCTAssertEqual(ShortcutStore(defaults: defaults).key(.pick), "p")
    }

    func testAKeyAlreadyTakenIsRefused() {
        let store = ShortcutStore(defaults: defaults())
        XCTAssertNotNil(store.problem("x", for: .pick), "reject's key")
        XCTAssertNotNil(store.problem("3", for: .pick), "rates three stars")
        XCTAssertNotNil(store.problem("g", for: .pick), "shows the sheet")
        XCTAssertNotNil(store.problem(String(UnicodeScalar(0xF702)!), for: .pick), "an arrow")
        XCTAssertNotNil(store.problem("ab", for: .pick))
        XCTAssertNil(store.problem("p", for: .pick), "its own key")
        XCTAssertFalse(store.set("x", for: .pick))
        XCTAssertEqual(store.key(.pick), "p")
    }

    func testEveryActionHasADistinctStandardKey() {
        let keys = SheetAction.allCases.map(\.standard)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: ShortcutStore.reserved))
        XCTAssertEqual(ShortcutStore.display(" "), "Space")
        XCTAssertEqual(ShortcutStore.display("p"), "P")
    }
}

final class SheetPaginationTests: XCTestCase {
    func testEveryFrameIsPrintedOnceAndPagesAreFull() {
        for count in [1, 6, 36, 38, 137, 400] {
            for columns in [4, 6, 8] {
                var options = SheetPrintOptions()
                options.columns = columns
                let pages = SheetPagination(options: options, count: count, notes: false)
                XCTAssertEqual((0..<pages.pages).reduce(0) { $0 + pages.range($1).count }, count)
                XCTAssertEqual(pages.range(0).lowerBound, 0)
                XCTAssertEqual(pages.range(pages.pages - 1).upperBound, count)
                for page in 0..<pages.pages {
                    let layout = pages.layout(page)
                    // The sheet fits the page, above its foot.
                    XCTAssertLessThanOrEqual(layout.height, options.page.height - SheetPagination.footer + 0.5, "\(count) frames, \(columns) columns, page \(page)")
                    if page < pages.pages - 1 { XCTAssertEqual(pages.range(page).count, pages.perPage) }
                }
            }
        }
    }

    func testPaperSizesAndOrientation() {
        var options = SheetPrintOptions()
        XCTAssertEqual(options.page.width, 595.3, accuracy: 0.2)
        XCTAssertEqual(options.page.height, 841.9, accuracy: 0.2)
        options.landscape = true
        XCTAssertGreaterThan(options.page.width, options.page.height)
        options.paper = .a3
        XCTAssertEqual(options.page.width, 1190.6, accuracy: 0.3)
        // A landscape page holds fewer strips of the same width, more columns make smaller frames and more strips.
        var portrait = SheetPrintOptions(); portrait.columns = 6
        var wide = portrait; wide.columns = 9
        XCTAssertGreaterThan(SheetPagination(options: wide, count: 500, notes: false).perPage, SheetPagination(options: portrait, count: 500, notes: false).perPage)
    }

    func testOptionsSurviveARoundTrip() throws {
        var options = SheetPrintOptions()
        options.paper = .twentyFourByThirty; options.background = .white; options.frames = .picks; options.columns = 8
        XCTAssertEqual(try JSONDecoder().decode(SheetPrintOptions.self, from: JSONEncoder().encode(options)), options)
    }
}

final class CompareGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let picture = CGSize(width: 2400, height: 1600)

    func testPanesShareTheSurface() {
        XCTAssertEqual(CompareGeometry.panes(1, in: bounds), [bounds])
        let two = CompareGeometry.panes(2, in: bounds)
        XCTAssertEqual(two[0].width, two[1].width)
        XCTAssertEqual(two[1].minX - two[0].maxX, CompareGeometry.gap)
        let four = CompareGeometry.panes(4, in: bounds)
        XCTAssertEqual(four[0].minY, four[1].minY)
        XCTAssertGreaterThan(four[2].minY, four[0].maxY)
        XCTAssertTrue(CompareGeometry.panes(0, in: bounds).isEmpty)
    }

    func testAFittedPictureIsWholeAndCentred() {
        let pane = CompareGeometry.panes(2, in: bounds)[0]
        let rect = CompareGeometry.rect(of: picture, in: pane, viewport: CompareViewport())
        XCTAssertEqual(rect.midX, pane.midX, accuracy: 0.01)
        XCTAssertEqual(rect.midY, pane.midY, accuracy: 0.01)
        XCTAssertLessThanOrEqual(rect.width, pane.width + 0.01)
        XCTAssertLessThanOrEqual(rect.height, pane.height + 0.01)
    }

    func testZoomingKeepsThePointUnderTheCursor() {
        let pane = bounds
        let anchor = CGPoint(x: 900, y: 300)
        let before = CompareGeometry.rect(of: picture, in: pane, viewport: CompareViewport())
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        let zoomed = CompareGeometry.zoomed(CompareViewport(), to: 4, about: anchor, picture: picture, pane: pane)
        let after = CompareGeometry.rect(of: picture, in: pane, viewport: zoomed)
        XCTAssertEqual(after.minX + unit.x * after.width, anchor.x, accuracy: 0.5)
        XCTAssertEqual(after.minY + unit.y * after.height, anchor.y, accuracy: 0.5)
        XCTAssertEqual(zoomed.zoom, 4)
    }

    func testAViewportNeverLeavesItsPicture() {
        let far = CompareGeometry.clamped(CompareViewport(zoom: 4, centre: CGPoint(x: 5, y: -3)), picture: picture, pane: bounds)
        let rect = CompareGeometry.rect(of: picture, in: bounds, viewport: far)
        XCTAssertLessThanOrEqual(rect.minX, bounds.minX + 0.01)
        XCTAssertGreaterThanOrEqual(rect.maxX, bounds.maxX - 0.01)
        XCTAssertLessThanOrEqual(rect.minY, bounds.minY + 0.01)
        XCTAssertGreaterThanOrEqual(rect.maxY, bounds.maxY - 0.01)
        // Zoomed out, a quarter of the fitted size at the least.
        XCTAssertEqual(CompareGeometry.clamped(CompareViewport(zoom: 0.2), picture: picture, pane: bounds).zoom, CompareViewport.zooms.lowerBound)
        XCTAssertEqual(CompareGeometry.clamped(CompareViewport(zoom: 900), picture: picture, pane: bounds).zoom, CompareViewport.zooms.upperBound)
    }
}

final class LibrarySearchTests: XCTestCase {
    func testARollIsFoundByItsWordsItsDevelopmentsFilmAndItsFiles() {
        let marseille = LabRoll(name: "Marseille", folder: "/photos/marseille", film: "Portra 400", camera: "Leica M6")
        let prague = LabRoll(name: "Prague", folder: "/photos/prague")
        let project = LabProject(name: "Voyages 2026", notes: "", rolls: [marseille, prague])
        let stats = [prague.id: RollStats(total: 2, films: ["ilford_hp5_plus": 2], names: ["L1005201.DNG", "L1005202.DNG"])]
        let stocks = [Stock(.object(["id": .string("ilford_hp5_plus"), "name": .string("Ilford HP5 Plus"), "bw": .bool(true)]))]
        func rolls(_ query: String) -> [String] { LibrarySearch.results(query, projects: [project], stats: stats, stocks: stocks).flatMap { $0.rolls.map(\.name) } }
        XCTAssertEqual(rolls(""), ["Marseille", "Prague"])
        XCTAssertEqual(rolls("portra"), ["Marseille"])
        XCTAssertEqual(rolls("leica marseille"), ["Marseille"])
        XCTAssertEqual(rolls("voyages"), ["Marseille", "Prague"])
        XCTAssertEqual(rolls("hp5"), ["Prague"])
        XCTAssertEqual(rolls("L1005202"), ["Prague"])
        XCTAssertEqual(rolls("velvia"), [])
        let found = LibrarySearch.results("hp5", projects: [project], stats: stats, stocks: stocks)
        XCTAssertEqual(found.first?.reasons[prague.id], "2 frames developed on Ilford HP5 Plus")
    }
}

final class StockFactsTests: XCTestCase {
    private func film(_ id: String, _ name: String, positive: Bool = false, bw: Bool = false, target: String = "") -> Stock {
        Stock(.object(["id": .string(id), "name": .string(name), "positive": .bool(positive), "bw": .bool(bw), "target_print": .string(target)]))
    }

    func testSpeedAndMakerComeFromTheName() {
        XCTAssertEqual(StockFacts.speed(film("kodak_portra_400", "Kodak Portra 400")), 400)
        XCTAssertEqual(StockFacts.speed(film("kodak_vision3_500t", "Kodak Vision3 500T")), 500)
        XCTAssertEqual(StockFacts.speed(film("fujifilm_velvia_50", "Fujifilm Velvia 50")), 50)
        XCTAssertEqual(StockFacts.speed(film("fujifilm_c200", "Fujifilm C200")), 200)
        XCTAssertEqual(StockFacts.speed(film("fujifilm_acros_100_ii", "Fujifilm Neopan 100 Acros II")), 100)
        XCTAssertNil(StockFacts.speed(film("kodak_doublex", "Kodak Double-X 5222")))
        XCTAssertEqual(StockFacts.maker(film("kodak_portra_400", "Kodak Portra 400")), "Kodak")
        XCTAssertEqual(StockFacts.maker(film("fujifilm_c200", "Fujicolor C200")), "Fujifilm")
        XCTAssertEqual(StockFacts.maker(film("lomography_lomochrome_metropolis", "LomoChrome Metropolis")), "Lomography")
    }

    func testFamilies() {
        XCTAssertEqual(StockFacts.family(film("kodak_portra_400", "Kodak Portra 400"), cinemaPrints: []), .colourNegative)
        XCTAssertEqual(StockFacts.family(film("fujifilm_velvia_50", "Fujifilm Velvia 50", positive: true), cinemaPrints: []), .slide)
        XCTAssertEqual(StockFacts.family(film("kodak_trix", "Kodak Tri-X", bw: true), cinemaPrints: []), .blackAndWhite)
        XCTAssertEqual(StockFacts.family(film("kodak_vision3_500t", "Kodak Vision3 500T", target: "kodak_2383"), cinemaPrints: ["kodak_2383"]), .cinema)
        XCTAssertEqual(StockFacts.family(film("kodak_aerochrome_1443", "Kodak Aerochrome III 1443", positive: true), cinemaPrints: []), .infrared)
    }

    func testEveryBundledProfileReadsItsCurves() throws {
        let profiles = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../data/profiles").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let profile = try XCTUnwrap(StockProfile.read(file), file.lastPathComponent)
            XCTAssertEqual(profile.logExposure.count, profile.density.count, file.lastPathComponent)
            XCTAssertFalse(profile.density.isEmpty, file.lastPathComponent)
            XCTAssertFalse(profile.type.isEmpty, file.lastPathComponent)
        }
    }
}

final class LabWordsTests: XCTestCase {
    func testRoomsHaveDistinctNamesKeysAndSymbols() {
        XCTAssertEqual(Set(Workspace.allCases.map(\.title)).count, Workspace.allCases.count)
        // Import has a key of its own, so the seven rooms before it keep theirs.
        XCTAssertEqual(Workspace.allCases.map(\.key), ["1", "2", "3", "4", "5", "6", "7", "0"])
        XCTAssertEqual(Workspace.contactSheet.title, "Contact Sheet")
    }

    func testFrenchKeepsAWordItDoesNotKnow() {
        XCTAssertEqual(French.words["Highlights"], "Hautes lumières")
        XCTAssertNil(French.words["A control added upstream tomorrow"])
        XCTAssertFalse(French.words.values.contains(""))
    }

    func testSheetOptionsSurviveARoundTrip() throws {
        var options = SheetOptions()
        options.style = .compact; options.lightTable = true; options.frameWidth = 222; options.tool = .pointer
        XCTAssertEqual(try JSONDecoder().decode(SheetOptions.self, from: JSONEncoder().encode(options)), options)
    }

    func testExposureLineReadsAsAPhotographerWritesIt() {
        let facts = FrameFacts(iso: 400, exposure: 1.0 / 250, aperture: 2.8, focalLength: 35)
        XCTAssertEqual(facts.exposureLine, "1/250 s · f/2.8 · ISO 400 · 35 mm")
        XCTAssertEqual(FrameFacts(exposure: 2).exposureLine, "2 s")
        XCTAssertEqual(FrameFacts().exposureLine, "")
    }
}
