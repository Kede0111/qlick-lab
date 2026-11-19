// Qlick Lab — GPL-3.0-only.
import Foundation
import Observation

/// A roll, or a session: one folder of photographs, where it lies. Nothing is copied or moved: the folder stays the
/// library, as in NEgs, and each photograph's marks and developments stay in its `.qlick` sidecar beside it. The roll
/// only adds what a folder can't say: a name, the film loaded, notes.
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

struct LabProject: Codable, Identifiable, Hashable, Sendable {
    static let schema = 1
    var schema = LabProject.schema
    var id = UUID()
    var name: String
    var notes = ""
    var createdAt = Date()
    var rolls: [LabRoll] = []
    var archived = false
    /// Nil for an ordinary project. A file without the key (every catalogue before 0.1.5) reads as one.
    var kind: Kind? = nil

    enum Kind: String, Codable, Sendable {
        /// The box where rolls imported without a project wait to be filed, like the tray of envelopes back from the
        /// lab. One per catalogue, made the first time something lands in it.
        case arrivals
    }

    var isArrivals: Bool { kind == .arrivals }
}

/// What a roll holds, counted from its folder and sidecars.
struct RollStats: Equatable, Sendable {
    var total = 0
    var picks = 0
    var rejects = 0
    var edited = 0
    var missing = false
    /// The films its developments are on, by stock id, with how many frames each: what the library's search finds
    /// a years-old development by.
    var films: [String: Int] = [:]
    /// File names, in order, for the search and for the roll's first frames.
    var names: [String] = []
    var unmarked: Int { max(total - picks - rejects, 0) }
}

/// The projects, one small JSON file each in Application Support. Deleting a project or a roll only forgets it:
/// photographs and sidecars are never touched.
@MainActor @Observable final class ProjectStore {
    private(set) var projects: [LabProject] = []
    private(set) var stats: [UUID: RollStats] = [:]
    /// The open catalog's folder (`CatalogList`).
    private(set) var directory: URL
    @ObservationIgnored private var counting: [UUID: Task<Void, Never>] = [:]

    init(directory: URL = AppDataLocations.supportDirectory.appendingPathComponent("Projects", isDirectory: true)) {
        self.directory = directory
        load()
    }

    // MARK: Files

    /// Another catalog's projects in place of these.
    func open(directory: URL) {
        counting.values.forEach { $0.cancel() }
        counting = [:]
        stats = [:]
        self.directory = directory
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != SavedImportSettings.fileName }
            .compactMap { try? decoder.decode(LabProject.self, from: Data(contentsOf: $0)) }
            // A newer schema is left alone, never written over.
            .filter { $0.schema <= LabProject.schema }
            // Arrivals first, then the projects in the order they were made.
            .sorted { ($0.isArrivals ? 0 : 1, $0.createdAt) < ($1.isArrivals ? 0 : 1, $1.createdAt) }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// Writes every project again: File › Save Catalog. Each change is written as it's made, so this only makes sure.
    func saveAll() { for project in projects { save(project) } }

    private func save(_ project: LabProject) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(project).write(to: file(project.id), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("project \(project.name): \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Projects

    /// The projects the user made: every project but Arrivals.
    var ordinary: [LabProject] { projects.filter { !$0.isArrivals } }

    /// Arrivals, if anything has landed in it yet.
    var arrivals: LabProject? { projects.first(where: \.isArrivals) }

    /// An ordinary project by its name, ignoring case.
    func project(named name: String) -> LabProject? {
        ordinary.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Arrivals, made if it isn't there yet.
    func arrivalsBox() -> LabProject {
        if let arrivals { return arrivals }
        let box = LabProject(name: "Arrivals", kind: .arrivals)
        projects.insert(box, at: 0)
        save(box)
        return box
    }

    @discardableResult func create(named name: String) -> LabProject {
        let project = LabProject(name: uniqueName(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Project" : name))
        projects.append(project)
        save(project)
        return project
    }

    func uniqueName(_ name: String) -> String {
        let taken = Set(ordinary.map { $0.name.lowercased() })
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
        projects[index] = project
        save(project)
    }

    /// Forgets the project. Its photographs and their sidecars stay where they are.
    func remove(_ id: UUID) {
        for roll in projects.first(where: { $0.id == id })?.rolls ?? [] { counting[roll.id]?.cancel(); stats[roll.id] = nil }
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(id))
        // Its own folder of links, made to show it whole.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("Views", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true))
    }

    // MARK: Rolls

    /// Adds `folders` to the project as rolls, skipping those it already has. A folder without photographs of its
    /// own gives one roll for each sub-folder that has some (a card's DCIM, a shoot's days).
    @discardableResult func addRolls(_ folders: [URL], to id: UUID) -> [LabRoll] {
        var added: [LabRoll] = []
        update(id) { project in
            for folder in folders.flatMap({ Self.rollFolders(in: $0) }) {
                let path = folder.standardizedFileURL.path
                guard !project.rolls.contains(where: { $0.folder == path }) else { continue }
                var roll = LabRoll(name: folder.lastPathComponent, folder: path,
                                   bookmark: try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                // A folder that was a roll before (another catalogue, another Mac) brings its card.
                RollCardFile.read(in: folder)?.apply(to: &roll)
                project.rolls.append(roll)
                added.append(roll)
            }
        }
        for roll in added { count(roll) }
        return added
    }

    /// `folder` itself if it holds photographs, else its sub-folders that do, two levels down at most.
    nonisolated static func rollFolders(in folder: URL, depth: Int = 2) -> [URL] {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [] }
        if let images = try? PhotoFolder.images(in: folder), !images.isEmpty { return [folder] }
        guard depth > 0 else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { rollFolders(in: $0, depth: depth - 1) }
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

    // MARK: Roll cards

    @ObservationIgnored private var cardWrites: [UUID: Task<Void, Never>] = [:]

    /// Writes a roll's card into its folder (`RollCardFile`), a moment after the last change: the editor changes it at
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

    /// Brings a roll and its card together once its folder has been read: the card wins (it may have been changed
    /// in another catalogue or on another Mac); a roll without a card, from before 0.3, gets one.
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

    /// Moves a roll from one project to another, with its card (film, camera, notes). If the other project already
    /// has the folder, the roll only leaves the first.
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

    // MARK: A whole project

    /// A project's own folder: a link to each of its rolls, listed whole (`PhotoFolder.listWhole`), so its contact
    /// sheet shows every roll's photographs at their own paths.
    func viewFolder(for project: LabProject) -> URL? {
        let folder = directory.appendingPathComponent("Views", isDirectory: true).appendingPathComponent(project.id.uuidString, isDirectory: true)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var used: Set<String> = []
            for (index, roll) in project.rolls.enumerated() {
                guard let target = resolve(roll, in: project.id) else { continue }
                // In the project's order: the links sort as the rolls are listed.
                var name = String(format: "%03d ", index) + roll.name.replacingOccurrences(of: "/", with: "-")
                while used.contains(name) { name += " +" }
                used.insert(name)
                try fm.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: target)
            }
        } catch {
            return nil
        }
        PhotoFolder.listWhole(folder, true)
        return folder
    }

    /// The project whose own folder is `directory`.
    func project(viewFolder directory: URL?) -> LabProject? {
        guard let directory, directory.deletingLastPathComponent().lastPathComponent == "Views",
              let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
        return projects.first { $0.id == id }
    }

    /// The project and roll whose folder is `directory`.
    func find(folder directory: URL?) -> (project: LabProject, roll: LabRoll)? {
        guard let path = directory?.standardizedFileURL.path else { return nil }
        for project in projects {
            if let roll = project.rolls.first(where: { $0.folder == path }) { return (project, roll) }
        }
        return nil
    }

    /// A roll's folder, found again by its bookmark if it moved; the path is then brought up to date.
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

    /// Counts a roll's photographs and marks off the main thread.
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

    nonisolated static func stats(of folder: URL, store: SidecarStore?) -> RollStats {
        guard let listing = try? PhotoFolder.listing(in: folder) else { return RollStats(missing: true) }
        var stats = RollStats(total: listing.photos.count)
        stats.names = listing.photos.map(\.name)
        guard let store else { return stats }
        for photo in listing.photos where listing.sidecars[PhotoFolder.sidecarKey(photo.url)] != nil {
            guard let sidecar = try? store.read(photo: photo.url) else { continue }
            let summary = sidecar.summary
            if summary.flag == .pick { stats.picks += 1 }
            if summary.flag == .reject { stats.rejects += 1 }
            if summary.edited { stats.edited += 1 }
            // Every version counts: a frame developed on two films is found by either.
            for film in Set(sidecar.variants.compactMap { $0.edits?["film"].string }.filter { !$0.isEmpty }) { stats.films[film, default: 0] += 1 }
        }
        return stats
    }
}
