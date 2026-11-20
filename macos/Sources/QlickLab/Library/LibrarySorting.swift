// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The order the photographs are shown in, as Lightroom's Sort: by when they were taken, their name, type, size,
/// rating, mark, whether they're developed or their shape; either way round. The folder's own order is by name.
struct LibrarySort: Codable, Equatable, Sendable {
    enum Key: String, Codable, CaseIterable, Sendable {
        case captureTime, fileName, fileType, fileSize, modified, rating, pick, label, edited, aspect, importDate, editDate, custom

        var title: String {
            switch self {
            case .captureTime: "Capture Time"
            case .fileName: "File Name"
            case .fileType: "File Type"
            case .fileSize: "File Size"
            case .modified: "Modified Date"
            case .rating: "Rating"
            case .pick: "Pick"
            case .label: "Colour Label"
            case .edited: "Developed"
            case .aspect: "Aspect Ratio"
            case .importDate: "Import Date"
            case .editDate: "Edit Date"
            case .custom: "Custom Order"
            }
        }

        /// The orders a list offers: Custom Order only in a Box or a Roll, where photographs are put in order by hand.
        static func offered(manual: Bool) -> [Key] { manual ? allCases : allCases.filter { $0 != .custom } }
    }

    var key = Key.fileName
    var ascending = true

    /// The folder's own order: nothing to sort.
    var natural: Bool { key == .fileName && ascending }

    private static let defaultsKey = "qlick.librarySort"
    /// Qlick Lab: the order of Boxes and Rolls, kept apart: Custom Order unless another is chosen there.
    static let boxKey = "qlick.boxSort"
    static func load(_ defaults: UserDefaults = .standard, key: String = defaultsKey, fallback: LibrarySort = LibrarySort()) -> LibrarySort {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LibrarySort.self, from: $0) } ?? fallback
    }
    func save(_ defaults: UserDefaults = .standard, key: String = defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

extension LabState {
    /// `items` in the sort's order. Ties keep the folder's order, so the order never shuffles.
    func sorted(_ items: [PhotoFile]) -> [PhotoFile] {
        let sort = self.sort
        // Custom Order is the Box's or Roll's own: the list is listed in it already.
        if sort.key == .custom { return openView?.holder != nil && !sort.ascending ? items.reversed() : items }
        // A folder is listed by name already; a Box or a Roll in its own order, so File Name sorts it.
        guard !sort.natural || openView?.holder != nil, items.count > 1 else { return items }
        let library = model.library
        // Qlick Lab: the import and edit dates come from each photograph's record (the index), worked out once.
        var dates: [URL: Date] = [:]
        if sort.key == .importDate || sort.key == .editDate {
            for item in items {
                let record = record(for: item.url)
                dates[item.url] = (sort.key == .importDate ? record.imported : record.editedAt) ?? .distantPast
            }
        }
        func compare(_ a: PhotoFile, _ b: PhotoFile) -> ComparisonResult {
            func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
            switch sort.key {
            case .fileName: return a.name.localizedStandardCompare(b.name)
            case .fileType: return order(a.url.pathExtension.lowercased(), b.url.pathExtension.lowercased())
            case .fileSize: return order(a.size ?? 0, b.size ?? 0)
            case .modified: return order(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .captureTime:
                return order(facts.known(a.url)?.date ?? a.modified ?? .distantPast, facts.known(b.url)?.date ?? b.modified ?? .distantPast)
            case .rating: return order(library.summary(for: a.url).rating, library.summary(for: b.url).rating)
            case .pick:
                func rank(_ flag: PhotoSidecar.Flag?) -> Int { flag == .pick ? 2 : flag == .reject ? 0 : 1 }
                return order(rank(library.summary(for: a.url).flag), rank(library.summary(for: b.url).flag))
            case .label:
                // As the labels are listed, red first; unlabelled photographs after them.
                return order(library.summary(for: a.url).label?.rank ?? ColorLabel.allCases.count, library.summary(for: b.url).label?.rank ?? ColorLabel.allCases.count)
            case .edited: return order(library.summary(for: a.url).edited ? 1 : 0, library.summary(for: b.url).edited ? 1 : 0)
            case .aspect:
                let ratios = model.aspects.ratios
                return order(ratios[a.url] ?? PhotoAspects.fallback, ratios[b.url] ?? PhotoAspects.fallback)
            case .importDate, .editDate:
                return order(dates[a.url] ?? .distantPast, dates[b.url] ?? .distantPast)
            case .custom: return .orderedSame
            }
        }
        if sort.key == .captureTime { readDates(items) }
        let indexed = items.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { x, y in
            var result = compare(x.1, y.1)
            if !sort.ascending { result = result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame }
            return result == .orderedSame ? x.0 < y.0 : result == .orderedAscending
        }.map(\.1)
    }

    /// Capture Time needs every file's date: read those not known yet, off the main thread.
    private func readDates(_ items: [PhotoFile]) {
        for item in items where facts.known(item.url) == nil { _ = facts.get(item.url) }
    }
}

/// The filters and the order, in one bar: the marks with their counts, the stars (at least, at most or exactly),
/// developed or not, and the sort. Under the grid and floating over the contact sheet; `\` shows and hides it.
struct LibraryFilterBar: View {
    let model: EditorModel
    /// Without its own pane of glass: in the grid's foot.
    var inline = false
    private var lab: LabState { model.lab }

    var body: some View {
        let counts = lab.counts
        let library = model.library
        HStack(spacing: 4) {
            chip("All", count: counts.total, on: library.filter.flags.isEmpty, mark: nil) {
                model.library.filter.flags = []
            }
            chip("Picks", count: counts.picks, on: library.filter.flags == [.pick], mark: .pick) { only(.pick) }
            chip("Rejects", count: counts.rejects, on: library.filter.flags == [.reject], mark: .reject) { only(.reject) }
            if counts.rejects > 0 {
                Button { lab.requestRemoveRejected() } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.dim)
                        .frame(width: 20, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.canDelete)
                .help("Remove Rejected Photos…")
                .accessibilityLabel("Remove Rejected Photos")
            }
            chip("Unmarked", count: counts.unmarked, on: library.filter.flags == [.unflagged], mark: nil) { only(.unflagged) }
            separator
            StarFilter(model: model)
            separator
            Button { model.library.filter.editedOnly.toggle() } label: {
                Text("Developed").font(Theme.caps(12, weight: library.filter.editedOnly ? .semibold : .regular))
                    .foregroundStyle(library.filter.editedOnly ? Theme.film : Theme.paper)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(library.filter.editedOnly ? Theme.paper : Color.white.opacity(0.001)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Only the photographs with a development of their own")
            separator
            LabelFilter(model: model)
            KeywordFilter(model: model)
            if library.filter.active {
                Button { model.library.filter = LibraryFilter() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain).help("Clear the filter (⌥⌘L)").padding(.horizontal, 4)
            }
            separator
            SortPicker(lab: lab)
            let selected = model.selection.selected.count
            if selected > 1 {
                separator
                Text("\(selected) selected").font(Theme.value(11.5)).foregroundStyle(Color(white: 0.8)).padding(.trailing, 8)
            }
        }
        .padding(inline ? 0 : 5)
        .modifier(BarGlass(on: !inline))
    }

    private var separator: some View { Divider().frame(height: 16).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4) }

    private func only(_ flag: LibraryFilter.Flag) {
        model.library.filter.flags = model.library.filter.flags == [flag] ? [] : [flag]
    }

    private func chip(_ title: String, count: Int, on: Bool, mark: PhotoSidecar.Flag?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let mark { MarkGlyph(flag: mark).frame(width: 15, height: 12) }
                Text(title).font(Theme.caps(12, weight: on ? .semibold : .regular))
                Text("\(count)").font(Theme.value(11.5)).opacity(0.65)
            }
            .foregroundStyle(on ? Theme.film : Theme.paper)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(on ? Theme.paper : Color.white.opacity(0.001)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct BarGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glass(Capsule()) } else { content }
    }
}

/// Five stars and how they count, as in Lightroom's filter bar: a click on a star filters by it, a second click
/// clears it; the sign before them chooses at least (≥), at most (≤) or exactly (=), or unrated.
private struct StarFilter: View {
    let model: EditorModel

    enum Relation: String, CaseIterable { case atLeast = "≥", atMost = "≤", exactly = "=" }

    var body: some View {
        let rating = model.library.filter.rating
        let (relation, stars) = Self.split(rating)
        HStack(spacing: 2) {
            Menu {
                ForEach(Relation.allCases, id: \.self) { choice in
                    Button {
                        set(choice, stars: max(stars, 1))
                    } label: {
                        Label(Self.words(choice), systemImage: choice == relation && stars > 0 ? "checkmark" : "")
                    }
                }
                Divider()
                Button("Unrated Only") { model.library.filter.rating = rating == .unrated ? .any : .unrated }
                Button("Any Rating") { model.library.filter.rating = .any }
            } label: {
                Text(rating == .unrated ? "0" : relation.rawValue)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.paper).frame(width: 18)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("At least, at most or exactly so many stars")
            ForEach(1...5, id: \.self) { star in
                Button {
                    if stars == star { model.library.filter.rating = .any } else { set(relation, stars: star) }
                } label: {
                    Image(systemName: star <= stars ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(star <= stars ? Theme.accent : Theme.dim)
                        .frame(width: 17, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(Self.words(relation)) \(star) \(star == 1 ? "star" : "stars")")
            }
        }
        .padding(.horizontal, 4)
    }

    private func set(_ relation: Relation, stars: Int) {
        model.library.filter.rating = switch relation {
        case .atLeast: .atLeast(stars)
        case .atMost: .atMost(stars)
        case .exactly: .exactly(stars)
        }
    }

    static func split(_ rating: LibraryFilter.Rating) -> (Relation, Int) {
        switch rating {
        case .any, .unrated: (.atLeast, 0)
        case .atLeast(let stars): (.atLeast, stars)
        case .atMost(let stars): (.atMost, stars)
        case .exactly(let stars): (.exactly, stars)
        }
    }

    static func words(_ relation: Relation) -> String {
        switch relation {
        case .atLeast: "At least"
        case .atMost: "At most"
        case .exactly: "Exactly"
        }
    }
}

/// "Sort: Capture Time ↑": the order and its direction.
struct SortPicker: View {
    let lab: LabState

    var body: some View {
        let sort = lab.sort
        HStack(spacing: 2) {
            Menu {
                ForEach(LibrarySort.Key.offered(manual: lab.openView?.holder != nil), id: \.self) { key in
                    Button { lab.sort.key = key } label: {
                        Label(key.title, systemImage: key == sort.key ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort").foregroundStyle(Theme.dim)
                    Text(sort.key.title).foregroundStyle(Theme.paper)
                }
                .font(Theme.caps(12))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("The order of the photographs")
            Button { lab.sort.ascending.toggle() } label: {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.paper)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sort.ascending ? "Ascending: click for descending" : "Descending: click for ascending")
        }
        .padding(.horizontal, 6)
    }
}

/// The colour labels in the filter bar: a click shows only that label's photographs, more clicks add others; the
/// menu at the end adds those without a label.
private struct LabelFilter: View {
    let model: EditorModel

    var body: some View {
        let filter = model.library.filter
        let counts = Dictionary(grouping: model.library.items.compactMap { model.library.summary(for: $0.url).label }, by: { $0 }).mapValues(\.count)
        HStack(spacing: 1) {
            ForEach(ColorLabel.allCases) { label in
                let on = filter.labels.contains(label)
                Button {
                    if on { model.library.filter.labels.remove(label) } else { model.library.filter.labels.insert(label) }
                } label: {
                    LabelDot(label: label, size: 10)
                        .opacity(on || (filter.labels.isEmpty && !filter.unlabelled) ? 1 : 0.35)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Theme.paper.opacity(on ? 0.9 : 0), lineWidth: 1.2))
                        .frame(width: 20, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(LabelNames.name(label)) label: \(counts[label] ?? 0)")
            }
            Button { model.library.filter.unlabelled.toggle() } label: {
                Image(systemName: "circle.dashed").font(.system(size: 10.5))
                    .foregroundStyle(filter.unlabelled ? Theme.paper : Theme.dim)
                    .frame(width: 20, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Without a label")
        }
        .padding(.horizontal, 2)
    }
}

/// Keyword ▾ in the filter bar: the keywords of what's listed, with their counts; one chosen shows only its photographs.
private struct KeywordFilter: View {
    let model: EditorModel

    var body: some View {
        let chosen = model.library.filter.keyword
        Menu {
            let held = PhotoWordsEditor.held(model.library.items.map { model.library.summary(for: $0.url).words.keywords })
            if held.isEmpty { Text("No keywords here yet") }
            ForEach(held, id: \.word) { entry in
                Button {
                    model.library.filter.keyword = chosen?.caseInsensitiveCompare(entry.word) == .orderedSame ? nil : entry.word
                } label: {
                    let title = "\(entry.word)  \(entry.count)"
                    if chosen?.caseInsensitiveCompare(entry.word) == .orderedSame { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if chosen != nil {
                Divider()
                Button("Any Keyword") { model.library.filter.keyword = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag").font(.system(size: 10.5))
                Text(chosen ?? "Keyword").lineLimit(1)
            }
            .font(Theme.caps(12, weight: chosen == nil ? .regular : .semibold))
            .foregroundStyle(chosen == nil ? Theme.paper : Theme.film)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(chosen == nil ? Color.white.opacity(0.001) : Theme.paper))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Only the photographs with a keyword")
    }
}

/// Over the filter bar: the search, which understands fields (`PhotoQuery`: `rating:>=3 film:portra iso:>800
/// date:2026-09`…), the period, film, camera and lens of what's listed, and Save as Smart Roll… for the whole filter.
struct LibraryFindBar: View {
    let model: EditorModel
    /// Without its own pane of glass: over the grid's foot.
    var inline = false
    private var lab: LabState { model.lab }
    @FocusState private var typing: Bool

    var body: some View {
        let filter = model.library.filter
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(filter.search.isEmpty ? Theme.dim : Theme.accent)
                TextField("Search, or rating:>=3 iso:>800…", text: Binding(get: { model.library.filter.search },
                                                                                             set: { model.library.filter.search = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($typing)
                    .onExitCommand { typing = false }
                if !filter.search.isEmpty {
                    Button { model.library.filter.search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.dim) }
                        .buttonStyle(.plain).help("Clear the search")
                }
            }
            .padding(.horizontal, 10).frame(width: 300, height: 24)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .help(LibraryFindBar.searchHelp)
            separator
            let facets = Facets(model: model)
            FacetMenu(title: "Period", symbol: "calendar", chosen: filter.period.map(Self.periodTitle), help: "Only the photographs taken then") {
                ForEach([7, 30, 365], id: \.self) { days in
                    choice("Last \(days) Days", on: filter.period == "last:\(days)") { model.library.filter.period = "last:\(days)" }
                }
                Divider()
                ForEach(facets.periods.years) { year in
                    Menu("\(year.title)  \(year.count)") {
                        choice("All of \(year.title)", on: filter.period == year.key) { model.library.filter.period = year.key }
                        Divider()
                        ForEach(year.children) { month in
                            choice("\(month.title)  \(month.count)", on: filter.period == month.key) { model.library.filter.period = month.key }
                        }
                    }
                }
                if filter.period != nil {
                    Divider()
                    Button("Any Time") { model.library.filter.period = nil }
                }
            }
            FacetMenu(title: "Film", symbol: "film", chosen: filter.film, help: "Only the photographs of a film: loaded in the camera or developed on") {
                values(facets.films, chosen: filter.film) { model.library.filter.film = $0 }
            }
            FacetMenu(title: "Camera", symbol: "camera", chosen: filter.camera, help: "Only the photographs of a camera") {
                values(facets.cameras, chosen: filter.camera) { model.library.filter.camera = $0 }
            }
            FacetMenu(title: "Lens", symbol: "camera.aperture", chosen: filter.lens, help: "Only the photographs of a lens") {
                values(facets.lenses, chosen: filter.lens) { model.library.filter.lens = $0 }
            }
            separator
            Button { lab.saveFilterAsSmartRoll() } label: {
                Label("Save as Smart Roll…", systemImage: SmartRollEditor.symbol).font(Theme.caps(12))
                    .foregroundStyle(filter.active ? Theme.paper : Theme.dim)
                    .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!filter.active)
            .help("A Smart Roll with these filters and this search: it finds them again across the whole catalog")
        }
        .padding(inline ? 0 : 5)
        .modifier(FindGlass(on: !inline))
    }

    static let searchHelp = """
    Words find file names, titles, captions, keywords, cameras, lenses, films and folders. Fields: rating:>=3, pick, reject, \
    label:red, keyword:usa, film:portra, camera:m11, lens:35, iso:>800, aperture:<2.8, shutter:1/250, date:2026-09, \
    imported:30d, title:…, name:…, type:dng, developed. Quotes keep words together; a minus leaves out.
    """

    static func periodTitle(_ period: String) -> String {
        if period.hasPrefix("last:") { return "Last \(period.dropFirst(5)) Days" }
        let parts = period.split(separator: "-")
        guard parts.count > 1, let start = SmartRule.period(period)?.start else { return period }
        return parts.count == 2 ? start.formatted(.dateTime.month(.abbreviated).year().locale(Locale(identifier: "en_GB")))
            : start.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB")))
    }

    private var separator: some View { Divider().frame(height: 16).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4) }

    @ViewBuilder private func choice(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { if on { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }

    @ViewBuilder private func values(_ list: [(name: String, count: Int)], chosen: String?, set: @escaping (String?) -> Void) -> some View {
        if list.isEmpty { Text("None here") }
        ForEach(list, id: \.name) { entry in
            choice("\(entry.name)  \(entry.count)", on: chosen?.caseInsensitiveCompare(entry.name) == .orderedSame) {
                set(chosen?.caseInsensitiveCompare(entry.name) == .orderedSame ? nil : entry.name)
            }
        }
        if chosen != nil {
            Divider()
            Button("Any") { set(nil) }
        }
    }

    /// The periods, films, cameras and lenses of what's listed, with their counts.
    @MainActor struct Facets {
        var periods = DateTree(years: [])
        var films: [(name: String, count: Int)] = []
        var cameras: [(name: String, count: Int)] = []
        var lenses: [(name: String, count: Int)] = []

        init(model: EditorModel) {
            let records = model.library.items.filter { $0.url.variantID == nil }.map { model.lab.record(for: $0.url) }
            periods = DateTree.build(records.compactMap(\.captured))
            func counted(_ names: [String]) -> [(name: String, count: Int)] {
                var counts: [String: (name: String, count: Int)] = [:]
                for name in names where !name.isEmpty {
                    let key = name.lowercased()
                    counts[key] = (counts[key]?.name ?? name, (counts[key]?.count ?? 0) + 1)
                }
                return counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            // A development is named by its stock's name, not its id.
            films = counted(records.flatMap { Array(Set([$0.filmLoaded] + $0.filmNames)) })
            cameras = counted(records.compactMap(\.camera))
            lenses = counted(records.compactMap(\.lens))
        }
    }
}

/// A menu of the find bar: its title, or the value chosen (then lit).
private struct FacetMenu<Items: View>: View {
    let title: String
    let symbol: String
    let chosen: String?
    let help: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(chosen ?? title).lineLimit(1).frame(maxWidth: 140)
            }
            .font(Theme.caps(12, weight: chosen == nil ? .regular : .semibold))
            .foregroundStyle(chosen == nil ? Theme.paper : Theme.film)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(chosen == nil ? Color.white.opacity(0.001) : Theme.paper))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(help)
    }
}

private struct FindGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glass(Capsule()) } else { content }
    }
}
