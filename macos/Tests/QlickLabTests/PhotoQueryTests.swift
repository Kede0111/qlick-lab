import XCTest
@testable import QlickLab

/// 0.4's R5: the search's fields, Smart Rolls' rules, the catalogue's index (read once, then only what changed), the
/// By Date tree and New Rolls by Day. Nothing on the disk changes.
@MainActor final class PhotoQueryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private var m11: PhotoRecord {
        var record = PhotoRecord(path: "/photos/Spain/L1004394.DNG")
        record.rating = 4; record.flag = .pick
        record.words = PhotoWords(label: .red, keywords: ["USA", "New York"], title: "Brooklyn Bridge at dusk", caption: "")
        record.edited = true
        record.filmsDeveloped = ["kodak_portra_400", "Kodak Portra 400"]
        record.filmLoaded = ""
        record.recipe = "Warm Prints"
        record.archive = "Leica M11"
        record.camera = "LEICA M11"; record.lens = "Summilux-M 1:1.4/35 ASPH."
        record.iso = 1600; record.exposure = 1.0 / 250; record.aperture = 2; record.focalLength = 35
        record.width = 9528; record.height = 6328
        record.captured = date("2026-09-19 18:42")
        record.imported = date("2026-09-20 09:00")
        return record
    }

    private var film: PhotoRecord {
        var record = PhotoRecord(path: "/photos/Roll 12/scan_007.tif")
        record.filmLoaded = "Portra 400 pushed +1"
        record.camera = "Leica M6"
        record.width = 4000; record.height = 6000
        record.captured = date("2025-03-02 11:00")
        return record
    }

    private func matches(_ query: String) -> [String] {
        let rules = PhotoQuery.parse(query)
        return [m11, film].filter { rules.matches($0, now: date("2026-10-01 12:00")) }.map(\.name)
    }

    // MARK: The search's words

    func testFieldsAndPlainWords() {
        XCTAssertEqual(matches(""), ["L1004394.DNG", "scan_007.tif"], "nothing asked, everything found")
        XCTAssertEqual(matches("rating:>=3"), ["L1004394.DNG"])
        XCTAssertEqual(matches("rating:0"), ["scan_007.tif"])
        XCTAssertEqual(matches("pick"), ["L1004394.DNG"])
        XCTAssertEqual(matches("reject"), [])
        XCTAssertEqual(matches("unmarked"), ["scan_007.tif"])
        XCTAssertEqual(matches("label:red"), ["L1004394.DNG"])
        XCTAssertEqual(matches("label:none"), ["scan_007.tif"])
        XCTAssertEqual(matches("film:portra"), ["L1004394.DNG", "scan_007.tif"], "loaded or developed on")
        XCTAssertEqual(matches(#"film:"portra 400""#), ["L1004394.DNG", "scan_007.tif"], "a stock id reads as its words")
        XCTAssertEqual(matches("camera:m11"), ["L1004394.DNG"])
        XCTAssertEqual(matches("lens:35"), ["L1004394.DNG"])
        XCTAssertEqual(matches("iso:>800"), ["L1004394.DNG"])
        XCTAssertEqual(matches("iso:>1600"), [], "more than is more than")
        XCTAssertEqual(matches("iso:>=1600"), ["L1004394.DNG"])
        XCTAssertEqual(matches("aperture:<2.8"), ["L1004394.DNG"])
        XCTAssertEqual(matches("aperture:<2"), [])
        XCTAssertEqual(matches("shutter:1/250"), ["L1004394.DNG"])
        XCTAssertEqual(matches("shutter:<1/125"), ["L1004394.DNG"])
        XCTAssertEqual(matches("date:2026-09"), ["L1004394.DNG"])
        XCTAssertEqual(matches("date:2026"), ["L1004394.DNG"])
        XCTAssertEqual(matches("date:2026-09-19"), ["L1004394.DNG"])
        XCTAssertEqual(matches("date:2026-09-18"), [])
        XCTAssertEqual(matches("date:<2026"), ["scan_007.tif"])
        XCTAssertEqual(matches("date:2025-01..2025-12"), ["scan_007.tif"], "a range")
        XCTAssertEqual(matches("imported:30d"), ["L1004394.DNG"], "in the last 30 days")
        XCTAssertEqual(matches("keyword:usa"), ["L1004394.DNG"])
        XCTAssertEqual(matches(#"keyword:"new york""#), ["L1004394.DNG"], "quotes keep words together")
        XCTAssertEqual(matches(#"title:"bridge at""#), ["L1004394.DNG"])
        XCTAssertEqual(matches("name:scan"), ["scan_007.tif"])
        XCTAssertEqual(matches("type:dng"), ["L1004394.DNG"])
        XCTAssertEqual(matches("type:.tif"), ["scan_007.tif"])
        XCTAssertEqual(matches("developed"), ["L1004394.DNG"])
        XCTAssertEqual(matches("undeveloped"), ["scan_007.tif"])
        XCTAssertEqual(matches("portrait"), ["scan_007.tif"])
        XCTAssertEqual(matches("recipe:warm"), ["L1004394.DNG"])
        XCTAssertEqual(matches("archive:leica"), ["L1004394.DNG"])
        XCTAssertEqual(matches("brooklyn"), ["L1004394.DNG"], "a plain word: the title")
        XCTAssertEqual(matches("m6"), ["scan_007.tif"], "a plain word: the camera")
        XCTAssertEqual(matches("Spain"), ["L1004394.DNG"], "a plain word: the folder")
        XCTAssertEqual(matches("rating:>=3 pick film:portra camera:m11 lens:35 iso:>800 date:2026-09 keyword:usa label:red"), ["L1004394.DNG"],
                       "the example of the proposal")
    }

    func testMinusLeavesOutAndSeveralMarksMeanEither() {
        XCTAssertEqual(matches("-pick"), ["scan_007.tif"])
        XCTAssertEqual(matches("-camera:m11"), ["scan_007.tif"])
        XCTAssertEqual(matches("pick unmarked"), ["L1004394.DNG", "scan_007.tif"], "two flags: either")
        XCTAssertEqual(matches("label:red label:blue"), ["L1004394.DNG"])
        XCTAssertEqual(matches("pick camera:m6"), [], "different fields: both")
        let parsed = PhotoQuery.parse("pick reject label:red")
        XCTAssertEqual(parsed.rules, [SmartRule(field: .label, op: .is, value: "red")])
        XCTAssertEqual(parsed.groups.first?.match, .any)
        XCTAssertEqual(parsed.groups.first?.rules.map(\.value), ["pick", "reject"])
    }

    func testUnknownFieldsAndUnreadableValuesAreWordsOrNothing() {
        XCTAssertEqual(PhotoQuery.parse("colour:red").rules, [SmartRule(field: .label, op: .is, value: "red")])
        XCTAssertEqual(PhotoQuery.parse("http://x").rules, [SmartRule(field: .text, op: .contains, value: "http://x")], "not a field: a word")
        XCTAssertTrue(PhotoQuery.parse("iso:lots").isEmpty, "a number that can't be read asks nothing")
        XCTAssertTrue(PhotoQuery.parse("date:soon").isEmpty)
        XCTAssertEqual(PhotoQuery.tokens(#"a "b c" d:"e f""#), ["a", "b c", "d:e f"])
        XCTAssertEqual(SmartRule.number("f/2.8"), 2.8)
        XCTAssertEqual(SmartRule.number("35mm"), 35)
        XCTAssertEqual(SmartRule.number("1/250")!, 0.004, accuracy: 1e-9)
        XCTAssertNil(SmartRule.period("2026-13"))
        XCTAssertEqual(PhotoQuery.parse(#"label:"To Print""#, label: { $0 == "To Print" ? .red : nil }).rules.first?.value, "red", "a label's own name")
    }

    // MARK: Smart Rolls

    func testRulesNestAndKeepInBoxesFile() throws {
        var rules = RuleGroup(match: .all, rules: [SmartRule(field: .rating, op: .atLeast, value: "3")])
        rules.groups = [RuleGroup(match: .any, rules: [SmartRule(field: .camera, op: .contains, value: "m6"),
                                                       SmartRule(field: .label, op: .is, value: "red")])]
        XCTAssertTrue(rules.matches(m11))
        XCTAssertFalse(rules.matches(film), "rated 0")
        let none = RuleGroup(match: .none, rules: [SmartRule(field: .developed, op: .is, value: "yes")])
        XCTAssertEqual([m11, film].filter { none.matches($0) }.map(\.name), ["scan_007.tif"])

        let catalogue = root.appendingPathComponent("catalogue.qlicklab", isDirectory: true)
        let store = ProjectStore(directory: catalogue)
        let box = try XCTUnwrap(store.createBox(named: "Best"))
        let roll = try XCTUnwrap(store.createSmartRoll(named: "Four stars", in: box.id, rules: rules))
        let read = try XCTUnwrap(BoxesFile.read(inCatalog: catalogue))
        XCTAssertEqual(read.first?.rolls.first?.rules, rules, "kept in boxes.json")
        XCTAssertNil(BoxesFile.read(inCatalog: catalogue)?.first?.rolls.first.map { $0.frames.isEmpty ? nil : $0 } ?? nil, "no photographs kept")

        // Its photographs are found by the rules (the lab's index), never put in by hand.
        store.smartFrames = { group in group == rules ? ["/photos/Spain/L1004394.DNG"] : [] }
        XCTAssertEqual(store.frames(of: .roll(roll.id, box: box.id)), ["/photos/Spain/L1004394.DNG"])
        XCTAssertEqual(store.frames(of: .box(box.id)), ["/photos/Spain/L1004394.DNG"], "a Box shows its Smart Rolls' photographs")
        XCTAssertTrue(store.isSmart(.roll(roll.id, box: box.id)))
        let plan = store.plan(.photos([URL(fileURLWithPath: "/photos/Roll 12/scan_007.tif")], from: nil), onto: .roll(roll.id, box: box.id), at: 0.5, copying: false)
        XCTAssertEqual(plan?.operation, .refused, "nothing is dropped into a Smart Roll")
        store.changeSmartRoll(roll.id, in: box.id, name: "Three", rules: RuleGroup(match: .any))
        XCTAssertEqual(store.boxRoll(roll.id, in: box.id)?.roll.name, "Three")
        XCTAssertEqual(store.boxRoll(roll.id, in: box.id)?.roll.rules, RuleGroup(match: .any))
    }

    func testTheFilterBecomesRules() {
        var filter = LibraryFilter(rating: .atLeast(3), flags: [.pick], labels: [.red, .blue], keyword: "usa", search: "iso:>800", period: "2026-09", camera: "LEICA M11")
        let rules = filter.asRules
        XCTAssertTrue(rules.matches(PhotoRecord(path: "/x.dng")) == false)
        var record = m11
        record.words.label = .blue
        XCTAssertTrue(rules.matches(record))
        record.iso = 400
        XCTAssertFalse(rules.matches(record), "the search is kept")
        filter = LibraryFilter(period: "last:30")
        XCTAssertEqual(filter.recordRules.rules, [SmartRule(field: .captureDate, op: .inLast, value: "30")])
        XCTAssertTrue(LibraryFilter(search: "x").active)
    }

    // MARK: The index, By Date

    func testTheIndexReadsOnceThenOnlyWhatChanged() throws {
        let folder = root.appendingPathComponent("photos/A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["A1.jpg", "A2.jpg"] { try Data("jpeg \(name)".utf8).write(to: folder.appendingPathComponent(name)) }
        let sidecar = #"{"qlick":1,"defaultsVersion":1,"variants":[{"id":"a","rating":4,"flag":"pick","label":"red","keywords":["usa"],"recipe":"Warm","edits":{"film":"kodak_portra_400","paper":"x"}}]}"#
        try Data(sidecar.utf8).write(to: folder.appendingPathComponent("A1.jpg.qlick"))
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        let first = try XCTUnwrap(CatalogIndex.build(folders: [folder], old: [:], store: nil))
        XCTAssertEqual(first.order.map { ($0 as NSString).lastPathComponent }, ["A1.jpg", "A2.jpg"])
        let a1 = try XCTUnwrap(first.photos[folder.appendingPathComponent("A1.jpg").standardizedFileURL.path])
        XCTAssertEqual(a1.rating, 4); XCTAssertEqual(a1.flag, "pick"); XCTAssertEqual(a1.label, "red")
        XCTAssertEqual(a1.keywords, ["usa"]); XCTAssertEqual(a1.films, ["kodak_portra_400"]); XCTAssertEqual(a1.recipe, "Warm")
        XCTAssertTrue(a1.edited)
        XCTAssertNotNil(a1.editedAt, "the sidecar's date is the edit date")

        // Read again with nothing changed: the same, nothing read again (a sentinel kept in the old entry stays).
        var old = first.photos
        old[a1.path]?.camera = "kept"
        let again = try XCTUnwrap(CatalogIndex.build(folders: [folder], old: old, store: nil))
        XCTAssertEqual(again.photos[a1.path]?.camera, "kept", "an unchanged file isn't read again")

        // A file gone leaves the index; a removed one (the catalogue's exclusion list) isn't listed.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("A2.jpg"))
        let after = try XCTUnwrap(CatalogIndex.build(folders: [folder], old: again.photos, store: nil))
        XCTAssertEqual(after.order.count, 1)
        try Data("jpeg A2.jpg".utf8).write(to: folder.appendingPathComponent("A2.jpg"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before, "the index writes nothing beside the photographs")
    }

    func testByDateCountsYearsMonthsDaysNewestFirst() {
        let tree = DateTree.build([date("2026-09-19 10:00"), date("2026-09-19 18:00"), date("2026-09-02 08:00"), date("2025-12-31 23:00")])
        XCTAssertEqual(tree.years.map(\.key), ["2026", "2025"])
        XCTAssertEqual(tree.years.map(\.count), [3, 1])
        XCTAssertEqual(tree.years[0].children.map(\.key), ["2026-09"])
        XCTAssertEqual(tree.years[0].children[0].children.map(\.key), ["2026-09-19", "2026-09-02"])
        XCTAssertEqual(tree.years[0].children[0].children.map(\.count), [2, 1])
        XCTAssertEqual(tree.years[0].children[0].title, "September")
    }

    func testNewRollsByDayMakesABoxWithARollPerDay() throws {
        let folder = root.appendingPathComponent("photos/Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalogue = root.appendingPathComponent("catalogue.qlicklab", isDirectory: true)
        let model = EditorModel()
        model.lab.projects.open(directory: catalogue)
        var paths: [String] = []
        for (index, day) in ["2026-09-19 10:00", "2026-09-19 18:00", "2026-09-20 08:00"].enumerated() {
            let path = folder.appendingPathComponent("F\(index).jpg").path
            paths.append(path)
            var photo = IndexedPhoto(path: path)
            photo.captured = date(day)
            model.lab.catalog.insert(photo)
        }
        model.lab.newRollsByDay(named: "Trip", paths: paths)
        let box = try XCTUnwrap(model.lab.projects.boxes.first { $0.name == "Trip" })
        XCTAssertEqual(box.rolls.map(\.name), ["19 Sep 2026", "20 Sep 2026"])
        XCTAssertEqual(box.rolls.map(\.frames.count), [2, 1])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "nothing on disk")
    }

    func testLibrarySearchShowsTheFoldersHoldingMatches() {
        let a = LabRoll(name: "A", folder: "/p/A"), b = LabRoll(name: "B", folder: "/p/B")
        let archive = LabProject(name: "M11", rolls: [a, b])
        let results = LibrarySearch.folders(holding: ["/p/A/1.dng", "/p/A/x/2.dng"], projects: [archive], roots: { $0.rolls.map(\.url) })
        XCTAssertEqual(results.first?.rolls.map(\.name), ["A"])
        XCTAssertEqual(results.first?.reasons[a.id], "2 photographs match")
        XCTAssertTrue(LibrarySearch.fielded(PhotoQuery.parse("iso:>800")))
        XCTAssertFalse(LibrarySearch.fielded(PhotoQuery.parse("brooklyn")))
    }
}
