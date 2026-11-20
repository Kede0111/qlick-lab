// Qlick Lab — GPL-3.0-only.
import CryptoKit
import Foundation
import Observation

/// One of an Archive's Folders: a folder of photographs where it lies, as it was imported or added. Nothing is copied
/// or moved: the folder stays the library, and each photograph's marks and developments stay in its `.qlick` sidecar
/// beside it. The Folder only adds what a folder can't say: a name, the film loaded, the camera, notes (its card).
/// The folders under it are read from the disk (`FolderTrees`); one of them gets an entry of its own once its card is
/// written.
struct LabRoll: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// The folder's path, and a bookmark that still finds it after it's renamed or moved on the same volume.
    var folder: String
    var bookmark: Data?
    /// What was in the camera, as the photographer writes it ("Portra 400 poussée +1"). Free text: it describes the
    /// shoot, it doesn't choose a simulation.
    var film = ""
    var camera = ""
    var notes = ""
    var addedAt = Date()

    var url: URL { URL(fileURLWithPath: folder, isDirectory: true) }
}

/// A Roll inside a Box: photographs chosen from any Archive, by their paths. Kept in the catalogue only.
struct BoxRoll: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var frames: [String] = []
    var createdAt = Date()
}

/// A Box: photographs chosen from any Archive (a portfolio, a trip, an edit for a client), held directly, in its Rolls,
/// or in the Boxes inside it, to any depth. Kept in the catalogue only: a photograph stays where it is, and can be in
/// any number of Boxes.
struct LabBox: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var frames: [String] = []
    /// The Boxes inside it.
    var boxes: [LabBox] = []
    var rolls: [BoxRoll] = []
    var createdAt = Date()

    /// What the Box shows: its own photographs, then those of the Boxes inside it, then its Rolls', each once.
    var allFrames: [String] {
        var seen: Set<String> = []
        return everyFrame.filter { seen.insert($0).inserted }
    }

    private var everyFrame: [String] { frames + boxes.flatMap(\.everyFrame) + rolls.flatMap(\.frames) }

    /// This Box and every Box inside it, depth first.
    var all: [LabBox] { [self] + boxes.flatMap(\.all) }

    /// The chain of Boxes from this one down to `id`, if it's in it.
    func path(to id: UUID) -> [LabBox]? {
        if self.id == id { return [self] }
        for box in boxes { if let path = box.path(to: id) { return [self] + path } }
        return nil
    }

    /// Changes the Box `id`, this one or one inside it. Whether it was found.
    mutating func change(_ id: UUID, _ change: (inout LabBox) -> Void) -> Bool {
        if self.id == id { change(&self); return true }
        for index in boxes.indices where boxes[index].change(id, change) { return true }
        return false
    }

    /// Takes the Box `id` out of those inside this one, at any depth.
    mutating func removeBox(_ id: UUID) -> LabBox? {
        if let index = boxes.firstIndex(where: { $0.id == id }) { return boxes.remove(at: index) }
        for index in boxes.indices { if let found = boxes[index].removeBox(id) { return found } }
        return nil
    }
}

/// An Archive: what one import subject holds ("Leica M11", "Spain 2026"): its Folders, the places on disk its
/// photographs live, shown as the disk has them. (The type kept its first name, project; the interface says Archive.)
struct LabProject: Codable, Identifiable, Hashable, Sendable {
    /// 2: no more Arrivals or selections (converted at load: `ProjectStore.convert`).
    static let schema = 2
    var schema = LabProject.schema
    var id = UUID()
    var name: String
    var notes = ""
    var createdAt = Date()
    /// The Archive's Folders (the imported locations, and the folders under them that have a card).
    var rolls: [LabRoll] = []
    var archived = false
    /// Its place among the Archives in the sidebar, once moved there by hand; before that, the order they were made in.
    var order: Int? = nil
    /// Read from catalogues before 0.4 only, to convert them: Arrivals, or a selection.
    var kind: Kind? = nil
    /// A selection's frames, before 0.4.
    var frames: [String]? = nil

    enum Kind: String, Codable, Sendable { case arrivals, selection }
}

/// The catalogue's Boxes, in one file beside the Archives: `boxes.json`, top-level key `qlick`.
enum BoxesFile {
    static let fileName = "boxes.json"
    static let schema = 1

    private struct File: Codable { var qlick: Content }
    private struct Content: Codable { var schema: Int; var boxes: [LabBox] }

    static func url(inCatalog directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The Boxes, or nil when there's no file, or one this version can't read (a newer schema is left alone).
    static func read(inCatalog directory: URL) -> [LabBox]? {
        guard let data = try? Data(contentsOf: url(inCatalog: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.qlick.schema <= schema else { return nil }
        return file.qlick.boxes
    }

    /// Whether a file is there that this version mustn't write over (newer, or unreadable).
    static func isForeign(inCatalog directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(inCatalog: directory).path) && read(inCatalog: directory) == nil
    }

    @discardableResult static func write(_ boxes: [LabBox], inCatalog directory: URL) -> Bool {
        guard !isForeign(inCatalog: directory) else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(File(qlick: Content(schema: schema, boxes: boxes))).write(to: url(inCatalog: directory), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("boxes: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

/// What holds photographs by reference: a Box, or one of its Rolls.
enum Holder: Hashable, Sendable {
    case box(UUID)
    case roll(UUID, box: UUID)
}

/// What a list on the contact sheet shows (`ProjectStore.viewFolder`): a whole Archive, a Folder with the folders
/// under it, a Box, a Roll of a Box.
enum LabView: Hashable, Sendable {
    case archive(UUID)
    case folder(String, archive: UUID)
    case box(UUID)
    case roll(UUID, box: UUID)

    var holder: Holder? {
        switch self {
        case .box(let id): .box(id)
        case .roll(let id, let box): .roll(id, box: box)
        default: nil
        }
    }
}

/// What a Folder holds, counted from it and the folders under it, and their sidecars.
struct RollStats: Equatable, Sendable {
    var total = 0
    var picks = 0
    var rejects = 0
    var edited = 0
    var missing = false
    /// The films its developments are on, by stock id, with how many frames each: what the library's search finds
    /// a years-old development by.
    var films: [String: Int] = [:]
    /// Qlick Lab: the keywords its photographs carry, with how many each (`ProjectStore.keywordCounts`).
    var keywords: [String: Int] = [:]
    /// File names, in order, relative to the folder (`2026-09-19/L1004394.DNG` below it), for the search and for its
    /// first frames.
    var names: [String] = []
    var unmarked: Int { max(total - picks - rejects, 0) }
}

/// The Archives, one small JSON file each in the catalogue, and the Boxes (`BoxesFile`). Removing an Archive, a
/// Folder, a Box or a Roll only forgets it: photographs and sidecars are never touched.
@MainActor @Observable final class ProjectStore {
    static let toSortName = "To Sort"
    private(set) var projects: [LabProject] = []
    private(set) var stats: [UUID: RollStats] = [:]
    /// The open catalog's folder (`CatalogList`).
    private(set) var directory: URL
    /// The Archives' Folders as the disk has them, followed as it changes.
    let folders = FolderTrees()
    @ObservationIgnored private var counting: [UUID: Task<Void, Never>] = [:]

    init(directory: URL = AppDataLocations.supportDirectory.appendingPathComponent("Projects", isDirectory: true)) {
        self.directory = directory
        load()
    }

    // MARK: Files

    /// Another catalog's Archives in place of these.
    func open(directory: URL) {
        counting.values.forEach { $0.cancel() }
        boxes = []
        removed = []
        counting = [:]
        stats = [:]
        self.directory = directory
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The folders of links whole projects were shown through before 0.3: lists need none now. Only the links go.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("Views", isDirectory: true))
        projects = files.filter { $0.pathExtension == "json" && ![SavedImportSettings.fileName, BoxesFile.fileName, RemovedFile.fileName].contains($0.lastPathComponent) }
            .compactMap { try? decoder.decode(LabProject.self, from: Data(contentsOf: $0)) }
            // A newer schema is left alone, never written over.
            .filter { $0.schema <= LabProject.schema }
            .sorted { ($0.order ?? Int.max, $0.createdAt) < ($1.order ?? Int.max, $1.createdAt) }
        boxes = BoxesFile.read(inCatalog: directory) ?? []
        removed = RemovedFile.read(inCatalog: directory) ?? []
        convert()
        followFolders()
    }

    /// Catalogues before 0.4, once: Arrivals becomes the Archive “To Sort”, each selection a Box of the same name.
    /// Only the catalogue's files change; nothing on disk moves.
    private func convert() {
        for index in projects.indices where projects[index].kind == .arrivals {
            let id = projects[index].id
            if projects[index].rolls.isEmpty {
                try? FileManager.default.removeItem(at: file(id))
                continue
            }
            projects[index].kind = nil
            projects[index].name = uniqueName(Self.toSortName, except: id)
            save(projects[index])
        }
        projects.removeAll { $0.kind == .arrivals }
        let selections = projects.filter { $0.kind == .selection }
        guard !selections.isEmpty else { return }
        projects.removeAll { $0.kind == .selection }
        for selection in selections.sorted(by: { $0.createdAt < $1.createdAt }) where !boxes.contains(where: { $0.id == selection.id }) {
            boxes.append(LabBox(id: selection.id, name: uniqueBoxName(selection.name), frames: selection.frames ?? [], createdAt: selection.createdAt))
        }
        // The Boxes are written before the selections' own files go: a failure leaves them to convert again.
        guard saveBoxes() else { return }
        for selection in selections { try? FileManager.default.removeItem(at: file(selection.id)) }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// Writes every Archive again: File › Save Catalog. Each change is written as it's made, so this only makes sure.
    func saveAll() { for project in projects { save(project) }; saveBoxes() }

    @discardableResult func save(_ project: LabProject) -> Bool {
        var project = project
        project.schema = LabProject.schema
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(project).write(to: file(project.id), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("archive \(project.name): \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    // MARK: Archives

    /// Every Archive (kept for the code that named them so; there is one kind now).
    var ordinary: [LabProject] { projects }

    /// An Archive by its name, ignoring case.
    func project(named name: String) -> LabProject? {
        projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func archive(_ id: UUID) -> LabProject? { projects.first { $0.id == id } }

    /// The Archive “To Sort”, where an import without an Archive goes; made if it isn't there yet.
    func toSort() -> LabProject {
        if let found = project(named: Self.toSortName) { return found }
        return create(named: Self.toSortName)
    }

    @discardableResult func create(named name: String) -> LabProject {
        let project = LabProject(name: uniqueName(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Archive" : name))
        projects.append(project)
        save(project)
        return project
    }

    func uniqueName(_ name: String, except: UUID? = nil) -> String {
        Self.unique(name, taken: projects.filter { $0.id != except }.map(\.name))
    }

    nonisolated static func unique(_ name: String, taken names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    func update(_ id: UUID, _ change: (inout LabProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        change(&project)
        guard project != projects[index] else { return }
        let rollsChanged = project.rolls.map(\.folder) != projects[index].rolls.map(\.folder)
        projects[index] = project
        save(project)
        if rollsChanged { followFolders() }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update(id) { $0.name = name }
    }

    /// Forgets the Archive. Its photographs and their sidecars stay where they are.
    func remove(_ id: UUID) {
        for roll in projects.first(where: { $0.id == id })?.rolls ?? [] { counting[roll.id]?.cancel(); stats[roll.id] = nil }
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(id))
        followFolders()
    }

    // MARK: Boxes and their Rolls

    /// The catalogue's Boxes on top, each with the Boxes inside it, in its file `boxes.json` (`BoxesFile`).
    private(set) var boxes: [LabBox] = []

    /// The photographs removed from the lab (Remove from Qlick Lab), by path: left out of every listing (their
    /// Archive's, a Folder's, the counts) and out of every Box. Their files aren't touched. In `removed.json`
    /// (`RemovedFile`); put back by Undo or the Archive's Restore Removed Photos.
    private(set) var removed: Set<String> = [] {
        didSet {
            guard removed != oldValue else { return }
            PhotoFolder.excluded = removed
            removedChanged?(removed.symmetricDifference(oldValue))
        }
    }
    /// Told when `removed` changes, with the photographs that came or went, so what's listed follows (`LabState`).
    @ObservationIgnored var removedChanged: ((Set<String>) -> Void)?

    /// The removed photographs in place of these, written at once (a removal, its undo, a restore).
    func replaceRemoved(_ new: Set<String>) {
        guard new != removed, RemovedFile.write(new, inCatalog: directory) else { return }
        removed = new
    }

    /// The chain of Boxes from the top down to `id`.
    func boxPath(_ id: UUID) -> [LabBox]? {
        for box in boxes { if let path = box.path(to: id) { return path } }
        return nil
    }

    func box(_ id: UUID) -> LabBox? { boxPath(id)?.last }

    /// Every Box, at any depth, depth first.
    var allBoxes: [LabBox] { boxes.flatMap(\.all) }

    /// A Roll of a Box, with its Box.
    func boxRoll(_ id: UUID, in boxID: UUID) -> (box: LabBox, roll: BoxRoll)? {
        guard let box = box(boxID), let roll = box.rolls.first(where: { $0.id == id }) else { return nil }
        return (box, roll)
    }

    /// The name a holder goes by: its Boxes' and its own, “Spain › Madrid › Day 1”.
    func name(of holder: Holder) -> String? {
        switch holder {
        case .box(let id): return boxPath(id).map { $0.map(\.name).joined(separator: " › ") }
        case .roll(let id, let boxID):
            guard let path = boxPath(boxID), let roll = path.last?.rolls.first(where: { $0.id == id }) else { return nil }
            return (path.map(\.name) + [roll.name]).joined(separator: " › ")
        }
    }

    func exists(_ holder: Holder) -> Bool { name(of: holder) != nil }

    /// What a holder shows: a Box's own photographs and everything inside it, or a Roll's.
    func frames(of holder: Holder) -> [String] {
        switch holder {
        case .box(let id): return box(id)?.allFrames ?? []
        case .roll(let id, let boxID): return boxRoll(id, in: boxID)?.roll.frames ?? []
        }
    }

    /// A name no Box beside it has: on top, or inside `parent`.
    func uniqueBoxName(_ name: String, in parent: UUID? = nil) -> String {
        Self.unique(name, taken: (parent.flatMap(box)?.boxes ?? boxes).map(\.name))
    }

    /// A new Box, on top or inside `parent`, holding `frames`.
    @discardableResult func createBox(named name: String, in parent: UUID? = nil, frames: [URL] = []) -> LabBox? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = LabBox(name: uniqueBoxName(trimmed.isEmpty ? "New Box" : trimmed, in: parent), frames: Self.paths(frames))
        if let parent {
            guard self.box(parent) != nil else { return nil }
            changeBox(parent) { $0.boxes.append(box) }
        } else {
            boxes.append(box)
            saveBoxes()
        }
        return box
    }

    /// A new Roll in a Box, holding `frames` (photographs chosen, or a Folder's dropped on the Box).
    @discardableResult func createRoll(named name: String, in boxID: UUID, frames: [URL] = []) -> BoxRoll? {
        guard let box = box(boxID) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roll = BoxRoll(name: Self.unique(trimmed.isEmpty ? "New Roll" : trimmed, taken: box.rolls.map(\.name)), frames: Self.paths(frames))
        changeBox(boxID) { $0.rolls.append(roll) }
        return roll
    }

    func renameBox(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeBox(id) { $0.name = name }
    }

    func renameRoll(_ id: UUID, in boxID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeBox(boxID) { box in
            if let index = box.rolls.firstIndex(where: { $0.id == id }) { box.rolls[index].name = name }
        }
    }

    /// Forgets a Box with everything inside it. The photographs stay where they are, in their Archives and other Boxes.
    func deleteBox(_ id: UUID) {
        if boxes.contains(where: { $0.id == id }) {
            boxes.removeAll { $0.id == id }
        } else {
            var found = false
            for index in boxes.indices where !found { found = boxes[index].removeBox(id) != nil }
            guard found else { return }
        }
        saveBoxes()
    }

    /// Forgets a Roll of a Box. The photographs stay where they are.
    func deleteRoll(_ id: UUID, in boxID: UUID) {
        changeBox(boxID) { $0.rolls.removeAll { $0.id == id } }
    }

    /// Puts photographs in a Box or a Roll, after those it has; one already in it stays where it is.
    func addFrames(_ frames: [URL], to holder: Holder) {
        let adding = Self.paths(frames)
        func add(_ list: inout [String]) {
            let known = Set(list)
            list += adding.filter { !known.contains($0) }
        }
        switch holder {
        case .box(let id):
            changeBox(id) { add(&$0.frames) }
        case .roll(let id, let boxID):
            changeBox(boxID) { box in
                if let index = box.rolls.firstIndex(where: { $0.id == id }) { add(&box.rolls[index].frames) }
            }
        }
    }

    /// Takes photographs out of a Box (from it and everything inside it, as it shows them all) or a Roll. The
    /// photographs aren't touched.
    func removeFrames(_ frames: [URL], from holder: Holder) {
        let gone = Set(Self.paths(frames))
        func strip(_ box: inout LabBox) {
            box.frames.removeAll { gone.contains($0) }
            for index in box.rolls.indices { box.rolls[index].frames.removeAll { gone.contains($0) } }
            for index in box.boxes.indices { strip(&box.boxes[index]) }
        }
        switch holder {
        case .box(let id):
            changeBox(id) { strip(&$0) }
        case .roll(let id, let boxID):
            changeBox(boxID) { box in
                if let index = box.rolls.firstIndex(where: { $0.id == id }) { box.rolls[index].frames.removeAll { gone.contains($0) } }
            }
        }
    }

    private func changeBox(_ id: UUID, _ change: (inout LabBox) -> Void) {
        var changed = boxes
        guard changed.indices.contains(where: { changed[$0].change(id, change) }), changed != boxes else { return }
        boxes = changed
        saveBoxes()
    }

    @discardableResult func saveBoxes() -> Bool { BoxesFile.write(boxes, inCatalog: directory) }

    /// Every Box in place of these, written at once (a drag in the sidebar, an undo).
    func replaceBoxes(_ new: [LabBox]) {
        guard new != boxes else { return }
        boxes = new
        saveBoxes()
    }

    /// The Archives in this order, each with its place written down (`LabProject.order`), so the sidebar keeps it.
    func reorderArchives(_ ids: [UUID]) {
        var ordered = ids.compactMap { id in projects.first { $0.id == id } }
        ordered += projects.filter { !ids.contains($0.id) }
        for index in ordered.indices where ordered[index].order != index {
            ordered[index].order = index
            save(ordered[index])
        }
        projects = ordered
    }

    // MARK: Undo

    /// What the sidebar's gestures change: the Boxes, and the Archives (their order, their Folders).
    struct Snapshot: Equatable {
        var boxes: [LabBox]
        var projects: [LabProject]
        var removed: Set<String> = []
    }

    var snapshot: Snapshot { Snapshot(boxes: boxes, projects: projects, removed: removed) }

    /// Puts the Boxes and the Archives back as they were. An Archive made or removed since is left as it is.
    func restore(_ snapshot: Snapshot) {
        replaceBoxes(snapshot.boxes)
        replaceRemoved(snapshot.removed)
        var restored: [LabProject] = []
        for old in snapshot.projects {
            guard let now = projects.first(where: { $0.id == old.id }) else { continue }
            if now != old { save(old) }
            restored.append(old)
        }
        restored += projects.filter { project in !snapshot.projects.contains { $0.id == project.id } }
        let foldersChanged = restored.map { $0.rolls.map(\.folder) } != projects.map { $0.rolls.map(\.folder) }
        projects = restored
        if foldersChanged {
            followFolders()
            for roll in projects.flatMap(\.rolls) where stats[roll.id] == nil { count(roll) }
        }
    }

    /// The photographs' own paths, once each: a version (`#variant=`) is its photograph.
    static func paths(_ frames: [URL]) -> [String] {
        var seen: Set<String> = []
        return frames.map { $0.photoFile.standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }

    // MARK: Folders

    /// Adds `folders` to the Archive, skipping those it already has. A folder is added as it is, with every folder
    /// under it: the tree is the disk's (`FolderTrees`).
    @discardableResult func addRolls(_ folders: [URL], to id: UUID) -> [LabRoll] {
        var added: [LabRoll] = []
        update(id) { project in
            for folder in folders where Self.holdsPhotographs(folder) {
                let path = folder.standardizedFileURL.path
                guard !project.rolls.contains(where: { $0.folder == path }) else { continue }
                let roll = Self.entry(for: folder)
                project.rolls.append(roll)
                added.append(roll)
            }
        }
        for roll in added { count(roll) }
        return added
    }

    /// A new entry for a folder, with the card it brings (another catalogue, another Mac).
    private static func entry(for folder: URL) -> LabRoll {
        let folder = folder.standardizedFileURL
        var roll = LabRoll(name: folder.lastPathComponent, folder: folder.path,
                           bookmark: try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        RollCardFile.read(in: folder)?.apply(to: &roll)
        return roll
    }

    /// Whether `folder` holds a photograph, itself or in any folder under it (hidden folders and packages aside).
    nonisolated static func holdsPhotographs(_ folder: URL) -> Bool {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in walk where PhotoFolder.extensions.contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    /// The Archive's Folders on top, in its order: those no other of its Folders holds.
    func roots(of archive: LabProject) -> [URL] {
        let folders = archive.rolls.map { URL(fileURLWithPath: $0.folder, isDirectory: true) }
        return folders.filter { folder in !folders.contains { folder.path.hasPrefix($0.path + "/") } }
            .reduce(into: [URL]()) { kept, folder in if !kept.contains(folder) { kept.append(folder) } }
    }

    /// The Archive whose Folders hold `path`, the deepest Folder first: the entry for exactly that folder, or the
    /// one that holds it.
    func place(of path: String) -> (archive: LabProject, entry: LabRoll)? {
        var best: (archive: LabProject, entry: LabRoll)?
        for archive in projects {
            for roll in archive.rolls where roll.folder == path || path.hasPrefix(roll.folder + "/") {
                if best == nil || roll.folder.count > best!.entry.folder.count { best = (archive, roll) }
            }
        }
        return best
    }

    /// A folder of an Archive as the lab knows it: its own entry, or one made for the moment (the disk's name, the
    /// film and camera of the Folder holding it).
    func folder(_ path: String, in archive: LabProject) -> LabRoll {
        if let own = archive.rolls.first(where: { $0.folder == path }) { return own }
        var made = LabRoll(id: Self.stableID(path), name: (path as NSString).lastPathComponent, folder: path)
        if let holder = archive.rolls.filter({ path.hasPrefix($0.folder + "/") }).max(by: { $0.folder.count < $1.folder.count }) {
            made.film = holder.film; made.camera = holder.camera
        }
        return made
    }

    /// The entry of a folder under one of the Archive's Folders, made when its card is first written.
    func folderEntry(_ path: String, in archiveID: UUID) -> LabRoll? {
        guard let archive = archive(archiveID) else { return nil }
        if let own = archive.rolls.first(where: { $0.folder == path }) { return own }
        let roll = Self.entry(for: URL(fileURLWithPath: path, isDirectory: true))
        update(archiveID) { $0.rolls.append(roll) }
        return roll
    }

    private nonisolated static func stableID(_ path: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(path.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The folders of the Archive that hold photographs, in the tree's order: each Folder on top, then those under it.
    /// Before the disk is read, the Folders the catalogue knows.
    func photoFolders(of archive: LabProject) -> [URL] {
        var seen: Set<String> = [], folders: [URL] = []
        for root in roots(of: archive) {
            let found: [URL]
            if let tree = tree(root) { found = tree.all.filter { $0.photos > 0 }.map(\.url) }
            else {
                let path = root.path
                found = archive.rolls.filter { $0.folder == path || $0.folder.hasPrefix(path + "/") }.compactMap { resolve($0, in: archive.id) }
            }
            for folder in found where seen.insert(folder.standardizedFileURL.path).inserted { folders.append(folder) }
        }
        return folders
    }

    private func tree(_ root: URL) -> FolderNode? { folders.trees[root.standardizedFileURL.path] }

    /// The folders holding photographs at `path` and under it: from the tree read, or from the disk now if it isn't
    /// read yet (a Folder just added), so a folder whose photographs are all in folders under it still shows them.
    func photoFolders(under path: String) -> [URL] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let node = node(path) ?? FolderTrees.read(url) else { return [url] }
        return node.all.filter { $0.photos > 0 }.map(\.url)
    }

    /// The tree read under a folder, wherever it is in an Archive's trees.
    func node(_ path: String) -> FolderNode? {
        for tree in folders.trees.values {
            if tree.id == path { return tree }
            if path.hasPrefix(tree.id + "/"), let found = tree.all.first(where: { $0.id == path }) { return found }
        }
        return nil
    }

    /// The trees follow every Archive's Folders on top.
    func followFolders() {
        folders.follow(Set(projects.flatMap { roots(of: $0) }.map(\.standardizedFileURL)))
    }

    func updateRoll(_ roll: UUID, in project: UUID, _ change: (inout LabRoll) -> Void) {
        var changed: LabRoll?
        update(project) { project in
            guard let index = project.rolls.firstIndex(where: { $0.id == roll }) else { return }
            let before = RollCardFile(project.rolls[index])
            change(&project.rolls[index])
            if RollCardFile(project.rolls[index]) != before { changed = project.rolls[index] }
        }
        if let changed { writeCard(of: changed) }
    }

    // MARK: Folder cards

    @ObservationIgnored private var cardWrites: [UUID: Task<Void, Never>] = [:]

    /// Writes a Folder's card into it (`RollCardFile`), a moment after the last change: the editor changes it at
    /// each letter typed. Off the main thread, as a disk on the network answers slowly.
    func writeCard(of roll: LabRoll) {
        cardWrites[roll.id]?.cancel()
        let card = RollCardFile(roll), folder = roll.url
        cardWrites[roll.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = await Task.detached(priority: .utility) { card.write(in: folder) }.value
            self?.cardWrites[roll.id] = nil
        }
    }

    /// Brings a Folder and its card together once it has been read: the card wins (it may have been changed in
    /// another catalogue or on another Mac); a Folder without a card, from before 0.3, gets one.
    private func reconcile(_ id: UUID, card: RollCardFile?) {
        guard cardWrites[id] == nil, let project = projects.first(where: { $0.rolls.contains { $0.id == id } }),
              let roll = project.rolls.first(where: { $0.id == id }) else { return }
        if let card {
            var updated = roll
            card.apply(to: &updated)
            if updated != roll { update(project.id) { if let index = $0.rolls.firstIndex(where: { $0.id == id }) { $0.rolls[index] = updated } } }
        } else if !RollCardFile(roll).isBlank {
            writeCard(of: roll)
        }
    }

    /// Moves a Folder from one Archive to another, with its card (film, camera, notes). If the other Archive already
    /// has the folder, it only leaves the first. Nothing moves on disk.
    func moveRoll(_ roll: UUID, from source: UUID, to target: UUID) {
        guard source != target, let moving = projects.first(where: { $0.id == source })?.rolls.first(where: { $0.id == roll }),
              projects.contains(where: { $0.id == target }) else { return }
        update(target) { project in
            if !project.rolls.contains(where: { $0.folder == moving.folder }) { project.rolls.append(moving) }
        }
        update(source) { $0.rolls.removeAll { $0.id == roll } }
    }

    func removeRoll(_ roll: UUID, from project: UUID) {
        update(project) { $0.rolls.removeAll { $0.id == roll } }
        stats[roll] = nil
    }

    // MARK: Lists

    /// The list (`PhotoFolder.register(list:)`) a whole Archive, a Folder with the folders under it, a Box or a Roll
    /// shows on one sheet, its photographs at their own paths. Named under `<catalogue>/Views/`, never made on disk.
    @discardableResult func viewFolder(for view: LabView) -> URL {
        let views = directory.appendingPathComponent("Views", isDirectory: true)
        let folder: URL, sources: [URL]
        switch view {
        case .archive(let id):
            folder = views.appendingPathComponent(id.uuidString, isDirectory: true)
            sources = archive(id).map(photoFolders(of:)) ?? []
        case .folder(let path, let id):
            folder = views.appendingPathComponent("folder/\(id.uuidString)", isDirectory: true).appendingPathComponent(String(path.dropFirst()), isDirectory: true)
            sources = photoFolders(under: path)
        case .box(let id):
            folder = views.appendingPathComponent("box/\(id.uuidString)", isDirectory: true)
            sources = frames(of: .box(id)).map { URL(fileURLWithPath: $0, isDirectory: false) }
        case .roll(let id, let box):
            folder = views.appendingPathComponent("roll/\(box.uuidString)/\(id.uuidString)", isDirectory: true)
            sources = frames(of: .roll(id, box: box)).map { URL(fileURLWithPath: $0, isDirectory: false) }
        }
        PhotoFolder.register(list: folder, sources: sources)
        return folder
    }

    /// A whole Archive's list.
    func viewFolder(for project: LabProject) -> URL { viewFolder(for: .archive(project.id)) }

    /// What the list named `directory` shows, if it's one of these.
    func view(of directory: URL?) -> LabView? {
        guard let directory else { return nil }
        let base = self.directory.appendingPathComponent("Views", isDirectory: true).standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        switch parts.first {
        case "box" where parts.count == 2:
            return UUID(uuidString: parts[1]).flatMap { box($0) != nil ? .box($0) : nil }
        case "roll" where parts.count == 3:
            guard let box = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]), boxRoll(id, in: box) != nil else { return nil }
            return .roll(id, box: box)
        case "folder" where parts.count > 2:
            guard let id = UUID(uuidString: parts[1]), archive(id) != nil else { return nil }
            return .folder("/" + parts.dropFirst(2).joined(separator: "/"), archive: id)
        default:
            guard parts.count == 1, let id = UUID(uuidString: parts[0]), archive(id) != nil else { return nil }
            return .archive(id)
        }
    }

    /// The Archive whose whole list is `directory`.
    func project(viewFolder directory: URL?) -> LabProject? {
        guard case .archive(let id)? = view(of: directory) else { return nil }
        return archive(id)
    }

    /// The Archive and Folder whose folder is `directory`, exactly (an entry of the catalogue).
    func find(folder directory: URL?) -> (project: LabProject, roll: LabRoll)? {
        guard let path = directory?.standardizedFileURL.path else { return nil }
        for project in projects {
            if let roll = project.rolls.first(where: { $0.folder == path }) { return (project, roll) }
        }
        return nil
    }

    /// A Folder, found again by its bookmark if it moved; the path is then brought up to date.
    func resolve(_ roll: LabRoll, in project: UUID) -> URL? {
        if FileManager.default.fileExists(atPath: roll.folder) { return roll.url }
        var stale = false
        guard let bookmark = roll.bookmark,
              let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        updateRoll(roll.id, in: project) { $0.folder = url.standardizedFileURL.path }
        return url
    }

    // MARK: Counts

    @ObservationIgnored var sidecars: SidecarStore?

    func countAll() { for roll in projects.flatMap(\.rolls) { count(roll) } }

    /// Counts a Folder's photographs and marks off the main thread.
    func count(_ roll: LabRoll) {
        counting[roll.id]?.cancel()
        let store = sidecars, url = roll.url, id = roll.id
        counting[id] = Task { [weak self] in
            let (counted, card) = await Task.detached(priority: .utility) { (Self.stats(of: url, store: store), RollCardFile.read(in: url)) }.value
            guard !Task.isCancelled, let self else { return }
            if self.stats[id] != counted { self.stats[id] = counted }
            if !counted.missing { self.reconcile(id, card: card) }
        }
    }

    /// A folder's photographs and those of every folder under it.
    nonisolated static func stats(of folder: URL, store: SidecarStore?) -> RollStats {
        guard let listing = try? PhotoFolder.listing(in: folder) else { return RollStats(missing: true) }
        var stats = RollStats()
        func add(_ listing: (photos: [PhotoFile], sidecars: [String: PhotoFile]), prefix: String) {
            stats.total += listing.photos.count
            stats.names += listing.photos.map { prefix + $0.name }
            guard let store else { return }
            for photo in listing.photos where listing.sidecars[PhotoFolder.sidecarKey(photo.url)] != nil {
                guard let sidecar = try? store.read(photo: photo.url) else { continue }
                let summary = sidecar.summary
                if summary.flag == .pick { stats.picks += 1 }
                if summary.flag == .reject { stats.rejects += 1 }
                if summary.edited { stats.edited += 1 }
                // Every version counts: a frame developed on two films is found by either.
                for film in Set(sidecar.variants.compactMap { $0.edits?["film"].string }.filter { !$0.isEmpty }) { stats.films[film, default: 0] += 1 }
                for word in summary.words.keywords { stats.keywords[word, default: 0] += 1 }
            }
        }
        add(listing, prefix: "")
        for sub in FolderTrees.read(folder)?.all.dropFirst() ?? [] where sub.photos > 0 {
            guard let inner = try? PhotoFolder.listing(in: sub.url) else { continue }
            add(inner, prefix: String(sub.url.path.dropFirst(folder.standardizedFileURL.path.count + 1)) + "/")
        }
        return stats
    }
}
