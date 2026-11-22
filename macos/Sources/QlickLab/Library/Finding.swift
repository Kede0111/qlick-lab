// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// What the lab works out from the index and keeps until it changes: the counts and lists of the sidebar's fixed
/// entries, the By Date tree, each Smart Roll's photographs.
struct FindingCache {
    var stamp: Int?
    var picks: [String] = []
    var days: DateTree = DateTree(years: [])
    var smart: [RuleGroup: [String]] = [:]
    var lastImport: [String]?
    var lastImportDate: Date?
    var stockNames: [String: String]?
}

/// The photographs of the catalogue by the day they were taken: years, their months, their days, with counts.
struct DateTree: Equatable, Sendable {
    struct Node: Identifiable, Equatable, Sendable {
        /// `2026`, `2026-09`, `2026-09-19`.
        var key: String
        var count: Int
        var children: [Node] = []
        var id: String { key }

        /// How the sidebar names it: the year, the month's name, the day of the month with its weekday.
        var title: String {
            let parts = key.split(separator: "-")
            guard let start = SmartRule.period(key)?.start else { return key }
            switch parts.count {
            case 2: return start.formatted(.dateTime.month(.wide).locale(Locale(identifier: "en_GB")))
            case 3: return start.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "en_GB")))
            default: return key
            }
        }
    }
    var years: [Node]

    /// Newest first. Each photograph counts on its capture day (its file's date without one).
    static func build(_ dates: [Date], calendar: Calendar = .current) -> DateTree {
        var days: [String: Int] = [:]
        for date in dates {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            days[String(format: "%04d-%02d-%02d", year, month, day), default: 0] += 1
        }
        var years: [Node] = []
        for (yearKey, yearDays) in Dictionary(grouping: days.keys, by: { String($0.prefix(4)) }).sorted(by: { $0.key > $1.key }) {
            var months: [Node] = []
            for (monthKey, monthDays) in Dictionary(grouping: yearDays, by: { String($0.prefix(7)) }).sorted(by: { $0.key > $1.key }) {
                let nodes = monthDays.sorted(by: >).map { Node(key: $0, count: days[$0] ?? 0) }
                months.append(Node(key: monthKey, count: nodes.reduce(0) { $0 + $1.count }, children: nodes))
            }
            years.append(Node(key: yearKey, count: months.reduce(0) { $0 + $1.count }, children: months))
        }
        return DateTree(years: years)
    }
}

/// A Smart Roll being made or changed in the rule editor.
struct SmartRollDraft: Identifiable {
    let id = UUID()
    /// The Smart Roll changed, nil for a new one.
    var editing: (roll: UUID, box: UUID)?
    var name: String
    var rules: RuleGroup
    /// The Box it goes in; nil: the Box “Smart Rolls”, made if it isn't there.
    var box: UUID?
}

extension LabState {
    static let smartRollsBoxName = "Smart Rolls"

    // MARK: Setting up

    /// The index follows the catalogue: its Archives' folders, the photographs removed, the marks on screen.
    func setUpFinding() {
        catalog.inputs = { [weak self] in
            guard let self else { return nil }
            var seen: Set<String> = []
            let folders = projects.projects.flatMap { self.projects.photoFolders(of: $0) }.filter { seen.insert($0.labStandardized.path).inserted }
            return CatalogIndex.Inputs(folders: folders, store: model.sidecarLookup?.store ?? model.sidecars, imported: importer.ledger.importDates())
        }
        catalog.changed = { [weak self] in self?.indexChanged() }
        projects.smartFrames = { [weak self] rules in self?.smartFrames(rules) ?? [] }
        projects.listedFrames = { [weak self] view in self?.listedFrames(view) ?? [] }
        model.library.recordFilter = { [weak self] item, rules in
            guard let self else { return true }
            return rules.matches(self.record(for: item))
        }
        catalog.open(catalog: projects.directory, cache: NSClassFromString("XCTestCase") == nil)
        followCatalogue()
        followSummaries()
    }

    /// What changes the index's folders: the Archives, their trees on disk, what's removed, another catalogue.
    private func followCatalogue() {
        withObservationTracking {
            _ = projects.projects; _ = projects.folders.trees; _ = projects.removed; _ = projects.directory
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.catalogDirectory != self.projects.directory.labStandardized.path {
                    self.catalogDirectory = self.projects.directory.labStandardized.path
                    self.catalog.open(catalog: self.projects.directory, cache: NSClassFromString("XCTestCase") == nil)
                }
                self.catalog.refresh()
                self.followCatalogue()
            }
        }
        if catalogDirectory == nil { catalogDirectory = projects.directory.labStandardized.path; catalog.refresh(after: .milliseconds(300)) }
    }

    /// The marks given on screen go to the index at once; what they don't say (films, edit dates) a moment after.
    private func followSummaries() {
        withObservationTracking {
            _ = model.library.summaries
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.catalog.adopt(self.model.library.summaries)
                self.catalog.refresh(after: .seconds(3))
                self.followSummaries()
            }
        }
    }

    /// The index read again found changes: a list drawn from it that's open is listed again.
    private func indexChanged() {
        switch openView {
        case .all?, .lastImport?, .picks?, .day?, .found?: libraryChanged()
        case .roll(let id, let box)? where projects.boxRoll(id, in: box)?.roll.isSmart == true: libraryChanged()
        case .box?: libraryChanged()
        default: break
        }
    }

    /// A label as the search reads it: its colour, or the name given to it in Settings.
    nonisolated static func labelWord(_ word: String) -> ColorLabel? {
        ColorLabel(word: word) ?? ColorLabel.allCases.first { LabelNames.name($0).caseInsensitiveCompare(word.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    /// Shows on the contact sheet the photographs the library's search finds.
    func openFound(_ query: String) {
        foundQuery = query
        open(.found)
    }

    // MARK: Where the lab is

    /// The fixed entries' names: their own, or By Date › 2026 › September › Sat 19 for a day.
    static func fixedTitle(_ view: LabView) -> String? {
        switch view {
        case .all: "All Photographs"
        case .lastImport: "Last Import"
        case .picks: "Picks"
        case .found: "Found"
        case .day(let key): DateTree.Node(key: key, count: 0).title
        default: nil
        }
    }

    func fixedCrumbs(_ view: LabView) -> [Crumb]? {
        guard case .day(let key) = view else { return Self.fixedTitle(view).map { [Crumb(text: $0, target: .view(view))] } }
        let parts = key.split(separator: "-").map(String.init)
        var crumbs: [Crumb] = []
        for depth in 1...parts.count {
            let partial = parts.prefix(depth).joined(separator: "-")
            crumbs.append(Crumb(text: Self.fixedTitle(.day(partial)) ?? partial, target: .view(.day(partial))))
        }
        if parts.count == 3, let date = SmartRule.period(key)?.start {
            crumbs[crumbs.count - 1].text = date.formatted(.dateTime.weekday(.wide).day().locale(Locale(identifier: "en_GB")))
        }
        return crumbs
    }

    // MARK: Records

    /// What the rules know of a folder: its Archive's name, the film of its card, when it joined the Archive.
    struct FolderFacts { var archive = ""; var film = ""; var added: Date? }

    /// The record of a photograph or duplicate: the index's, with its marks as the library has them now; for a
    /// photograph outside every Archive, what its file says (read once, off the main thread).
    func record(for item: URL) -> PhotoRecord {
        let file = item.photoFile
        let path = file.labStandardized.path
        var folders: [String: FolderFacts] = [:]
        var record = catalog.photos[path].map { record(of: $0, folders: &folders) } ?? {
            var record = PhotoRecord(path: path)
            if let facts = facts.get(file) { fill(&record, facts: facts) }
            let folder = folderFacts((path as NSString).deletingLastPathComponent, memo: &folders)
            record.filmLoaded = folder.film; record.archive = folder.archive; record.imported = folder.added
            return record
        }()
        if let summary = model.library.summaries[item] {
            record.rating = summary.rating; record.flag = summary.flag; record.words = summary.words; record.edited = summary.edited
        }
        return record
    }

    private func fill(_ record: inout PhotoRecord, facts: FrameFacts) {
        record.captured = facts.date; record.camera = facts.camera; record.lens = facts.lens
        record.iso = facts.iso; record.exposure = facts.exposure; record.aperture = facts.aperture; record.focalLength = facts.focalLength
        record.width = facts.pixels.map { Double($0.width) }; record.height = facts.pixels.map { Double($0.height) }
    }

    func record(of photo: IndexedPhoto, folders: inout [String: FolderFacts]) -> PhotoRecord {
        var record = PhotoRecord(path: photo.path)
        record.rating = photo.rating
        record.flag = photo.flag.flatMap(PhotoSidecar.Flag.init(rawValue:))
        record.words = PhotoWords(label: photo.label.flatMap(ColorLabel.init(rawValue:)), keywords: photo.keywords, title: photo.title, caption: photo.caption)
        record.edited = photo.edited
        let names = stockNames
        record.filmsDeveloped = photo.films + photo.films.compactMap { names[$0] }
        record.filmNames = photo.films.map { names[$0] ?? $0 }
        record.recipe = photo.recipe
        record.camera = photo.camera; record.lens = photo.lens
        record.iso = photo.iso; record.exposure = photo.exposure; record.aperture = photo.aperture; record.focalLength = photo.focalLength
        record.width = photo.width; record.height = photo.height
        record.captured = photo.captured ?? photo.modified
        record.editedAt = photo.editedAt
        let folder = folderFacts((photo.path as NSString).deletingLastPathComponent, memo: &folders)
        record.filmLoaded = folder.film; record.archive = folder.archive
        record.imported = catalog.imported(photo.path) ?? folder.added
        return record
    }

    private func folderFacts(_ path: String, memo: inout [String: FolderFacts]) -> FolderFacts {
        if let known = memo[path] { return known }
        var facts = FolderFacts()
        // The deepest Folder holding it, both paths spelled alike (a link such as /tmp and /private/tmp aside).
        var best: (archive: LabProject, entry: LabRoll, folder: String)?
        for archive in projects.projects {
            for roll in archive.rolls {
                let folder = URL(fileURLWithPath: roll.folder, isDirectory: true).labStandardized.path
                guard folder == path || path.hasPrefix(folder + "/"), best.map({ folder.count > $0.folder.count }) ?? true else { continue }
                best = (archive, roll, folder)
            }
        }
        if let best {
            facts.archive = best.archive.name
            facts.added = best.entry.addedAt
            // The Folder's own card, or the card of the Folder holding it.
            let own = best.archive.rolls.first { URL(fileURLWithPath: $0.folder, isDirectory: true).labStandardized.path == path }
            facts.film = (own ?? best.entry).film
        }
        memo[path] = facts
        return facts
    }

    /// The stocks' names by their ids, so `film:portra` finds a development on `kodak_portra_400`.
    private var stockNames: [String: String] {
        if let known = finding.stockNames, !known.isEmpty || model.stocks.isEmpty { return known }
        let names = Dictionary(model.stocks.map { ($0.id, $0.name) }) { first, _ in first }
        finding.stockNames = names
        return names
    }

    /// Every record of the index, in its order.
    func allRecords() -> [PhotoRecord] {
        var folders: [String: FolderFacts] = [:]
        return catalog.order.compactMap { path in catalog.photos[path].map { record(of: $0, folders: &folders) } }
    }

    // MARK: Lists

    /// The cache, worked out again when the index or the Archives changed.
    private func cached() -> FindingCache {
        let stamp = catalog.generation &* 31 &+ projects.projects.hashValue &* 7 &+ lastImportStamp
        if finding.stamp == stamp { return finding }
        var cache = FindingCache(stamp: stamp)
        cache.picks = catalog.order.filter { catalog.photos[$0]?.flag == PhotoSidecar.Flag.pick.rawValue }
        cache.days = DateTree.build(catalog.order.compactMap { catalog.photos[$0]?.day })
        finding = cache
        return cache
    }

    /// The fixed entries' counts, nil before the index is read.
    var allCount: Int? { _ = catalog.generation; return catalog.ready ? catalog.order.count : nil }
    var picksCount: Int? { catalog.ready ? cached().picks.count : nil }
    var lastImportCount: Int { lastImportPaths().count }
    var dateTree: DateTree { cached().days }

    /// The photographs of the last import still in the lab.
    func lastImportPaths() -> [String] {
        var cache = cached()
        if let known = cache.lastImport { return known }
        let file = LastImportFile.read(inCatalog: projects.directory)
        let paths = file?.photos ?? importer.ledger.lastImport()
        let removed = projects.removed
        // A photograph on a disk that doesn't answer is kept: it's away, not gone.
        let kept = paths.filter { !removed.contains($0) && (VolumeReach.exists($0) || VolumeReach.isSilent($0)) }
        cache.lastImport = kept
        cache.lastImportDate = file?.date ?? kept.compactMap { catalog.imported($0) }.max()
        finding = cache
        return kept
    }

    var lastImportDate: Date? {
        _ = lastImportPaths()
        return finding.lastImportDate
    }

    /// What a fixed entry lists, by path.
    func listedFrames(_ view: LabView) -> [String] {
        switch view {
        case .lastImport: return lastImportPaths()
        case .found: return smartFrames(PhotoQuery.parse(foundQuery, label: Self.labelWord))
        case .picks: return cached().picks
        case .day(let key):
            guard let period = SmartRule.period(key) else { return [] }
            let paths = catalog.order.filter { path in catalog.photos[path]?.day.map { $0 >= period.start && $0 < period.end } ?? false }
            return paths.sorted { (catalog.photos[$0]?.day ?? .distantPast) < (catalog.photos[$1]?.day ?? .distantPast) }
        default: return []
        }
    }

    /// The photographs of the catalogue that meet `rules`, in the index's order.
    func smartFrames(_ rules: RuleGroup) -> [String] {
        var cache = cached()
        if let known = cache.smart[rules] { return known }
        let now = Date()
        let found = allRecords().filter { rules.matches($0, now: now) }.map(\.path)
        cache.smart[rules] = found
        finding = cache
        return found
    }

    /// The import just made: Last Import shows it.
    func noteImported(_ photos: [URL]) {
        guard !photos.isEmpty else { return }
        LastImportFile.write(photos, inCatalog: projects.directory)
        lastImportStamp += 1
        catalog.refresh(after: .milliseconds(300))
    }

    // MARK: Smart Rolls

    /// The rule editor, for a new Smart Roll (in `box`, or in the Box “Smart Rolls”) or one to change.
    func newSmartRoll(in box: UUID? = nil, rules: RuleGroup? = nil, name: String = "Smart Roll") {
        guard projects.isOpen else { return NSSound.beep() }
        let rules = rules ?? RuleGroup(match: .all, rules: [PhotoField.rating.startingRule])
        smartRollDraft = SmartRollDraft(editing: nil, name: name, rules: rules, box: box)
    }

    func editSmartRoll(_ id: UUID, in box: UUID) {
        guard let roll = projects.boxRoll(id, in: box)?.roll, let rules = roll.rules else { return }
        smartRollDraft = SmartRollDraft(editing: (id, box), name: roll.name, rules: rules, box: box)
    }

    /// Save as Smart Roll… from the filter bar: its filter and search as rules, kept in the Box open (if one is).
    func saveFilterAsSmartRoll() {
        var rules = model.library.filter.asRules
        // What's open narrows it: an Archive's or a Folder's photographs only.
        switch openView {
        case .archive(let id)?: if let archive = projects.archive(id) { rules.rules.insert(SmartRule(field: .archive, op: .is, value: archive.name), at: 0) }
        case .folder(let path, _)?: rules.rules.insert(SmartRule(field: .folder, op: .is, value: path), at: 0)
        case .day(let key)?: rules.rules.insert(SmartRule(field: .captureDate, op: .is, value: key), at: 0)
        case .picks?: rules.rules.insert(SmartRule(field: .flag, op: .is, value: "pick"), at: 0)
        default: break
        }
        if rules.isEmpty { rules.rules = [PhotoField.rating.startingRule] }
        let box: UUID? = switch openView {
        case .box(let id)?: id
        case .roll(_, let id)?: id
        default: nil
        }
        let search = model.library.filter.search.trimmingCharacters(in: .whitespaces)
        newSmartRoll(in: box, rules: rules, name: search.isEmpty ? "Smart Roll" : search)
    }

    /// The rule editor's Save: a new Smart Roll, or the one changed. One undo step.
    func finishSmartRoll(_ draft: SmartRollDraft) {
        smartRollDraft = nil
        if let editing = draft.editing {
            undoable("Change Smart Roll") { projects.changeSmartRoll(editing.roll, in: editing.box, name: draft.name, rules: draft.rules); return true }
            if openView == .roll(editing.roll, box: editing.box) { libraryChanged() }
            return
        }
        var made: (UUID, UUID)?
        undoable("New Smart Roll") {
            let boxID: UUID
            if let box = draft.box, projects.box(box) != nil { boxID = box }
            else if let existing = projects.boxes.first(where: { $0.name == Self.smartRollsBoxName }) { boxID = existing.id }
            else if let box = projects.createBox(named: Self.smartRollsBoxName) { boxID = box.id }
            else { return false }
            guard let roll = projects.createSmartRoll(named: draft.name, in: boxID, rules: draft.rules) else { return false }
            made = (roll.id, boxID)
            return true
        }
        guard let (roll, box) = made else { return }
        sidebarFold.unfold(.box(box))
        if !projects.frames(of: .roll(roll, box: box)).isEmpty { open(.roll(roll, box: box)) }
    }

    /// How many photographs of the catalogue the rules find now (the editor's count).
    func countMatching(_ rules: RuleGroup) -> Int { smartFrames(rules).count }

    // MARK: New Rolls by Day

    /// A Box named after `name` with one Roll per capture day of `paths`, in the order of the days. Nothing on disk.
    func newRollsByDay(named name: String, paths: [String], in parent: UUID? = nil) {
        guard !paths.isEmpty else { return NSSound.beep() }
        let calendar = Calendar.current
        var byDay: [String: [String]] = [:]
        var undated: [String] = []
        for path in paths {
            guard let date = catalog.photos[path]?.day ?? facts.known(URL(fileURLWithPath: path, isDirectory: false))?.date else { undated.append(path); continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            byDay[String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), default: []].append(path)
        }
        var made: UUID?
        undoable("New Rolls by Day") {
            guard let box = projects.createBox(named: name, in: parent) else { return false }
            for day in byDay.keys.sorted() {
                let title = SmartRule.period(day).map { $0.start.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB"))) } ?? day
                projects.createRoll(named: title, in: box.id, frames: (byDay[day] ?? []).map { URL(fileURLWithPath: $0, isDirectory: false) })
            }
            if !undated.isEmpty { projects.createRoll(named: "Undated", in: box.id, frames: undated.map { URL(fileURLWithPath: $0, isDirectory: false) }) }
            made = box.id
            return true
        }
        if let made {
            if let parent { sidebarFold.unfold(.box(parent)) }
            sidebarFold.unfold(.box(made))
            note("New Rolls by Day", "\(byDay.count + (undated.isEmpty ? 0 : 1)) Rolls in “\(projects.box(made)?.name ?? name)”")
        }
    }

    /// The photographs of an Archive, a Folder (with those under it) or a Box, for New Rolls by Day.
    func photoPaths(of view: LabView) -> [String] {
        switch view {
        case .box(let id): return projects.frames(of: .box(id))
        case .archive(let id):
            guard let archive = projects.archive(id) else { return [] }
            let folders = Set(projects.photoFolders(of: archive).map(\.labStandardized.path))
            return catalog.order.filter { folders.contains(($0 as NSString).deletingLastPathComponent) }
        case .folder(let path, _):
            let folder = URL(fileURLWithPath: path, isDirectory: true).labStandardized.path
            return catalog.order.filter { $0.hasPrefix(folder + "/") }
        default: return []
        }
    }

    func newRollsByDay(for view: LabView) {
        let name: String
        var parent: UUID?
        switch view {
        case .archive(let id): name = projects.archive(id)?.name ?? "By Day"
        case .folder(let path, let id): name = projects.archive(id).map { projects.folder(path, in: $0).name } ?? (path as NSString).lastPathComponent
        case .box(let id): name = (projects.box(id)?.name ?? "Box") + " by Day"; parent = projects.place(ofBox: id)?.parent
        default: return
        }
        let paths = photoPaths(of: view)
        guard !paths.isEmpty else {
            model.error = catalog.building ? "The lab is still reading these photographs. Try again in a moment." : "No photographs to sort by day here."
            return
        }
        newRollsByDay(named: name, paths: paths, in: parent)
    }
}
