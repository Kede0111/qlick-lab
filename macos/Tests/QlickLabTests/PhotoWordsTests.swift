import XCTest
@testable import QlickLab

/// 0.4's R4: colour labels, keywords, title and caption, stored in the sidecar (and a DNG's XMP), filtered and sorted.
@MainActor final class PhotoWordsTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    private func defaults() -> UserDefaults {
        let name = TestDefaults.name("qlick-words")
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { TestDefaults.remove(name) }
        return defaults
    }

    func testTheWordsGoInAndComeBackOut() throws {
        var raw: JSONValue? = nil
        raw = try SidecarPatch(variant: "v1", rating: 3, label: .some(.green), keywords: ["Madrid", " street ", "madrid", ""],
                               title: "  Gran Vía ", caption: "Evening, from the roof.", defaultsVersion: 1, app: "test").applied(to: raw)
        let sidecar = try PhotoSidecar(raw: try XCTUnwrap(raw))
        let words = try XCTUnwrap(sidecar.variants.first?.words)
        XCTAssertEqual(words.label, .green)
        XCTAssertEqual(words.keywords, ["Madrid", "street"], "trimmed, each once whatever its case")
        XCTAssertEqual(words.title, "Gran Vía")
        XCTAssertEqual(words.caption, "Evening, from the roof.")
        XCTAssertEqual(sidecar.summary.words, words)
        XCTAssertEqual(raw?["variants"].array.first?["label"], .string("green"))

        // A change leaves the rest; empty takes it away; with nothing left the file goes.
        raw = try SidecarPatch(variant: "v1", label: .some(nil), keywords: [], defaultsVersion: 1, app: "test").applied(to: raw)
        let after = try PhotoSidecar(raw: try XCTUnwrap(raw)).variants[0]
        XCTAssertNil(after.words.label)
        XCTAssertEqual(after.words.keywords, [])
        XCTAssertEqual(after.words.title, "Gran Vía")
        XCTAssertEqual(after.rating, 3)
        raw = try SidecarPatch(variant: "v1", rating: 0, title: "", caption: "", defaultsVersion: 1, app: "test").applied(to: raw)
        XCTAssertNil(raw, "nothing left: no file")
    }

    func testALabelFromANewerVersionIsKept() throws {
        let raw = try json(#"{"qlick": 1, "defaultsVersion": 1, "variants": [{"id": "v1", "label": "orange", "rating": 2}]}"#)
        XCTAssertNil(try PhotoSidecar(raw: raw).variants[0].words.label, "read as none")
        let rated = try XCTUnwrap(try SidecarPatch(variant: "v1", rating: 4, defaultsVersion: 1, app: "test").applied(to: raw))
        XCTAssertEqual(rated["variants"].array.first?["label"], .string("orange"), "and never written over")
    }

    func testADNGsXMPCarriesTheStandardFields() throws {
        let raw = try json(#"{"qlick": 1, "defaultsVersion": 1, "variants": [{"id": "v1", "label": "red", "keywords": ["Spain", "night"], "title": "Rue", "caption": "Late & cold"}]}"#)
        let packet = String(decoding: try DNGMetadata.updated(nil, raw: raw), as: UTF8.self)
        XCTAssertTrue(packet.contains("<xmp:Label>Red</xmp:Label>"), packet)
        XCTAssertTrue(packet.contains("<rdf:li>Spain</rdf:li>"))
        XCTAssertTrue(packet.contains("<rdf:Bag>"))
        XCTAssertTrue(packet.contains(">Rue</rdf:li>"))
        XCTAssertTrue(packet.contains("Late &amp; cold"))
        // Taken off again: the fields go, the sidecar says why.
        let cleared = try json(#"{"qlick": 1, "defaultsVersion": 1, "variants": [{"id": "v1", "rating": 1}]}"#)
        let again = String(decoding: try DNGMetadata.updated(Data(packet.utf8), raw: cleared), as: UTF8.self)
        XCTAssertFalse(again.contains("xmp:Label"))
        XCTAssertFalse(again.contains("Spain"))
        // Another app's keywords stay while the lab has never written any.
        let theirs = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:subject><rdf:Bag><rdf:li>Theirs</rdf:li></rdf:Bag></dc:subject>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let kept = String(decoding: try DNGMetadata.updated(Data(theirs.utf8), raw: cleared), as: UTF8.self)
        XCTAssertTrue(kept.contains("Theirs"))
    }

    func testTheFiltersFindLabelsAndKeywords() throws {
        var red = LibrarySummary(); red.label = .red; red.words.keywords = ["Spain"]
        var blue = LibrarySummary(); blue.label = .blue
        let none = LibrarySummary()
        var filter = LibraryFilter()
        filter.labels = [.red]
        XCTAssertTrue(filter.includes(red)); XCTAssertFalse(filter.includes(blue)); XCTAssertFalse(filter.includes(none))
        filter.unlabelled = true
        XCTAssertTrue(filter.includes(none)); XCTAssertFalse(filter.includes(blue))
        filter = LibraryFilter(); filter.unlabelled = true
        XCTAssertTrue(filter.includes(none)); XCTAssertFalse(filter.includes(red))
        filter = LibraryFilter(); filter.keyword = "spain"
        XCTAssertTrue(filter.includes(red), "letter case aside"); XCTAssertFalse(filter.includes(blue))
        XCTAssertTrue(filter.active)

        // Kept between launches; one saved before the labels reads as it was.
        let defaults = defaults()
        filter.labels = [.green, .purple]
        filter.save(defaults)
        XCTAssertEqual(LibraryFilter.load(defaults), filter)
        let old = Data(#"{"rating": {"atLeast": {"_0": 3}}, "flags": ["pick"], "editedOnly": true}"#.utf8)
        let decoded = try JSONDecoder().decode(LibraryFilter.self, from: old)
        XCTAssertEqual(decoded.rating, .atLeast(3)); XCTAssertEqual(decoded.flags, [.pick]); XCTAssertTrue(decoded.editedOnly)
        XCTAssertTrue(decoded.labels.isEmpty); XCTAssertNil(decoded.keyword)
    }

    func testLabelsSortInTheirOrderAndKeysAreSixToNine() {
        XCTAssertEqual(ColorLabel.allCases.map(\.rank), [0, 1, 2, 3, 4])
        XCTAssertEqual(LibrarySort.Key.label.title, "Colour Label")
        XCTAssertEqual([SheetAction.labelRed, .labelYellow, .labelGreen, .labelBlue].map(\.standard), ["6", "7", "8", "9"])
        XCTAssertEqual(SheetAction.labelGreen.label, .green)
        XCTAssertNil(ColorLabel.purple.action, "purple is in the menus only")
        XCTAssertEqual(ColorLabel(word: " Blue"), .blue)
        let store = ShortcutStore(defaults: defaults())
        XCTAssertNotNil(store.problem("6", for: .pick), "the red label's key")
        XCTAssertTrue(store.set("0", for: .labelRed) == false, "a rating key")
        XCTAssertTrue(store.set("h", for: .labelRed))
        XCTAssertEqual(store.key(.labelRed), "h")
    }

    func testLabelNamesAndTypedKeywords() {
        let defaults = defaults()
        XCTAssertEqual(LabelNames.name(.red, defaults: defaults), "Red")
        LabelNames.set("  To Print ", for: .red, defaults: defaults)
        XCTAssertEqual(LabelNames.name(.red, defaults: defaults), "To Print")
        LabelNames.set("", for: .red, defaults: defaults)
        XCTAssertEqual(LabelNames.name(.red, defaults: defaults), "Red")
        XCTAssertNil(defaults.object(forKey: LabelNames.key))

        XCTAssertEqual(PhotoWords.typed("Madrid, street,, Madrid"), ["Madrid", "street"])
        XCTAssertEqual(PhotoWordsEditor.held([["Spain", "night"], ["spain"]]).map { "\($0.word) \($0.count)" }, ["night 1", "Spain 2"])
    }

    /// The catalogue's keyword counts come from its Folders' sidecars.
    func testTheCatalogueCountsItsKeywords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-words-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, words) in [("a.jpg", #"["Spain", "night"]"#), ("b.jpg", #"["spain"]"#), ("c.jpg", "[]")] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
            try Data(#"{"qlick": 1, "defaultsVersion": 1, "variants": [{"id": "v", "keywords": \#(words), "rating": 1}]}"#.utf8)
                .write(to: folder.appendingPathComponent(name + ".qlick"))
        }
        let stats = ProjectStore.stats(of: folder, store: SidecarStore(writes: false))
        XCTAssertEqual(stats.keywords["Spain"], 1)
        XCTAssertEqual(stats.keywords["spain"], 1)
        XCTAssertEqual(stats.keywords["night"], 1)
        let merged = PhotoWordsEditor.merged([("Spain", 2), ("night", 1)], listed: [["Rue"]])
        XCTAssertEqual(merged.map(\.word), ["Spain", "night", "Rue"])
    }
}
