// Qlick Lab — GPL-3.0-only.
import Foundation

/// When a photograph was taken, as the camera wrote it: a wall clock without a time zone. A frame shot at 23:50 in
/// Tokyo is filed that day wherever it's imported, so nothing here is ever converted to the Mac's zone.
struct CaptureTime: Codable, Hashable, Comparable, Sendable {
    var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// EXIF's `2026:09:19 11:38:56` (dashes are read too).
    init?(exif text: String) {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 6, numbers[0] > 1900, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
              (0...23).contains(numbers[3]), (0...59).contains(numbers[4]), (0...60).contains(numbers[5]) else { return nil }
        (year, month, day, hour, minute, second) = (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], min(numbers[5], 59))
    }

    /// A file's date, read on this Mac's clock: the fallback for a photograph that says nothing itself.
    init(file date: Date, zone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        (year, month, day, hour, minute, second) = (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        (self.year, self.month, self.day, self.hour, self.minute, self.second) = (year, month, day, hour, minute, second)
    }

    /// Seconds on a clock of its own, for sorting and for telling a burst.
    var seconds: TimeInterval {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))?.timeIntervalSinceReferenceDate ?? 0
    }

    /// This time `minutes` later (earlier if negative): a camera whose clock was off, or left at home's zone.
    func shifted(minutes: Int) -> CaptureTime {
        guard minutes != 0 else { return self }
        let date = Date(timeIntervalSinceReferenceDate: seconds + Double(minutes) * 60)
        return CaptureTime(file: date, zone: TimeZone(secondsFromGMT: 0)!)
    }

    /// The day it's filed under when a day starts at `hour`: with 4, a frame at 02:30 belongs to the evening before.
    func filingDay(startingAt hour: Int) -> CaptureTime {
        guard hour > 0, self.hour < hour else { return self }
        return shifted(minutes: -24 * 60)
    }

    static func < (a: CaptureTime, b: CaptureTime) -> Bool { a.seconds < b.seconds }

    /// `2026:09:19 11:38:56`, the ledger's spelling.
    var text: String { String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second) }
}

/// One file of a source, as listed. No pixels are read.
struct ImportFile: Codable, Hashable, Sendable {
    var url: URL
    var size: Int
    var modified: Date?
    var name: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension }
    var isRaw: Bool { EditorModel.rawExtensions.contains(ext.lowercased()) }
}

/// A photograph of a source: its file and, when the camera wrote both, the JPEG beside its RAW.
struct ImportFrame: Identifiable, Hashable, Sendable {
    var file: ImportFile
    /// The JPEG of a RAW + JPEG pair.
    var companion: ImportFile?
    /// From the photograph itself; nil until it's read, or if it says nothing.
    var captured: CaptureTime?
    var camera: String?
    var lens: String?
    var id: URL { file.url }

    /// The time it's filed by: its own, else its file's date.
    var time: CaptureTime? { captured ?? file.modified.map { CaptureTime(file: $0) } }
    var dateFromFile: Bool { captured == nil && file.modified != nil }

    /// Pairs a folder's listing: a RAW and a JPEG of the same name in the same folder are one photograph.
    static func frames(from files: [ImportFile]) -> [ImportFrame] {
        var jpegs: [String: ImportFile] = [:]
        func key(_ file: ImportFile) -> String { file.url.deletingPathExtension().path.lowercased() }
        for file in files where ["jpg", "jpeg"].contains(file.ext.lowercased()) { jpegs[key(file)] = file }
        var taken: Set<URL> = [], frames: [ImportFrame] = []
        for file in files where file.isRaw {
            let jpeg = jpegs[key(file)]
            if let jpeg { taken.insert(jpeg.url) }
            frames.append(ImportFrame(file: file, companion: jpeg))
        }
        for file in files where !file.isRaw && !taken.contains(file.url) { frames.append(ImportFrame(file: file)) }
        return frames.sorted { $0.file.url.path.localizedStandardCompare($1.file.url.path) == .orderedAscending }
    }
}

/// Runs of frames taken in quick succession.
enum ImportBursts {
    /// Indices of `times` (in order) grouped where each follows the one before by at most `gap` seconds; only groups
    /// of two or more. Frames without a time break a run.
    static func groups(_ times: [CaptureTime?], gap: TimeInterval = 2) -> [Range<Int>] {
        var groups: [Range<Int>] = [], start = 0
        for index in 1..<max(times.count, 1) + 1 {
            let joined: Bool
            if index < times.count, let a = times[index - 1], let b = times[index] { joined = abs(b.seconds - a.seconds) <= gap } else { joined = false }
            if !joined {
                if index - start >= 2 { groups.append(start..<index) }
                start = index
            }
        }
        return groups
    }
}

/// What an import does with the files.
enum ImportMode: String, Codable, CaseIterable, Sendable {
    case copy, move, add
    var title: String {
        switch self {
        case .copy: "Copy to My Disk"
        case .move: "Move"
        case .add: "Leave Where They Are"
        }
    }
    /// The word on the panel's switch.
    var short: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        case .add: "Leave in Place"
        }
    }
    var help: String {
        switch self {
        case .copy: "Copies the photographs and checks every copy. The source is left as it is."
        case .move: "Copies and checks, then moves the source files to the Trash. Not for memory cards."
        case .add: "Copies nothing: each folder joins the Archive where it lies."
        }
    }
}

/// Which files of a RAW + JPEG pair are imported.
enum ImportPairs: String, Codable, CaseIterable, Sendable {
    case both, rawOnly, jpegOnly
    var title: String {
        switch self {
        case .both: "RAW and JPEG"
        case .rawOnly: "RAW only"
        case .jpegOnly: "JPEG only"
        }
    }
}

/// An import's choices: everything the panel sets, kept as a profile and in the journal.
struct ImportOptions: Codable, Equatable, Sendable {
    var mode = ImportMode.copy
    /// The folder the dated folders are made in.
    var destination: URL?
    /// The folders under the destination; empty puts everything in the destination itself.
    var folders = ImportTemplate.defaultFolders
    /// The files' new names, without extension; empty keeps the camera's names.
    var rename = ""
    /// `{job}`: the shoot's name.
    var job = ""
    var sequenceStart = 1
    /// Minutes added to every capture time: a camera clock that was off.
    var clockOffset = 0
    /// The hour a day starts at for filing: 4 keeps a night in one folder.
    var dayStart = 0
    var pairs = ImportPairs.both
    var skipDuplicates = true
    var skipRejected = true
    /// Read every copy back and compare it to the source.
    var verify = true
    /// A second, untouched copy of every file, in the same folders under this one.
    var secondCopy: URL?
    var ejectAfter = false
    var keywords = ""
    var creator = ""
    var copyright = ""
    var caption = ""
    /// The Archive the folders join, by name: required (an import never leaves photographs outside the library).
    var project = ""
    /// The same Archive by its identity, so renaming it doesn't make a new one at the next import. Nil when the
    /// name was typed (a new Archive) or for options saved before it.
    var projectID: UUID? = nil
    /// Each photograph's own Auto white balance and exposure under its recipe.
    var balanceEach = false
    /// Qlick Lab: a Box, or a Roll of it (`boxRollID`), the imported photographs are also put in. Optional, as every
    /// field added since the first options, so what was saved before still reads.
    var boxID: UUID? = nil
    var boxRollID: UUID? = nil
    /// Qlick Lab: the card of each Folder the import makes (`RollCardFile`): the film loaded, the camera, notes.
    var film: String? = nil
    var camera: String? = nil
    var notes: String? = nil

    /// The Box or Roll chosen, if any.
    var holder: Holder? {
        guard let boxID else { return nil }
        return boxRollID.map { .roll($0, box: boxID) } ?? .box(boxID)
    }

    /// The Folder card the import writes, or nil when nothing was typed.
    var card: RollCardFile? {
        let card = RollCardFile(film: (film ?? "").trimmingCharacters(in: .whitespaces), camera: (camera ?? "").trimmingCharacters(in: .whitespaces),
                                notes: (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return card.isBlank ? nil : card
    }
}

/// How the copies are laid out in folders under the destination: a ready-made structure, or one's own.
enum ImportStructure: String, CaseIterable, Identifiable, Sendable {
    case byDay, byMonth, byYear, byDayAndJob, oneFolder, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .byDay: "By Day"
        case .byMonth: "By Month"
        case .byYear: "By Year"
        case .byDayAndJob: "By Day and Job"
        case .oneFolder: "One Folder"
        case .custom: "Custom"
        }
    }

    /// Its template; nil for Custom, which is the text typed.
    var template: String? {
        switch self {
        case .byDay: "{yyyy}/{yyyy}-{mm}-{dd}"
        case .byMonth: "{yyyy}/{yyyy}-{mm}"
        case .byYear: "{yyyy}"
        case .byDayAndJob: "{yyyy}/{yyyy}-{mm}-{dd} {job}"
        case .oneFolder: ""
        case .custom: nil
        }
    }

    /// What it makes, as an example beside its name.
    var example: String {
        switch self {
        case .byDay: "2026/2026-09-19"
        case .byMonth: "2026/2026-09"
        case .byYear: "2026"
        case .byDayAndJob: "2026/2026-09-19 Job"
        case .oneFolder: "all in the destination"
        case .custom: "your own"
        }
    }

    /// The structure a template is, Custom when it's none of the ready-made ones.
    init(template: String) {
        self = Self.allCases.first { $0.template == template } ?? .custom
    }
}

/// How the copies are named: the camera's own names, a ready-made form, or one's own.
enum ImportNaming: String, CaseIterable, Identifiable, Sendable {
    case camera, dateSequence, jobSequence, dateName, dateTime, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Camera’s Names"
        case .dateSequence: "Date_0001"
        case .jobSequence: "Job_001"
        case .dateName: "Date-Name"
        case .dateTime: "Date_Time"
        case .custom: "Custom"
        }
    }

    var template: String? {
        switch self {
        case .camera: ""
        case .dateSequence: "{date}_{seq:4}"
        case .jobSequence: "{job}_{seq:3}"
        case .dateName: "{date}-{name}"
        case .dateTime: "{date}_{time}"
        case .custom: nil
        }
    }

    var example: String {
        switch self {
        case .camera: "L1004394"
        case .dateSequence: "20260919_0001"
        case .jobSequence: "Job_001"
        case .dateName: "20260919-L1004394"
        case .dateTime: "20260919_113856"
        case .custom: "your own"
        }
    }

    init(template: String) {
        self = Self.allCases.first { $0.template == template } ?? .custom
    }
}

/// Folder and file name templates: text with `{tokens}`, as the batch export's names.
enum ImportTemplate {
    static let defaultFolders = "{yyyy}/{yyyy}-{mm}-{dd}"
    /// The tags a custom template's buttons insert, in plain words: the folders' and, with the sequence and the
    /// camera's name, the files'.
    static func tags(forFiles files: Bool) -> [(title: String, token: String)] {
        var tags: [(title: String, token: String)] = [("year", "{yyyy}"), ("month", "{mm}"), ("day", "{dd}"), ("month name", "{month}"), ("job", "{job}"),
                                                      ("camera", "{camera}"), ("lens", "{lens}"), ("card", "{card}")]
        if files { tags += [("seq", "{seq:4}"), ("name", "{name}"), ("time", "{time}")] }
        return tags
    }

    static let tokens = ["yyyy", "yy", "mm", "dd", "month", "hh", "min", "ss", "date", "time", "name", "seq", "job", "camera", "lens", "archive", "card"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    struct Values {
        var time: CaptureTime?
        var name = ""
        var sequence = 1
        var job = ""
        var camera = ""
        var lens = ""
        var project = ""
        var card = ""
    }

    /// `template` with its tokens replaced. Unknown tokens stay as they're written, so a typo shows.
    static func expand(_ template: String, _ values: Values) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; rest = ""; break }
            let token = String(rest[rest.index(after: open)..<close])
            out += value(token, values) ?? "{\(token)}"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func value(_ token: String, _ v: Values) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let t = v.time
        func two(_ n: Int?) -> String { n.map { String(format: "%02d", $0) } ?? "00" }
        switch parts.first ?? "" {
        case "yyyy": return t.map { String(format: "%04d", $0.year) } ?? "0000"
        case "yy": return t.map { String(format: "%02d", $0.year % 100) } ?? "00"
        case "mm": return two(t?.month)
        case "dd": return two(t?.day)
        case "month": return t.map { months[min(max($0.month, 1), 12) - 1] } ?? "Undated"
        case "hh": return two(t?.hour)
        case "min": return two(t?.minute)
        case "ss": return two(t?.second)
        case "date": return t.map { String(format: "%04d%02d%02d", $0.year, $0.month, $0.day) } ?? "00000000"
        case "time": return t.map { String(format: "%02d%02d%02d", $0.hour, $0.minute, $0.second) } ?? "000000"
        case "name": return v.name
        case "seq":
            let width = parts.count > 1 ? min(max(Int(parts[1]) ?? 4, 1), 8) : 4
            return String(format: "%0\(width)d", v.sequence)
        case "job": return v.job
        case "camera": return v.camera
        case "lens": return v.lens
        // `{project}`, its name before 0.4, still reads.
        case "archive", "project": return v.project
        case "card": return v.card
        default: return nil
        }
    }

    /// `token` put in `text` over the selection `range` (UTF-16, as a text field counts): the new text and where the
    /// cursor goes, after the token.
    static func insert(_ token: String, into text: String, at range: NSRange) -> (text: String, caret: Int) {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let new = ns.replacingCharacters(in: NSRange(location: location, length: length), with: token)
        return (new, location + (token as NSString).length)
    }

    /// One name of a path: nothing a file system refuses, no leading period, never empty.
    static func component(_ text: String, fallback: String = "Untitled") -> String {
        var name = String(text.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "-" : $0 })
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
        return name.isEmpty ? fallback : name
    }

    /// A folder template as its folders, top first. A frame without any date goes to `Undated`.
    static func folders(_ template: String, _ values: Values) -> [String] {
        guard values.time != nil || !usesDate(template) else { return ["Undated"] }
        return template.split(separator: "/").map { component(expand(String($0), values)) }
    }

    static func usesDate(_ template: String) -> Bool {
        ["{yyyy", "{yy", "{mm", "{dd", "{month", "{hh", "{min", "{ss", "{date", "{time"].contains { template.contains($0) }
    }

    /// Why `template` can't be used, or nil.
    static func problem(_ template: String, folders: Bool) -> String? {
        if template.filter({ $0 == "{" }).count != template.filter({ $0 == "}" }).count { return "A { is missing its }." }
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let token = rest[rest.index(after: open)..<close].split(separator: ":").first.map(String.init) ?? ""
            if !tokens.contains(token), token != "project" { return "“{\(token)}” isn’t a tag the lab knows." }
            rest = rest[rest.index(after: close)...]
        }
        if !folders, template.contains("/") { return "A file name can’t contain /." }
        return nil
    }
}

/// One file's place in the plan.
struct PlannedFile: Codable, Equatable, Sendable {
    var source: ImportFile
    var destination: URL
    /// The second copy's place.
    var backup: URL?
}

/// One photograph's place in the plan.
struct PlannedFrame: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Copied (or added).
        case new
        /// The ledger says this catalog already imported it.
        case duplicate
        /// A file of the same name and size already lies at the destination.
        case present
    }
    var id: URL
    var files: [PlannedFile]
    var status = Status.new
    /// Under the destination, with `/`.
    var folder: String
    /// The camera's name was taken: it was numbered.
    var renamed = false
    /// Where the ledger says a duplicate went.
    var earlier: String?
    var bytes: Int { files.reduce(0) { $0 + $1.source.size } }
}

/// Where everything will go, before anything is written.
struct ImportPlan: Equatable, Sendable {
    struct Folder: Equatable, Identifiable, Sendable {
        var path: String
        var count = 0
        var bytes = 0
        /// It doesn't exist yet.
        var isNew = true
        var id: String { path }
    }

    var frames: [PlannedFrame] = []
    var folders: [Folder] = []
    var problems: [String] = []

    /// What is copied: not the duplicates.
    var toCopy: [PlannedFrame] { frames.filter { $0.status == .new } }
    var bytes: Int { toCopy.reduce(0) { $0 + $1.bytes } }
    var fileCount: Int { toCopy.reduce(0) { $0 + $1.files.count } }
    var duplicates: Int { frames.count - toCopy.count }

    /// What the plan asks of the file system and of the ledger, so tests answer for both.
    struct World {
        /// The size of the file there, or nil if there's none.
        var size: (URL) -> Int? = { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        var folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        /// Where the ledger says the file went, if it was imported before.
        var imported: (ImportFile, CaptureTime?) -> String? = { _, _ in nil }
    }

    /// Lays `frames` out under the options' destination. Pure: nothing is touched.
    static func make(_ frames: [ImportFrame], options: ImportOptions, card: String = "", world: World = World()) -> ImportPlan {
        var plan = ImportPlan()
        if options.mode == .add {
            plan.frames = frames.map { frame in
                PlannedFrame(id: frame.id, files: files(of: frame, options.pairs).map { PlannedFile(source: $0, destination: $0.url) },
                             folder: frame.file.url.deletingLastPathComponent().path)
            }
            plan.summarise(root: nil, world: world)
            return plan
        }
        guard let root = options.destination else {
            plan.problems.append("Choose where the photographs go.")
            return plan
        }
        for (template, folders) in [(options.folders, true), (options.rename, false)] {
            if let problem = ImportTemplate.problem(template, folders: folders) { plan.problems.append(problem) }
        }
        var taken: Set<String> = []
        var sequence = options.sequenceStart
        // In the order they were taken, so a sequence follows the shoot.
        let ordered = frames.enumerated().sorted { a, b in
            let (x, y) = (a.element.time?.seconds, b.element.time?.seconds)
            if let x, let y, x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
        for frame in ordered {
            let sources = files(of: frame, options.pairs)
            guard let first = sources.first else { continue }
            let time = frame.time?.shifted(minutes: options.clockOffset)
            var values = ImportTemplate.Values(time: time?.filingDay(startingAt: options.dayStart), name: first.stem, sequence: sequence,
                                               job: options.job, camera: frame.camera ?? "", lens: frame.lens ?? "", project: options.project, card: card)
            let parts = ImportTemplate.folders(options.folders, values)
            let folder = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            // The name carries the real time, the folder the filing day.
            values.time = time
            let wanted = options.rename.isEmpty ? first.stem : ImportTemplate.component(ImportTemplate.expand(options.rename, values), fallback: first.stem)
            if let earlier = options.skipDuplicates ? world.imported(first, frame.captured) : nil {
                plan.frames.append(PlannedFrame(id: frame.id, files: sources.map { PlannedFile(source: $0, destination: folder.appendingPathComponent($0.name)) },
                                                status: .duplicate, folder: parts.joined(separator: "/"), earlier: earlier))
                continue
            }
            // One name for the pair; numbered until no file of the pair meets another.
            var stem = wanted, number = 1, present = false
            while true {
                let targets = sources.map { folder.appendingPathComponent(stem).appendingPathExtension($0.ext) }
                let clash = targets.contains { taken.contains($0.path.lowercased()) }
                let sizes = zip(sources, targets).map { (source: $0.size, there: world.size($1)) }
                if !clash, sizes.allSatisfy({ $0.there == nil }) { break }
                // The same names with the same sizes: these very files, copied before.
                if !clash, sizes.allSatisfy({ $0.there == $0.source }) { present = true; break }
                number += 1
                stem = "\(wanted)-\(number)"
            }
            let planned = sources.map { source -> PlannedFile in
                let target = folder.appendingPathComponent(stem).appendingPathExtension(source.ext)
                taken.insert(target.path.lowercased())
                let backup = options.secondCopy.map { parts.reduce($0) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent(source.name) }
                return PlannedFile(source: source, destination: target, backup: backup)
            }
            plan.frames.append(PlannedFrame(id: frame.id, files: planned, status: present ? .present : .new, folder: parts.joined(separator: "/"),
                                            renamed: stem != wanted))
            sequence += 1
        }
        plan.summarise(root: root, world: world)
        return plan
    }

    private static func files(of frame: ImportFrame, _ pairs: ImportPairs) -> [ImportFile] {
        guard let jpeg = frame.companion else { return [frame.file] }
        switch pairs {
        case .both: return [frame.file, jpeg]
        case .rawOnly: return [frame.file]
        case .jpegOnly: return [jpeg]
        }
    }

    private mutating func summarise(root: URL?, world: World) {
        var index: [String: Int] = [:]
        for frame in frames where frame.status == .new {
            if index[frame.folder] == nil {
                index[frame.folder] = folders.count
                let url = root.map { frame.folder.split(separator: "/").reduce($0) { $0.appendingPathComponent(String($1), isDirectory: true) } }
                folders.append(Folder(path: frame.folder, isNew: url.map { !world.folderExists($0) } ?? false))
            }
            folders[index[frame.folder]!].count += 1
            folders[index[frame.folder]!].bytes += frame.bytes
        }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
