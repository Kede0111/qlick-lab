// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The order the photographs are shown in, as Lightroom's Sort: by when they were taken, their name, type, size,
/// rating, mark, whether they're developed or their shape; either way round. The folder's own order is by name.
struct LibrarySort: Codable, Equatable, Sendable {
    enum Key: String, Codable, CaseIterable, Sendable {
        case captureTime, fileName, fileType, fileSize, modified, rating, pick, edited, aspect

        var title: String {
            switch self {
            case .captureTime: "Capture Time"
            case .fileName: "File Name"
            case .fileType: "File Type"
            case .fileSize: "File Size"
            case .modified: "Modified Date"
            case .rating: "Rating"
            case .pick: "Pick"
            case .edited: "Developed"
            case .aspect: "Aspect Ratio"
            }
        }
    }

    var key = Key.fileName
    var ascending = true

    /// The folder's own order: nothing to sort.
    var natural: Bool { key == .fileName && ascending }

    private static let defaultsKey = "qlick.librarySort"
    static func load(_ defaults: UserDefaults = .standard) -> LibrarySort {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(LibrarySort.self, from: $0) } ?? LibrarySort()
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension LabState {
    /// `items` in the sort's order. Ties keep the folder's order, so the order never shuffles.
    func sorted(_ items: [PhotoFile]) -> [PhotoFile] {
        let sort = self.sort
        guard !sort.natural, items.count > 1 else { return items }
        let library = model.library
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
            case .edited: return order(library.summary(for: a.url).edited ? 1 : 0, library.summary(for: b.url).edited ? 1 : 0)
            case .aspect:
                let ratios = model.aspects.ratios
                return order(ratios[a.url] ?? PhotoAspects.fallback, ratios[b.url] ?? PhotoAspects.fallback)
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
            chip("Unmarked", count: counts.unmarked, on: library.filter.flags == [.unflagged], mark: nil) { only(.unflagged) }
            separator
            StarFilter(model: model)
            separator
            Button { model.library.filter.editedOnly.toggle() } label: {
                Text("Developed").font(Q.label(12, weight: library.filter.editedOnly ? .semibold : .regular))
                    .foregroundStyle(library.filter.editedOnly ? Q.black : Q.text)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(library.filter.editedOnly ? Q.text : Color.white.opacity(0.001)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Only the photographs with a development of their own")
            if library.filter.active {
                Button { model.library.filter = LibraryFilter() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Q.dim)
                }
                .buttonStyle(.plain).help("Clear the filter (⌥⌘L)").padding(.horizontal, 4)
            }
            separator
            SortPicker(lab: lab)
            let selected = model.selection.selected.count
            if selected > 1 {
                separator
                Text("\(selected) selected").font(Q.value(11.5)).foregroundStyle(Color(white: 0.8)).padding(.trailing, 8)
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
                Text(title).font(Q.label(12, weight: on ? .semibold : .regular))
                Text("\(count)").font(Q.value(11.5)).opacity(0.65)
            }
            .foregroundStyle(on ? Q.black : Q.text)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(on ? Q.text : Color.white.opacity(0.001)))
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
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Q.text).frame(width: 18)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("At least, at most or exactly so many stars")
            ForEach(1...5, id: \.self) { star in
                Button {
                    if stars == star { model.library.filter.rating = .any } else { set(relation, stars: star) }
                } label: {
                    Image(systemName: star <= stars ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(star <= stars ? Q.red : Q.dim)
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
                ForEach(LibrarySort.Key.allCases, id: \.self) { key in
                    Button { lab.sort.key = key } label: {
                        Label(key.title, systemImage: key == sort.key ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort").foregroundStyle(Q.dim)
                    Text(sort.key.title).foregroundStyle(Q.text)
                }
                .font(Q.label(12))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("The order of the photographs")
            Button { lab.sort.ascending.toggle() } label: {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Q.text)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sort.ascending ? "Ascending: click for descending" : "Descending: click for ascending")
        }
        .padding(.horizontal, 6)
    }
}
