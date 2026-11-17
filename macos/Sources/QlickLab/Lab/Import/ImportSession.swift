// Qlick Lab — GPL-3.0-only.
import AppKit
import ImageIO
import Observation

/// A place photographs are imported from.
struct ImportSource: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case card, disk, folder }
    /// Where its photographs are listed from: a card's `DCIM`, a folder itself.
    var root: URL
    /// Its volume's mount point, when it's a card or a disk.
    var volume: URL?
    var name: String
    var kind: Kind
    var uuid: String?
    var id: URL { root }
    var symbol: String {
        switch kind {
        case .card: "sdcard"
        case .disk: "externaldrive"
        case .folder: "folder"
        }
    }
}

/// The volumes photographs may come from: memory cards (they hold a `DCIM` folder) and other disks that can be
/// taken out. Nothing is read from them here but their names.
enum ImportVolumes {
    static func mounted() -> [ImportSource] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeUUIDStringKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false else { return nil }
            let external = values.volumeIsInternal != true || values.volumeIsRemovable == true || values.volumeIsEjectable == true
            guard external else { return nil }
            let name = values.volumeName ?? volume.lastPathComponent
            if let dcim = cardFolder(of: volume) {
                return ImportSource(root: dcim, volume: volume, name: name, kind: .card, uuid: values.volumeUUIDString)
            }
            return ImportSource(root: volume, volume: volume, name: name, kind: .disk, uuid: values.volumeUUIDString)
        }
    }

    /// A camera's folder at the top of a volume, however it's spelled.
    static func cardFolder(of volume: URL) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.first { $0.lastPathComponent.uppercased() == "DCIM" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    static func folder(_ url: URL) -> ImportSource {
        ImportSource(root: url, volume: nil, name: url.lastPathComponent, kind: .folder, uuid: nil)
    }
}

/// Reads a source without developing anything: its files, then what each says of itself.
enum ImportScan {
    /// Every photograph under `root`, sub-folders included. Hidden files and packages are skipped.
    static func files(in root: URL, cancelled: () -> Bool = { false }) -> [ImportFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [ImportFile] = []
        for case let url as URL in walker {
            if cancelled() { return [] }
            guard PhotoFolder.extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(ImportFile(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate))
        }
        return files
    }

    struct Facts: Sendable {
        var captured: CaptureTime?
        var camera: String?
        var lens: String?
    }

    /// When and with what a photograph was taken, from its header.
    static func facts(of url: URL) -> Facts {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return Facts() }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let text = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String
        func clean(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text
        }
        return Facts(captured: text.flatMap(CaptureTime.init(exif:)), camera: clean(tiff[kCGImagePropertyTIFFModel]), lens: clean(exif[kCGImagePropertyExifLensModel]))
    }

    /// A photograph as its camera rendered it, `maxPixels` on its long side at most: the preview inside the file,
    /// so nothing is developed. The whole file is read only when it holds none.
    static func preview(of url: URL, maxPixels: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceShouldCacheImmediately: true]
            if !EditorModel.rawExtensions.contains(url.pathExtension.lowercased()) { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
            else { options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }
}

/// Which frames the import's grid shows.
enum ImportFilter: String, CaseIterable, Sendable {
    case all, new, checked, picks, unmarked, rejects, bursts
    var title: String {
        switch self {
        case .all: "All"
        case .new: "New"
        case .checked: "To Import"
        case .picks: "Picks"
        case .unmarked: "Unmarked"
        case .rejects: "Rejects"
        case .bursts: "Bursts"
        }
    }
    var help: String {
        switch self {
        case .all: "Every photograph of the source"
        case .new: "Those this catalog hasn’t imported yet"
        case .checked: "Those the import will take"
        case .picks: "Those ringed"
        case .unmarked: "Those neither ringed nor crossed out"
        case .rejects: "Those crossed out"
        case .bursts: "Those taken within two seconds of another"
        }
    }
}

enum ImportView: String, Sendable { case grid, loupe, compare }

/// How an import shows itself while it runs.
enum ImportProgressStyle: String, CaseIterable, Sendable {
    case automatic, filmLab, compact
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .filmLab: "Film Lab"
        case .compact: "Compact"
        }
    }
    static let key = "qlick.importProgressStyle"
    /// Above this many photographs Automatic shows the compact list.
    static let compactAbove = 500
}

/// The import room's state: the source being looked at, what's chosen of it, where it will go, and the import
/// running. It reads the source and never writes to it: marks made here live here until each photograph's copy is
/// checked.
@MainActor @Observable final class ImportSession {
    @ObservationIgnored unowned let model: EditorModel

    // MARK: Sources

    private(set) var volumes: [ImportSource] = []
    private(set) var recent: [URL] = (UserDefaults.standard.stringArray(forKey: "qlick.importRecent") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    private(set) var source: ImportSource?
    /// Cards put in since the room was last looked at: the sidebar says so.
    var cards: [ImportSource] { volumes.filter { $0.kind == .card } }

    // MARK: The source's photographs

    private(set) var frames: [ImportFrame] = []
    private(set) var scanning = false
    /// How many frames have said when they were taken.
    private(set) var factsRead = 0
    var datesReady: Bool { !scanning && factsRead >= frames.count }
    /// Frames this catalog imported before (the ledger).
    private(set) var known: Set<URL> = []
    /// Frames of a burst, with their burst's number.
    private(set) var bursts: [URL: Int] = [:]
    /// What the grid shows, in order.
    private(set) var shown: [ImportFrame] = []

    // MARK: Triage

    /// Frames unchecked by hand.
    private(set) var excluded: Set<URL> = []
    private(set) var marks: [URL: ImportMarks] = [:]
    private(set) var selected: Set<URL> = []
    private(set) var current: URL?
    @ObservationIgnored private var anchor: URL?
    var filter = ImportFilter.all { didSet { if filter != oldValue { refreshShown() } } }
    var view = ImportView.grid
    var cellSize: Double = UserDefaults.standard.object(forKey: "qlick.importCell") as? Double ?? 190 {
        didSet { UserDefaults.standard.set(cellSize, forKey: "qlick.importCell") }
    }
    /// The loupe shows the camera's preview beside the recipe's development.
    var splitBefore = true

    // MARK: Where it goes

    var options = ImportSession.loadOptions() {
        didSet {
            guard options != oldValue else { return }
            Self.saveOptions(options)
            if options.skipDuplicates != oldValue.skipDuplicates || options.skipRejected != oldValue.skipRejected { refreshShown() }
            replan()
        }
    }
    private(set) var plan = ImportPlan()
    private(set) var planning = false
    private(set) var freeSpace: Int?
    private(set) var profiles: [String: ImportOptions] = ImportSession.loadProfiles()
    var progressStyle = UserDefaults.standard.string(forKey: ImportProgressStyle.key).flatMap(ImportProgressStyle.init) ?? .automatic {
        didSet { UserDefaults.standard.set(progressStyle.rawValue, forKey: ImportProgressStyle.key) }
    }

    // MARK: The import running

    var run: ImportRun?
    /// An import a quit, a crash or a pulled card left unfinished.
    private(set) var unfinished: ImportJournal?
    @ObservationIgnored var runner: ImportRunner?
    @ObservationIgnored var activity: NSObjectProtocol?

    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var ledgerCache: ImportLedger?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var index: [URL: Int] = [:]

    init(model: EditorModel) {
        self.model = model
        guard NSClassFromString("XCTestCase") == nil else { return }
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        if let journal = ImportJournal.read(), journal.remaining > 0 { unfinished = journal } else { ImportJournal.remove() }
    }

    /// The catalog's memory of what it imported.
    var ledger: ImportLedger {
        let url = ImportLedger.file(inCatalog: model.lab.projects.directory)
        if let ledgerCache, ledgerCache.url == url { return ledgerCache }
        let ledger = ImportLedger(url: url)
        ledgerCache = ledger
        return ledger
    }

    // MARK: Sources

    func refreshVolumes() {
        volumes = ImportVolumes.mounted()
        // The source's card was taken out: its photographs can't be read any more.
        if let source, source.volume != nil, !volumes.contains(where: { $0.root == source.root }), run == nil { close() }
    }

    func open(_ source: ImportSource) {
        guard run == nil else { return }
        scan?.cancel()
        self.source = source
        frames = []; index = [:]; shown = []; known = []; bursts = [:]
        excluded = []; marks = [:]; selected = []; current = nil; anchor = nil
        factsRead = 0; scanning = true; view = .grid; filter = .all
        plan = ImportPlan()
        if source.kind == .folder { remember(source.root) }
        let root = source.root
        scan = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) { ImportScan.files(in: root, cancelled: { Task.isCancelled }) }.value
            guard let self, !Task.isCancelled else { return }
            self.frames = ImportFrame.frames(from: files)
            self.index = Dictionary(uniqueKeysWithValues: self.frames.enumerated().map { ($1.id, $0) })
            self.scanning = false
            self.refreshShown()
            self.current = self.shown.first?.id
            // Then what each says of itself, a batch at a time, so the grid is there at once.
            let urls = self.frames.map(\.id)
            for start in stride(from: 0, to: urls.count, by: 48) {
                let batch = Array(urls[start..<min(start + 48, urls.count)])
                let read = await Task.detached(priority: .utility) { () -> [ImportScan.Facts] in
                    var facts = [ImportScan.Facts](repeating: ImportScan.Facts(), count: batch.count)
                    facts.withUnsafeMutableBufferPointer { buffer in
                        guard let out = buffer.baseAddress else { return }
                        nonisolated(unsafe) let slots = out
                        DispatchQueue.concurrentPerform(iterations: batch.count) { slots[$0] = ImportScan.facts(of: batch[$0]) }
                    }
                    return facts
                }.value
                guard !Task.isCancelled else { return }
                for (url, facts) in zip(batch, read) {
                    guard let at = self.index[url] else { continue }
                    self.frames[at].captured = facts.captured; self.frames[at].camera = facts.camera; self.frames[at].lens = facts.lens
                }
                self.factsRead = min(start + batch.count, urls.count)
            }
            self.factsRead = urls.count
            self.refreshKnown()
            self.refreshShown()
            self.replan()
        }
    }

    func close() {
        scan?.cancel(); scan = nil
        source = nil; frames = []; index = [:]; shown = []; selected = []; current = nil; scanning = false; plan = ImportPlan()
    }

    /// A folder (or a disk) chosen in the panel.
    func chooseFolder(startingAt folder: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import From"
        panel.message = "Choose a folder of photographs. Its sub-folders are read too."
        panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if let folder { panel.directoryURL = folder }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open(ImportVolumes.folder(url)) }
        }
    }

    private func remember(_ folder: URL) {
        recent = ([folder] + recent.filter { $0.standardizedFileURL != folder.standardizedFileURL }).prefix(6).map { $0 }
        UserDefaults.standard.set(recent.map(\.path), forKey: "qlick.importRecent")
    }

    // MARK: What's shown

    func frame(_ id: URL) -> ImportFrame? { index[id].map { frames[$0] } }
    func marks(for id: URL) -> ImportMarks { marks[id] ?? ImportMarks() }

    /// Whether the import takes this frame.
    func included(_ id: URL) -> Bool {
        if excluded.contains(id) { return false }
        if options.skipRejected, marks[id]?.flag == "reject" { return false }
        if options.skipDuplicates, known.contains(id) { return false }
        return true
    }
    var includedFrames: [ImportFrame] { frames.filter { included($0.id) } }
    var includedCount: Int { frames.reduce(0) { $0 + (included($1.id) ? 1 : 0) } }

    private func refreshKnown() {
        let ledger = ledger
        known = Set(frames.filter { ledger.imported($0.file, captured: $0.captured) != nil }.map(\.id))
        let ordered = frames.sorted { ($0.time?.seconds ?? 0, $0.file.url.path) < ($1.time?.seconds ?? 0, $1.file.url.path) }
        var found: [URL: Int] = [:]
        for (number, group) in ImportBursts.groups(ordered.map(\.captured)).enumerated() {
            for at in group { found[ordered[at].id] = number }
        }
        bursts = found
    }

    func refreshShown() {
        let kept = frames.filter { frame in
            let mark = marks[frame.id]
            switch filter {
            case .all: return true
            case .new: return !known.contains(frame.id)
            case .checked: return included(frame.id)
            case .picks: return mark?.flag == "pick"
            case .unmarked: return mark?.flag == nil
            case .rejects: return mark?.flag == "reject"
            case .bursts: return bursts[frame.id] != nil
            }
        }
        // As they were taken, once that's known; a file's own date stands in till then.
        shown = kept.sorted { a, b in
            let (x, y) = (a.time?.seconds ?? 0, b.time?.seconds ?? 0)
            return x != y ? x < y : a.file.url.path.localizedStandardCompare(b.file.url.path) == .orderedAscending
        }
        if let current, !shown.contains(where: { $0.id == current }) { self.current = shown.first?.id; selected = [] }
    }

    // MARK: Selection

    /// The frames the keys act on: the selection, or the current frame alone.
    var targets: [URL] {
        // In the comparison the keys mark the pane last clicked, not all of them.
        if view == .compare || selected.isEmpty { return current.map { [$0] } ?? [] }
        return shown.map(\.id).filter(selected.contains)
    }
    /// Makes `id` the current frame and leaves the selection as it is.
    func focus(_ id: URL) { current = id }

    func click(_ id: URL, command: Bool = false, shift: Bool = false) {
        if shift, let anchor = anchor ?? current, let from = shown.firstIndex(where: { $0.id == anchor }), let to = shown.firstIndex(where: { $0.id == id }) {
            selected = Set(shown[min(from, to)...max(from, to)].map(\.id))
        } else if command {
            if selected.isEmpty, let current { selected = [current] }
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else {
            selected = []
            anchor = id
        }
        current = id
    }

    func selectAll() { selected = Set(shown.map(\.id)) }
    func selectNone() { selected = [] }

    /// Moves the current frame by `step` frames (`extend` grows the selection, as ⇧ with the arrows).
    func move(by step: Int, extend: Bool = false) {
        guard !shown.isEmpty else { return }
        let at = current.flatMap { id in shown.firstIndex { $0.id == id } } ?? 0
        let next = shown[min(max(at + step, 0), shown.count - 1)].id
        if extend { click(next, shift: true) } else { click(next) }
    }

    // MARK: Marks

    private func change(_ ids: [URL], _ edit: (inout ImportMarks) -> Void) {
        for id in ids {
            var mark = marks[id] ?? ImportMarks()
            edit(&mark)
            marks[id] = mark.isEmpty ? nil : mark
        }
        if filter != .all || options.skipRejected { refreshShown() }
        replan()
    }

    /// Rings or crosses out the targets, or lifts the mark if they all carry it.
    func toggle(flag: String) {
        let ids = targets
        let all = !ids.isEmpty && ids.allSatisfy { marks[$0]?.flag == flag }
        change(ids) { $0.flag = all ? nil : flag }
    }
    func unmark() { change(targets) { $0.flag = nil } }
    func rate(_ stars: Int) { change(targets) { $0.rating = min(max(stars, 0), 5) } }
    func rotate(by quarter: Int) { change(targets) { $0.rotation = (($0.rotation + quarter) % 4 + 4) % 4 } }
    /// Gives `recipe` (a recipe's name, nil for none) to `ids`, or to the targets.
    func assign(recipe: String?, to ids: [URL]? = nil) { change(ids ?? targets) { $0.recipe = recipe } }

    /// Checks or unchecks the targets: all checked if any wasn't.
    func toggleIncluded(_ ids: [URL]? = nil) {
        let ids = ids ?? targets
        let check = ids.contains { excluded.contains($0) }
        for id in ids { if check { excluded.remove(id) } else { excluded.insert(id) } }
        if filter == .checked { refreshShown() }
        replan()
    }
    func setIncluded(_ on: Bool, _ ids: [URL]) {
        for id in ids { if on { excluded.remove(id) } else { excluded.insert(id) } }
        if filter == .checked { refreshShown() }
        replan()
    }
    /// Keeps the first frame of every burst checked and unchecks the others.
    func keepFirstOfBursts() {
        var seen: Set<Int> = []
        let ordered = frames.sorted { ($0.time?.seconds ?? 0) < ($1.time?.seconds ?? 0) }
        for frame in ordered { if let burst = bursts[frame.id], !seen.insert(burst).inserted { excluded.insert(frame.id) } }
        refreshShown(); replan()
    }

    /// The recipes given, with how many frames each.
    var recipesInUse: [String: Int] {
        var counts: [String: Int] = [:]
        for frame in frames where included(frame.id) { if let recipe = marks[frame.id]?.recipe { counts[recipe, default: 0] += 1 } }
        return counts
    }

    // MARK: The plan

    /// Lays the checked frames out again, off the main thread, a moment after the last change.
    func replan() {
        planTask?.cancel()
        guard source != nil, datesReady else { return }
        let frames = includedFrames, options = options, card = source?.name ?? "", ledger = ledger
        planning = true
        planTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let (plan, free) = await Task.detached(priority: .userInitiated) { () -> (ImportPlan, Int?) in
                var world = ImportPlan.World()
                // What's already known was left out above; the plan has only the destination to look at.
                world.imported = { file, captured in options.skipDuplicates ? ledger.imported(file, captured: captured) : nil }
                return (ImportPlan.make(frames, options: options, card: card, world: world), options.destination.flatMap(ImportCopier.freeSpace(at:)))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.plan = plan
            self.freeSpace = free
            self.planning = false
        }
    }

    /// Bytes the import writes: the copies and their second copies.
    var bytesNeeded: Int { options.mode == .add ? 0 : plan.bytes }
    /// Why the import can't start, in the user's words; nil when it can.
    var blocker: String? {
        if run != nil { return "An import is running." }
        guard source != nil else { return "Choose a source." }
        if scanning { return "Reading the source…" }
        if frames.isEmpty { return "No photographs here." }
        if !datesReady { return "Reading the dates…" }
        if options.mode != .add, options.destination == nil { return "Choose where the photographs go." }
        if options.mode == .move, source?.kind == .card { return "Move isn’t offered for memory cards: copy, then format the card in the camera." }
        if let problem = plan.problems.first { return problem }
        if planning { return "Working out where the photographs go…" }
        if plan.toCopy.isEmpty {
            let imported = plan.duplicates > 0 || (!known.isEmpty && frames.allSatisfy { known.contains($0.id) || !included($0.id) } && options.skipDuplicates)
            return imported ? "Everything here is already imported." : "Nothing is checked."
        }
        if options.mode != .add, let freeSpace, freeSpace < bytesNeeded { return "Not enough room on the destination." }
        if let second = options.secondCopy, let free = ImportCopier.freeSpace(at: second), free < plan.bytes { return "Not enough room for the second copy." }
        return nil
    }

    // MARK: Options and profiles

    private static let optionsKey = "qlick.importOptions", profilesKey = "qlick.importProfiles"
    private static func loadOptions() -> ImportOptions {
        guard NSClassFromString("XCTestCase") == nil, let data = UserDefaults.standard.data(forKey: optionsKey),
              let options = try? JSONDecoder().decode(ImportOptions.self, from: data) else { return ImportOptions() }
        return options
    }
    private static func saveOptions(_ options: ImportOptions) {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: optionsKey) }
    }
    private static func loadProfiles() -> [String: ImportOptions] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey), let profiles = try? JSONDecoder().decode([String: ImportOptions].self, from: data) else { return [:] }
        return profiles
    }
    func saveProfile(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        profiles[name] = options
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.profilesKey) }
    }
    func deleteProfile(_ name: String) {
        profiles[name] = nil
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.profilesKey) }
    }
    func apply(profile name: String) { if let profile = profiles[name] { options = profile } }

    func setUnfinished(_ journal: ImportJournal?) { unfinished = journal }
    /// After an import, what it copied is known: the grid greys it.
    func importedNow() { refreshKnown(); refreshShown(); replan() }
}
