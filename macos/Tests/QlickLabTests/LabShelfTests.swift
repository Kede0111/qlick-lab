// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// The Lab's shelf: one system of favourites and hidden films, papers and recipes, by identifier.
@MainActor final class LabShelfTests: XCTestCase {
    private func stock(_ id: String, paper: Bool = false, fotufilm: Bool = false, datasheet: Bool = true) -> Stock {
        Stock(.object(["id": .string(id), "name": .string(id.capitalized), "paper": .bool(paper), "positive": .bool(false), "bw": .bool(false),
                       "target_print": .string(paper ? "" : "endura"), "development_times": .array([]),
                       "fotufilm": .bool(fotufilm), "manufacturer_data": .bool(datasheet)]))
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = TestDefaults.name(name)
        return UserDefaults(suiteName: suite)!
    }

    func testWhatWasKeptBeforeTheShelfComesInOnce() throws {
        let defaults = defaults("qlick-shelf-former")
        defaults.set(["kodak_gold_200"], forKey: "favoriteFilms")
        defaults.set(["endura"], forKey: "favoritePapers")
        defaults.set(["trix", "supra", "kodak_gold_200"], forKey: "qlick.favouriteStocks")
        defaults.set(["Portra Warm"], forKey: "qlick.favouriteRecipes")
        defaults.set(FotufilmFilms.datasheets.rawValue, forKey: FotufilmFilms.key)
        let shelf = LabShelf(storage: .defaults(defaults, key: LabShelf.defaultsKey), defaults: defaults)
        XCTAssertEqual(shelf.favouriteIDs(.film), ["kodak_gold_200"])
        XCTAssertEqual(shelf.favouriteIDs(.paper), ["endura"])

        shelf.adopt(stocks: [stock("kodak_gold_200"), stock("trix"), stock("supra", paper: true), stock("endura", paper: true),
                             stock("sample", fotufilm: true, datasheet: false), stock("measured", fotufilm: true)])
        XCTAssertEqual(shelf.favouriteIDs(.film), ["kodak_gold_200", "trix"])
        XCTAssertEqual(shelf.favouriteIDs(.paper), ["endura", "supra"], "a paper starred in the Stocks room is a paper")
        XCTAssertTrue(shelf.isHidden(.film, "sample"), "Fotufilm films › From datasheets left it out")
        XCTAssertFalse(shelf.isHidden(.film, "measured"))

        var portra = PresetFile(url: URL(fileURLWithPath: "/tmp/Portra Warm.json"), size: 1, modified: .distantPast)
        portra.shelfID = "A1"
        shelf.adopt(recipes: [portra])
        XCTAssertTrue(shelf.isFavourite(.recipe, "A1"), "a recipe starred by name is starred by its id")

        // Read again: kept, and the former keys aren't read a second time.
        defaults.set(["other"], forKey: "favoriteFilms")
        let again = LabShelf(storage: .defaults(defaults, key: LabShelf.defaultsKey), defaults: defaults)
        XCTAssertEqual(again.favouriteIDs(.film), ["kodak_gold_200", "trix"])
        XCTAssertTrue(again.isHidden(.film, "sample"))
        XCTAssertTrue(again.isFavourite(.recipe, "A1"))
    }

    func testAStarAndAHidingAreOneSystemAndForgottenWithTheRecipe() {
        let shelf = LabShelf(storage: .memory, defaults: defaults("qlick-shelf-one"))
        XCTAssertEqual(shelf.favouriteIDs(.film), LabShelf.firstFavouriteFilms, "new photographers start with four films")
        let previews = Previews(defaults: defaults("qlick-shelf-previews"), shelf: shelf)
        previews.toggleFavorite("trix", paper: false)
        XCTAssertTrue(shelf.isFavourite(.film, "trix"), "the tray's star is the shelf's")
        shelf.toggleFavourite(.recipe, "R")
        shelf.setHidden(.recipe, "R", true)
        XCTAssertTrue(shelf.isHidden(.recipe, "R"))
        shelf.forget(recipe: "R")
        XCTAssertFalse(shelf.isFavourite(.recipe, "R"))
        XCTAssertFalse(shelf.isHidden(.recipe, "R"))
    }

    func testARecipeKeepsItsIdentifierThroughARename() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PresetLibrary(folder: folder)
        _ = try await library.add(Data("{}".utf8), name: "Portra")
        _ = try await library.add(Data("{}".utf8), name: "Tri-X")
        let listed = try await library.list()
        let id = try XCTUnwrap(listed.first { $0.name == "Portra" }?.shelfID)
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotEqual(id, listed.first { $0.name == "Tri-X" }?.shelfID)
        let again = try await library.list()
        XCTAssertEqual(again.first { $0.name == "Portra" }?.shelfID, id, "the same each time it's listed")

        let portra = try XCTUnwrap(listed.first { $0.name == "Portra" })
        let renamed = try await library.rename(portra, to: "Portra Warm")
        XCTAssertEqual(renamed.shelfID, id)
        let afterRename = try await library.list()
        XCTAssertEqual(afterRename.first { $0.name == "Portra Warm" }?.shelfID, id)

        // A file copied in by hand gets one of its own.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("By Hand.json"))
        let byHand = try await library.list().first { $0.name == "By Hand" }
        XCTAssertEqual(byHand?.shelfID.count, 36)
    }

    func testTheShelfFiltersSearchesAndSorts() {
        func preset(_ name: String, _ days: Double, _ id: String) -> PresetFile {
            var file = PresetFile(url: URL(fileURLWithPath: "/tmp/\(name).json"), size: 1, modified: Date(timeIntervalSince1970: days * 86_400))
            file.shelfID = id
            return file
        }
        let presets = [preset("Gold Summer", 3, "g"), preset("Portra Warm", 1, "p"), preset("Ektar Punch", 2, "e")]
        let films = ["g": "Kodak Gold 200", "p": "Kodak Portra 400", "e": "Kodak Ektar 100"]
        func shown(_ filter: ShelfFilter, _ query: String = "", _ sort: RecipeSort = .custom) -> [String] {
            ShelfRules.recipes(presets, filter: filter, query: query, sort: sort, favourite: { $0.shelfID == "p" },
                               hidden: { $0.shelfID == "e" }) { films[$0.shelfID] ?? "" }.map(\.name)
        }
        XCTAssertEqual(shown(.all), ["Gold Summer", "Portra Warm"], "a hidden recipe leaves the list")
        XCTAssertEqual(shown(.hidden), ["Ektar Punch"], "and is found under Hidden")
        XCTAssertEqual(shown(.favourites), ["Portra Warm"])
        XCTAssertEqual(shown(.all, "portra 400"), ["Portra Warm"], "the film's name is searched too")
        XCTAssertEqual(shown(.all, "", .name), ["Gold Summer", "Portra Warm"])
        XCTAssertEqual(shown(.all, "", .date), ["Gold Summer", "Portra Warm"], "the newest first")
        XCTAssertEqual(shown(.all, "", .film), ["Gold Summer", "Portra Warm"])

        let stocks = [stock("velvia_50"), stock("gold_200"), stock("tri_x_400")]
        XCTAssertEqual(ShelfRules.stocks(stocks, sort: .name) { _ in nil }.map(\.id), ["gold_200", "tri_x_400", "velvia_50"])
        XCTAssertEqual(ShelfRules.stocks(stocks, sort: .speed) { Int($0.id.split(separator: "_").last ?? "") }.map(\.id), ["velvia_50", "gold_200", "tri_x_400"])
    }

    func testAHiddenStockLeavesTheListsButNotThePhotographUsingIt() {
        let model = EditorModel()
        defer { model.shutdown() }
        let films = model.films
        guard let first = films.first, films.count > 1 else { return }
        model.shelf.setHidden(.film, first.id, true)
        XCTAssertFalse(model.listedFilms(keeping: []).contains { $0.id == first.id })
        XCTAssertTrue(model.listedFilms(keeping: [first.id]).contains { $0.id == first.id }, "the film in use stays listed")
        model.shelf.setHidden(.film, first.id, false)
    }
}
