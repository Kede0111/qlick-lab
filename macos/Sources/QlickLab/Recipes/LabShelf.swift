// Qlick Lab — GPL-3.0-only.
import Foundation
import Observation

/// The Lab's shelf: which films, papers and recipes are favourites and which are hidden, one system for the three,
/// by identifier (a stock's id, a recipe's own `shelfID`, which follows it through a rename). A star given anywhere
/// shows everywhere: the tray, the menus, the Stocks and Recipes rooms, Compare, Import.
///
/// A hidden one leaves the trays, the menus, Compare and Import; it stays on the shelf, under Hidden, to show again.
/// Only the lists: a photograph developed with it keeps it.
///
/// Kept in `Shelf.json` beside the Presets folder (top-level key `qlick`); in a defaults key or nowhere for tests.
@MainActor @Observable final class LabShelf {
    enum Kind: String, Codable, Sendable, CaseIterable { case film, paper, recipe }

    /// Starred, in the order starred ("film:kodak_portra_400", "recipe:<UUID>").
    private(set) var favourites: [String] = []
    private(set) var hidden: Set<String> = []

    /// What was kept before the shelf, to sort out once the stocks and recipes are known.
    private struct Pending: Codable, Equatable {
        /// Stocks starred in the Stocks room, film or paper not known yet.
        var stocks: [String] = []
        /// Recipes starred by name.
        var recipeNames: [String] = []
        /// The former Settings › Films › Fotufilm films choice, when it hid some.
        var fotufilm: String?
        var isEmpty: Bool { stocks.isEmpty && recipeNames.isEmpty && fotufilm == nil }
    }
    @ObservationIgnored private var pending = Pending()

    private struct File: Codable {
        var qlick = 1
        var favourites: [String]
        var hidden: [String]
        var pending: Pending?
    }

    enum Storage {
        case file(URL)
        case defaults(UserDefaults, key: String)
        /// Kept nowhere: tests.
        case memory
    }
    @ObservationIgnored private let storage: Storage

    static let fileURL = AppDataLocations.supportDirectory.appendingPathComponent("Shelf.json")
    static let defaultsKey = "qlick.shelf"

    /// Starred for new photographers, as before the shelf: four films everyone knows.
    static let firstFavouriteFilms = ["kodak_gold_200", "kodak_portra_400", "kodak_ektar_100", "fujifilm_c200"]

    /// `defaults` is where the marks kept before the shelf are read from, once.
    init(storage: Storage = .file(LabShelf.fileURL), defaults: UserDefaults = .standard) {
        self.storage = storage
        if let file = Self.read(storage) {
            favourites = file.favourites
            hidden = Set(file.hidden)
            pending = file.pending ?? Pending()
        } else {
            adoptFormer(defaults)
            save()
        }
    }

    /// The shelf the app keeps: in `Shelf.json`; nowhere while testing.
    static func forApp() -> LabShelf { LabShelf(storage: NSClassFromString("XCTestCase") == nil ? .file(fileURL) : .memory) }

    static func key(_ kind: Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    func isFavourite(_ kind: Kind, _ id: String) -> Bool { favourites.contains(Self.key(kind, id)) }
    func isHidden(_ kind: Kind, _ id: String) -> Bool { hidden.contains(Self.key(kind, id)) }

    /// Stars it (last among the favourites) or takes its star off.
    func toggleFavourite(_ kind: Kind, _ id: String) {
        let key = Self.key(kind, id)
        if let index = favourites.firstIndex(of: key) { favourites.remove(at: index) } else { favourites.append(key) }
        save()
    }

    func setHidden(_ kind: Kind, _ id: String, _ hide: Bool) {
        let key = Self.key(kind, id)
        guard hidden.contains(key) != hide else { return }
        if hide { hidden.insert(key) } else { hidden.remove(key) }
        save()
    }

    /// The starred ids of one kind, in the order starred. Ids no longer there are kept, in case they come back.
    func favouriteIDs(_ kind: Kind) -> [String] {
        let prefix = kind.rawValue + ":"
        return favourites.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    func hiddenCount(_ kind: Kind, among ids: [String]) -> Int { ids.filter { isHidden(kind, $0) }.count }

    // MARK: What was kept before

    /// The tray's favourite films and papers, the Stocks room's, the favourite recipes by name, and the Fotufilm
    /// films setting.
    private func adoptFormer(_ defaults: UserDefaults) {
        let films = defaults.stringArray(forKey: "favoriteFilms") ?? Self.firstFavouriteFilms
        let papers = defaults.stringArray(forKey: "favoritePapers") ?? []
        favourites = films.map { Self.key(.film, $0) } + papers.map { Self.key(.paper, $0) }
        let known = Set(films + papers)
        pending.stocks = (defaults.stringArray(forKey: "qlick.favouriteStocks") ?? []).filter { !known.contains($0) }
        pending.recipeNames = defaults.stringArray(forKey: "qlick.favouriteRecipes") ?? []
        if let fotufilm = defaults.string(forKey: FotufilmFilms.key), fotufilm != FotufilmFilms.all.rawValue { pending.fotufilm = fotufilm }
    }

    /// Once the stocks are known: the Stocks room's stars find their kind, and the films the former Fotufilm films
    /// setting left out are hidden.
    func adopt(stocks: [Stock]) {
        guard !stocks.isEmpty, !pending.stocks.isEmpty || pending.fotufilm != nil else { return }
        for id in pending.stocks {
            guard let stock = stocks.first(where: { $0.id == id }) else { continue }
            let key = Self.key(stock.paper ? .paper : .film, id)
            if !favourites.contains(key) { favourites.append(key) }
        }
        pending.stocks = []
        if let choice = pending.fotufilm.flatMap(FotufilmFilms.init) {
            for stock in stocks where !stock.paper && !choice.lists(stock) { hidden.insert(Self.key(.film, stock.id)) }
        }
        pending.fotufilm = nil
        save()
    }

    /// Once the recipes are listed: the recipes starred by name are starred by their own id.
    func adopt(recipes: [PresetFile]) {
        guard !pending.recipeNames.isEmpty, !recipes.isEmpty else { return }
        for name in pending.recipeNames {
            guard let recipe = recipes.first(where: { PresetName.key($0.name) == PresetName.key(name) }), !recipe.shelfID.isEmpty else { continue }
            let key = Self.key(.recipe, recipe.shelfID)
            if !favourites.contains(key) { favourites.append(key) }
        }
        pending.recipeNames = []
        save()
    }

    /// A recipe deleted: its marks go with it.
    func forget(recipe id: String) {
        let key = Self.key(.recipe, id)
        guard favourites.contains(key) || hidden.contains(key) else { return }
        favourites.removeAll { $0 == key }
        hidden.remove(key)
        save()
    }

    // MARK: Storage

    private static func read(_ storage: Storage) -> File? {
        let data: Data?
        switch storage {
        case .file(let url): data = try? Data(contentsOf: url)
        case .defaults(let defaults, let key): data = defaults.data(forKey: key)
        case .memory: data = nil
        }
        return data.flatMap { try? JSONDecoder().decode(File.self, from: $0) }
    }

    private func save() {
        let file = File(favourites: favourites, hidden: hidden.sorted(), pending: pending.isEmpty ? nil : pending)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        switch storage {
        case .file(let url):
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        case .defaults(let defaults, let key): defaults.set(data, forKey: key)
        case .memory: break
        }
    }
}

/// What the Recipes and Stocks rooms show of the shelf: what's listed (hidden ones aside), the favourites, or the
/// hidden ones, to show them again.
enum ShelfFilter: String, CaseIterable, Sendable {
    case all, favourites, hidden
    var title: String {
        switch self {
        case .all: "All"
        case .favourites: "Favourites"
        case .hidden: "Hidden"
        }
    }

    func keeps(favourite: Bool, hidden: Bool) -> Bool {
        switch self {
        case .all: !hidden
        case .favourites: favourite && !hidden
        case .hidden: hidden
        }
    }
}

/// The order of the recipes on the shelf.
enum RecipeSort: String, CaseIterable, Sendable {
    /// The photographer's own order, as dragged in the Recipes room.
    case custom, name, film, date
    var title: String {
        switch self {
        case .custom: "Custom Order"
        case .name: "Name"
        case .film: "Film"
        case .date: "Date Changed"
        }
    }
    static let key = "qlick.recipeSort"
}

/// The order of the stocks on the shelf.
enum StockSort: String, CaseIterable, Sendable {
    /// As the engine's catalogue lists them: by maker, then name.
    case catalogue, name, speed
    var title: String {
        switch self {
        case .catalogue: "Maker"
        case .name: "Name"
        case .speed: "Speed"
        }
    }
    static let key = "qlick.stockSort"
}

enum ShelfRules {
    /// The recipes shown: filtered, searched (name and film, every word), sorted. `film` names a recipe's film.
    static func recipes(_ presets: [PresetFile], filter: ShelfFilter, query: String, sort: RecipeSort,
                        favourite: (PresetFile) -> Bool, hidden: (PresetFile) -> Bool, film: (PresetFile) -> String) -> [PresetFile] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = presets.filter { preset in
            filter.keeps(favourite: favourite(preset), hidden: hidden(preset))
                && words.allSatisfy { "\(preset.name) \(film(preset))".localizedStandardContains($0) }
        }
        func byName(_ a: PresetFile, _ b: PresetFile) -> Bool { PresetName.key(a.name) < PresetName.key(b.name) }
        switch sort {
        case .custom: return kept
        case .name: return kept.sorted(by: byName)
        case .film: return kept.sorted { film($0).localizedStandardCompare(film($1)) == .orderedSame ? byName($0, $1) : film($0).localizedStandardCompare(film($1)) == .orderedAscending }
        case .date: return kept.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : byName($0, $1) }
        }
    }

    static func stocks(_ stocks: [Stock], sort: StockSort, speed: (Stock) -> Int?) -> [Stock] {
        switch sort {
        case .catalogue: return stocks
        case .name: return stocks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .speed: return stocks.sorted { (speed($0) ?? Int.max, $0.name) < (speed($1) ?? Int.max, $1.name) }
        }
    }
}
