// Qlick Lab — GPL-3.0-only.
import CryptoKit
import Foundation
import Observation

/// One photograph of the catalogue as the index keeps it: what its file says (capture time, camera, lens, exposure,
/// size) and what its sidecar says (marks, words, developments, recipe), each read again only when its file changes.
struct IndexedPhoto: Codable, Equatable, Sendable {
    var path: String
    var size: Int?
    var modified: Date?
    /// The sidecar as last read: its date and size, empty without one.
    var sidecarStamp = ""
    var captured: Date?
    var camera: String?
    var lens: String?
    var iso: Double?
    var exposure: Double?
    var aperture: Double?
    var focalLength: Double?
    var width: Double?
    var height: Double?
    var rating = 0
    var flag: String?
    var label: String?
    var keywords: [String] = []
    var title = ""
    var caption = ""
    var edited = false
    /// The films its versions are developed on, by stock id.
    var films: [String] = []
    var recipe: String?
    /// When its sidecar was last written.
    var editedAt: Date?

    init(path: String) { self.path = path }

    /// The day it belongs to: its capture time, or its file's date without one.
    var day: Date? { captured ?? modified }

    mutating func adopt(facts: FrameFacts) {
        captured = facts.date; camera = facts.camera; lens = facts.lens
        iso = facts.iso; exposure = facts.exposure; aperture = facts.aperture; focalLength = facts.focalLength
        width = facts.pixels.map { Double($0.width) }; height = facts.pixels.map { Double($0.height) }
    }

    mutating func adopt(sidecar: PhotoSidecar?) {
        let summary = sidecar?.summary ?? LibrarySummary()
        adopt(summary: summary)
        films = Array(Set(sidecar?.variants.compactMap { $0.edits?["film"].string }.filter { !$0.isEmpty } ?? [])).sorted()
        let recipe = sidecar?.raw["variants"].array.first?["recipe"].string ?? ""
        self.recipe = recipe.isEmpty ? nil : recipe
    }

    /// Takes the marks and words of `summary`; whether anything changed.
    @discardableResult mutating func adopt(summary: LibrarySummary) -> Bool {
        let before = self
        rating = summary.rating; flag = summary.flag?.rawValue; edited = summary.edited
        label = summary.words.label?.rawValue; keywords = summary.words.keywords
        title = summary.words.title; caption = summary.words.caption
        return self != before
    }
}

/// Every photograph of every Archive (those removed from the lab aside), indexed once and kept in the caches:
/// what All Photographs, Picks, By Date, the Smart Rolls and the search are drawn from. Read off the main thread;
/// a later reading lists the folders again and reads only the files that changed.
@MainActor @Observable final class CatalogIndex {
    nonisolated static let version = 2

    /// Moves when what the index knows changes.
    private(set) var generation = 0
    /// Reading files now (the first time, most of all).
    private(set) var building = false
    @ObservationIgnored private(set) var photos: [String: IndexedPhoto] = [:]
    /// The paths in their folders' order.
    @ObservationIgnored private(set) var order: [String] = []
    /// Has been read at least once, from the caches or the disk.
    @ObservationIgnored private(set) var ready = false

    /// What a reading needs, asked of the lab when it starts: the folders, where sidecars are read, the import dates.
    struct Inputs: Sendable {
        var folders: [URL]
        var store: SidecarStore?
        var imported: [String: Date]
    }
    @ObservationIgnored var inputs: (() -> Inputs?)?
    /// Told after each reading that changed something.
    @ObservationIgnored var changed: (() -> Void)?

    @ObservationIgnored private var cacheURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var importDates: [String: Date] = [:]

    /// The cache of a catalogue: in the app's caches, named after the catalogue's folder.
    nonisolated static func cacheFile(forCatalog directory: URL) -> URL {
        let name = SHA256.hash(data: Data(directory.labStandardized.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return AppDataLocations.cachesDirectory.appendingPathComponent("Catalog Index", isDirectory: true).appendingPathComponent(name + ".json")
    }

    private struct CacheFile: Codable {
        var version: Int
        var photos: [IndexedPhoto]
    }

    /// Another catalogue: its cache is read now (what it held shows at once), the disk after.
    func open(catalog directory: URL, cache: Bool = true) {
        task?.cancel(); task = nil; waiting?.cancel(); waiting = nil
        cacheURL = cache ? Self.cacheFile(forCatalog: directory) : nil
        photos = [:]; order = []; ready = false
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let file = try? JSONDecoder().decode(CacheFile.self, from: data), file.version == Self.version {
            for photo in file.photos { photos[photo.path] = photo }
            order = file.photos.map(\.path)
            ready = true
        }
        generation += 1
    }

    /// Reads the folders again in a moment; asked again meanwhile, it waits a little more.
    func refresh(after delay: Duration = .milliseconds(800)) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    /// Reads the folders again now (only what changed is read); a reading under way is followed by another.
    func refreshNow() {
        guard task == nil else { again = true; return }
        guard let inputs = inputs?() else { return }
        building = true
        let old = photos, cacheURL = cacheURL
        importDates = inputs.imported
        task = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                Self.build(folders: inputs.folders, old: old, store: inputs.store)
            }.value
            guard let self else { return }
            self.task = nil
            if let built, !Task.isCancelled {
                if built.photos != self.photos || built.order != self.order {
                    self.photos = built.photos
                    self.order = built.order
                    self.generation += 1
                    self.changed?()
                    if let cacheURL {
                        let file = CacheFile(version: Self.version, photos: built.order.compactMap { built.photos[$0] })
                        Task.detached(priority: .background) {
                            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? JSONEncoder().encode(file).write(to: cacheURL, options: .atomic)
                        }
                    }
                }
                self.ready = true
            }
            self.building = false
            if self.again { self.again = false; self.refreshNow() }
        }
    }

    /// The marks on screen, laid over what the index read: a pick shows in Picks at once. Whether any changed.
    @discardableResult func adopt(_ summaries: [URL: LibrarySummary]) -> Bool {
        var changed = false
        for (item, summary) in summaries where item.variantID == nil && summary.problem == nil {
            let path = item.labStandardized.path
            guard var photo = photos[path], photo.adopt(summary: summary) else { continue }
            photos[path] = photo
            changed = true
        }
        if changed { generation += 1 }
        return changed
    }

    /// One photograph put in by hand, as a reading would (the tests).
    func insert(_ photo: IndexedPhoto) {
        if photos[photo.path] == nil { order.append(photo.path) }
        photos[photo.path] = photo
        ready = true
        generation += 1
    }

    /// When the photograph was imported, if the import's ledger knows.
    func imported(_ path: String) -> Date? { importDates[path] }

    // MARK: Reading

    /// The index of `folders`' photographs: those of `old` whose files haven't changed are kept as they are, the
    /// others read (their facts, their sidecars), several at once. Nil when cancelled.
    nonisolated static func build(folders: [URL], old: [String: IndexedPhoto], store: SidecarStore?) -> (photos: [String: IndexedPhoto], order: [String])? {
        var photos: [String: IndexedPhoto] = [:], order: [String] = []
        struct Work { var path: String; var url: URL; var facts: Bool; var sidecar: Bool; var inside: Bool }
        var work: [Work] = []
        for folder in folders {
            if Task.isCancelled { return nil }
            guard let listing = try? PhotoFolder.listing(in: folder) else { continue }
            for file in listing.photos {
                let path = file.url.labStandardized.path
                guard photos[path] == nil else { continue }
                let sidecar = listing.sidecars[PhotoFolder.sidecarKey(file.url)]
                let stamp = sidecar.map { "\($0.modified?.timeIntervalSince1970 ?? 0)|\($0.size ?? 0)" } ?? ""
                var photo = old[path] ?? IndexedPhoto(path: path)
                let known = old[path] != nil
                let facts = !known || photo.size != file.size || photo.modified != file.modified
                let marks = !known || photo.sidecarStamp != stamp
                photo.size = file.size; photo.modified = file.modified; photo.sidecarStamp = stamp
                // A DNG keeping its sidecar inside it: its date is known once it's read (below).
                let inside = sidecar?.url == file.url
                if !inside { photo.editedAt = sidecar?.modified }
                photos[path] = photo
                order.append(path)
                if facts || marks { work.append(Work(path: path, url: file.url, facts: facts, sidecar: marks, inside: inside)) }
            }
        }
        guard !work.isEmpty else { return (photos, order) }
        let results = Results(count: work.count)
        DispatchQueue.concurrentPerform(iterations: max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))) { lane in
            var index = lane
            let lanes = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
            while index < work.count {
                if Task.isCancelled { return }
                let item = work[index]
                var photo = photos[item.path]!
                if item.facts { photo.adopt(facts: FrameFacts.read(item.url)) }
                if item.sidecar {
                    let sidecar: PhotoSidecar?
                    if let store { sidecar = (try? store.read(photo: item.url)) ?? nil }
                    else { sidecar = ((try? SidecarStore.readRaw(photo: item.url)) ?? nil).flatMap { try? PhotoSidecar(raw: $0) } }
                    photo.adopt(sidecar: sidecar)
                    // A DNG keeping its sidecar inside: its file's date is when it was last written, if it holds one.
                    if item.inside { photo.editedAt = sidecar == nil ? nil : photo.modified }
                }
                results.set(index, photo)
                index += lanes
            }
        }
        if Task.isCancelled { return nil }
        for (index, item) in work.enumerated() { if let read = results.get(index) { photos[item.path] = read } }
        return (photos, order)
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [IndexedPhoto?]
        init(count: Int) { list = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ photo: IndexedPhoto) { lock.lock(); list[index] = photo; lock.unlock() }
        func get(_ index: Int) -> IndexedPhoto? { lock.lock(); defer { lock.unlock() }; return list[index] }
    }
}

/// The photographs the last import brought in, in the catalogue's folder (`last-import.json`, top-level key
/// `qlick`): what Last Import shows. Written at the end of each import, copied or left in place.
enum LastImportFile {
    static let fileName = "last-import.json"
    static let schema = 1

    struct Content: Codable, Equatable {
        var schema = LastImportFile.schema
        var date: Date
        var photos: [String]
    }
    private struct File: Codable { var qlick: Content }

    static func url(inCatalog directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func read(inCatalog directory: URL) -> Content? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(inCatalog: directory)), let file = try? decoder.decode(File.self, from: data),
              file.qlick.schema <= schema else { return nil }
        return file.qlick
    }

    static func write(_ photos: [URL], inCatalog directory: URL, date: Date = Date()) {
        guard !photos.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var seen: Set<String> = []
        let paths = photos.map { $0.photoFile.labStandardized.path }.filter { seen.insert($0).inserted }
        let content = Content(date: date, photos: paths)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(File(qlick: content)).write(to: url(inCatalog: directory), options: .atomic)
    }
}
