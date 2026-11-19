// Qlick Lab — GPL-3.0-only.
import Foundation

/// What the import decided for one photograph before it was copied: written into its edits once its copy is checked.
struct ImportMarks: Codable, Equatable, Sendable {
    var rating = 0
    /// "pick" or "reject".
    var flag: String?
    /// Clockwise quarter turns.
    var rotation = 0
    /// The recipe's file name, without extension.
    var recipe: String?
    var isEmpty: Bool { rating == 0 && flag == nil && rotation == 0 && recipe == nil }
}

/// An import under way or interrupted, as the batch export keeps its own (`BatchJournal`): what was asked, and how
/// far each file got, so that quitting, a card pulled out or a crash never means starting again, and never means
/// copying a file twice.
struct ImportJournal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case waiting, done, present, failed, skipped }

    struct File: Codable, Equatable, Sendable {
        var planned: PlannedFile
        var status = Status.waiting
        /// Where it ended up (numbered if its name was taken).
        var written: URL?
        var hash: String?
        var backupDone = false
        var error: String?
    }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: URL
        var folder: String
        var captured: CaptureTime?
        var files: [File]
        var marks = ImportMarks()
        /// Its marks, recipe and metadata are written.
        var finished = false
        var done: Bool { files.allSatisfy { $0.status == .done || $0.status == .present } }
        var failed: Bool { files.contains { $0.status == .failed } }
        var settled: Bool { files.allSatisfy { $0.status != .waiting } }
        /// The photograph itself (not its JPEG companion), where it now lies.
        var photo: URL? { files.first?.written }
    }

    static let schema = 1
    var schema = ImportJournal.schema
    var id = UUID()
    /// To the second, as the file keeps it.
    var started = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    var options: ImportOptions
    /// The source's volume, to know it again when it comes back, and its name.
    var volume: String?
    var sourceName: String
    /// The folder the source's files were listed under: gone while its card or disk is away.
    var sourceRoot: URL?
    var items: [Item]
    var destinationBookmark: Data?

    var remaining: Int { items.filter { !$0.settled }.count }
    var failures: [(name: String, reason: String)] {
        items.flatMap { item in item.files.compactMap { file in file.status == .failed ? (file.planned.source.name, file.error ?? "Failed") : nil } }
    }
    var totalBytes: Int { items.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.planned.source.size } } }
    var doneBytes: Int { items.reduce(0) { $0 + $1.files.reduce(0) { $0 + ($1.status == .waiting ? 0 : $1.planned.source.size) } } }

    init(plan: ImportPlan, options: ImportOptions, marks: [URL: ImportMarks], times: [URL: CaptureTime], volume: String?, sourceName: String, sourceRoot: URL? = nil) {
        self.options = options
        self.sourceRoot = sourceRoot
        self.volume = volume
        self.sourceName = sourceName
        items = plan.toCopy.map { frame in
            Item(id: frame.id, folder: frame.folder, captured: times[frame.id], files: frame.files.map { File(planned: $0) }, marks: marks[frame.id] ?? ImportMarks())
        }
        destinationBookmark = options.destination.flatMap { try? $0.bookmarkData() }
    }

    static var url: URL { AppDataLocations.supportDirectory.appendingPathComponent("import-journal.json") }

    func write(to url: URL = ImportJournal.url) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL = ImportJournal.url) -> ImportJournal? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let journal = try? decoder.decode(ImportJournal.self, from: data), journal.schema == schema else { return nil }
        return journal
    }

    static func remove(at url: URL = ImportJournal.url) { try? FileManager.default.removeItem(at: url) }

    /// A readable account of the import, kept in each roll's folder: every file, where it went and its SHA-256.
    func report(folder: String) -> String {
        var lines = ["Qlick Lab import report", "Started: \(ISO8601DateFormatter().string(from: started))", "Source: \(sourceName)",
                     "Verified: \(options.verify ? "every copy read back and compared (SHA-256)" : "no")", ""]
        for item in items where item.folder == folder {
            for file in item.files {
                let name = file.written?.lastPathComponent ?? file.planned.destination.lastPathComponent
                switch file.status {
                case .done: lines.append("\(file.hash ?? "-")  \(name)  (from \(file.planned.source.name))")
                case .present: lines.append("\(file.hash ?? "-")  \(name)  (already there)")
                case .failed: lines.append("FAILED  \(file.planned.source.name): \(file.error ?? "")")
                case .skipped: lines.append("SKIPPED  \(file.planned.source.name)")
                case .waiting: lines.append("NOT COPIED  \(file.planned.source.name)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// What a catalog has imported, so a card read twice doesn't fill the disk twice. The lab has no database (the
/// folders are the library), so this small file in the catalog's own folder is the memory: one JSON line per file,
/// appended as each is copied, so a crash loses nothing.
final class ImportLedger: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var size: Int
        /// `CaptureTime.text`, or empty.
        var captured: String
        var hash: String?
        var destination: String
        var imported: Date
    }

    let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    static func file(inCatalog directory: URL) -> URL { directory.appendingPathComponent("import-ledger.jsonl") }

    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            // A line cut short by a crash is skipped.
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else { continue }
            entries[Self.key(entry.name, entry.size, entry.captured)] = entry
        }
    }

    /// A camera file is known by its name, its size and when it was taken: the three together don't repeat.
    static func key(_ name: String, _ size: Int, _ captured: String) -> String { "\(name.lowercased())|\(size)|\(captured)" }

    var count: Int { lock.withLock { entries.count } }

    /// Where `file` went when it was imported, if it was and still lies there.
    func imported(_ file: ImportFile, captured: CaptureTime?) -> String? {
        let entry = lock.withLock { entries[Self.key(file.name, file.size, captured?.text ?? "")] }
        guard let entry, FileManager.default.fileExists(atPath: entry.destination) else { return nil }
        return entry.destination
    }

    /// Qlick Lab: forgets what was imported into `folders` (their paths), so a later import takes it again.
    func forget(folders: Set<String>) {
        guard !folders.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        lock.withLock {
            let before = entries.count
            entries = entries.filter { !folders.contains((($0.value.destination as NSString).deletingLastPathComponent as NSString).standardizingPath) }
            guard entries.count != before else { return }
            var text = Data()
            for entry in entries.values.sorted(by: { $0.imported < $1.imported }) {
                guard let line = try? encoder.encode(entry) else { continue }
                text.append(line); text.append(10)
            }
            try? text.write(to: url, options: .atomic)
        }
    }

    func record(_ file: ImportFile, captured: CaptureTime?, hash: String?, destination: URL) {
        let entry = Entry(name: file.name, size: file.size, captured: captured?.text ?? "", hash: hash, destination: destination.path, imported: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(10)
        lock.withLock {
            entries[Self.key(entry.name, entry.size, entry.captured)] = entry
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }
}
