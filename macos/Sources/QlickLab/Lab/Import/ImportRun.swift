// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation

/// One frame of an import, as the room shows it.
enum ImportFrameState: Sendable { case waiting, copying, verified, failed }

/// An import as it runs: what the room, the sidebar and the quit question read.
@MainActor @Observable final class ImportRun {
    let total: Int
    let totalBytes: Int
    let sourceName: String
    let order: [URL]
    let started = Date()
    private(set) var done = 0
    private(set) var doneBytes = 0
    private(set) var failed = 0
    /// Bytes a second, smoothed.
    private(set) var rate: Double = 0
    private(set) var currentName: String?
    /// The disk or card the import waits for.
    var waitingFor: String?
    var paused = false
    private(set) var finished = false
    var stopped = false
    private(set) var states: [URL: ImportFrameState] = [:]
    /// Where each photograph went, as its copy is checked: to show it, and to open it.
    private(set) var written: [URL: URL] = [:]
    private(set) var failures: [(name: String, reason: String)] = []
    /// The folders made, in the order their first photograph arrived.
    private(set) var folders: [URL] = []
    var ejected = false
    /// What couldn't be written of marks, recipes or metadata.
    var notes: [String] = []

    @ObservationIgnored private var samples: [(time: Date, bytes: Int)] = []

    init(journal: ImportJournal) {
        total = journal.items.count
        totalBytes = journal.totalBytes
        sourceName = journal.sourceName
        order = journal.items.map(\.id)
        // A resumed import starts from what was done.
        for item in journal.items where item.settled {
            done += 1
            states[item.id] = item.done ? .verified : .failed
            if item.failed { failed += 1 }
            if let photo = item.photo { written[item.id] = photo; note(folder: photo.deletingLastPathComponent()) }
        }
        doneBytes = journal.doneBytes
        failures = journal.failures
    }

    var fraction: Double { totalBytes > 0 ? min(Double(doneBytes) / Double(totalBytes), 1) : (total > 0 ? Double(done) / Double(total) : 1) }
    /// Seconds left at the present rate; nil while it isn't known.
    var remaining: TimeInterval? {
        guard rate > 1, !finished else { return nil }
        return Double(max(totalBytes - doneBytes, 0)) / rate
    }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    func state(of id: URL) -> ImportFrameState { states[id] ?? .waiting }

    func add(bytes: Int) {
        doneBytes = max(doneBytes + bytes, 0)
        let now = Date()
        samples.append((now, doneBytes))
        samples.removeAll { now.timeIntervalSince($0.time) > 4 }
        if let first = samples.first, now.timeIntervalSince(first.time) > 0.4 {
            rate = Double(doneBytes - first.bytes) / now.timeIntervalSince(first.time)
        }
    }
    func began(_ id: URL, name: String) { currentName = name; if states[id] == nil { states[id] = .copying } }
    func settled(_ item: ImportJournal.Item) {
        done += 1
        states[item.id] = item.done ? .verified : .failed
        if item.failed {
            failed += 1
            failures += item.files.compactMap { $0.status == .failed ? ($0.planned.source.name, $0.error ?? "Failed") : nil }
        }
        if let photo = item.photo, item.done { written[item.id] = photo; note(folder: photo.deletingLastPathComponent()) }
    }
    private func note(folder: URL) { if !folders.contains(folder) { folders.append(folder) } }
    func finish(stopped: Bool) { finished = true; self.stopped = stopped; currentName = nil; rate = 0 }

    /// "312 / 840 · 22.4 of 60.1 GB · 184 MB/s · 3 min left · 0 errors"
    var figures: String {
        let size = ByteCountFormatter()
        size.countStyle = .file
        var parts = ["\(min(done + (finished ? 0 : 1), total)) / \(total)", "\(size.string(fromByteCount: Int64(doneBytes))) of \(size.string(fromByteCount: Int64(totalBytes)))"]
        if !finished {
            if rate > 1 { parts.append("\(size.string(fromByteCount: Int64(rate)))/s") }
            if let remaining { parts.append(Self.duration(remaining) + " left") }
        }
        parts.append(failed == 1 ? "1 error" : "\(failed) errors")
        return parts.joined(separator: " · ")
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let seconds = Int(seconds.rounded())
        if seconds < 60 { return "\(max(seconds, 1)) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}

/// What the copying thread has to say, gathered between two looks from the main thread: an import of thousands of
/// files never floods the interface with one message a chunk.
private final class ImportMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var started: (Int, String)?
    private var settled: [ImportJournal.Item] = []
    private var waiting: String??
    private var finished: ImportJournal?

    func post(_ event: ImportRunner.Event) {
        lock.withLock {
            switch event {
            case .bytes(let count): bytes += count
            case .started(let item, let name): started = (item, name)
            case .settled(_, let item): settled.append(item)
            case .waiting(let name): waiting = .some(name)
            case .finished(let journal): finished = journal
            }
        }
    }

    func take() -> (bytes: Int, started: (Int, String)?, settled: [ImportJournal.Item], waiting: String??, finished: ImportJournal?) {
        lock.withLock {
            defer { bytes = 0; started = nil; settled = []; waiting = nil; finished = nil }
            return (bytes, started, settled, waiting, finished)
        }
    }
}

extension ImportSession {
    /// Starts the import of what's checked. Nothing happens if something stands in its way (`blocker`).
    func start() {
        guard blocker == nil, let source else { return }
        let frames = includedFrames, options = options, ledger = ledger
        var times: [URL: CaptureTime] = [:]
        for frame in frames { if let captured = frame.captured { times[frame.id] = captured } }
        let marks = marks
        if options.mode == .add { return addInPlace(frames, marks: marks) }
        Task {
            // The plan once more, now, on the disk as it is.
            let plan = await Task.detached(priority: .userInitiated) { () -> ImportPlan in
                var world = ImportPlan.World()
                world.imported = { file, captured in options.skipDuplicates ? ledger.imported(file, captured: captured) : nil }
                return ImportPlan.make(frames, options: options, card: source.name, world: world)
            }.value
            guard !plan.toCopy.isEmpty, plan.problems.isEmpty, self.run == nil else { return }
            let journal = ImportJournal(plan: plan, options: options, marks: marks, times: times, volume: source.uuid, sourceName: source.name, sourceRoot: source.root)
            self.begin(journal)
        }
    }

    /// Takes up an import that was interrupted.
    func resume() {
        guard run == nil, let journal = unfinished else { return }
        setUnfinished(nil)
        begin(journal)
    }

    /// Forgets an interrupted import. What it already copied stays where it is.
    func discardUnfinished() {
        setUnfinished(nil)
        ImportJournal.remove()
    }

    private func begin(_ journal: ImportJournal) {
        let run = ImportRun(journal: journal)
        self.run = run
        let runner = ImportRunner()
        self.runner = runner
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Importing photographs")
        let mailbox = ImportMailbox(), ledger = ledger
        Task.detached(priority: .utility) {
            _ = runner.run(journal, ledger: ledger) { mailbox.post($0) }
        }
        Task { [weak self] in
            // The recipes, once each, before the first photograph asks for one.
            var recipes: [String: EditState] = [:]
            if let self {
                for name in Set(journal.items.compactMap(\.marks.recipe)) {
                    guard let preset = self.model.presets.first(where: { $0.name == name }) else { run.notes.append("The recipe “\(name)” isn’t there any more."); continue }
                    if let state = await self.model.labRecipeState(preset) { recipes[name] = state } else { run.notes.append("The recipe “\(name)” couldn’t be read.") }
                }
            }
            var unwritten = 0
            // A resumed import: what was copied before it stopped may not have had its marks written yet.
            if let self {
                let earlier = journal.items.filter { $0.done && !$0.marks.isEmpty && $0.photo.map { (try? SidecarStore.readRaw(photo: $0)) ?? nil == nil } == true }
                if !earlier.isEmpty { await self.finish(earlier, journal: journal, recipes: recipes, run: run, counted: true); await self.flushMarks(run) }
            }
            while let self {
                try? await Task.sleep(for: .milliseconds(100))
                let news = mailbox.take()
                if news.bytes != 0 { run.add(bytes: news.bytes) }
                if let (item, name) = news.started, journal.items.indices.contains(item) { run.began(journal.items[item].id, name: name) }
                if let waiting = news.waiting { run.waitingFor = waiting }
                if !news.settled.isEmpty {
                    await self.finish(news.settled, journal: journal, recipes: recipes, run: run)
                    unwritten += news.settled.count
                    if unwritten >= 20 { unwritten = 0; await self.flushMarks(run) }
                }
                if let end = news.finished {
                    await self.flushMarks(run)
                    self.ended(end, run: run, stopped: runner.cancelled)
                    return
                }
            }
        }
    }

    /// A photograph's copy is checked: its marks, its recipe and its words are written, and its folder joins the project.
    private func finish(_ items: [ImportJournal.Item], journal: ImportJournal, recipes: [String: EditState], run: ImportRun, counted: Bool = false) async {
        let options = journal.options
        var balances: [URL: (temperature: Double, tint: Double)] = [:]
        if options.balanceEach {
            let photos = items.filter { $0.done && $0.marks.recipe != nil }.compactMap(\.photo)
            if !photos.isEmpty { balances = await model.labAutoBalances(photos) }
        }
        for item in items {
            if !counted { run.settled(item) }
            guard item.done, let photo = item.photo else { continue }
            let recipe = item.marks.recipe.flatMap { recipes[$0] }
            if !model.labWriteImported(photo, marks: item.marks, recipe: recipe, balance: balances[photo], matchExposure: options.balanceEach), run.notes.count < 20 {
                run.notes.append("\(photo.lastPathComponent): its marks or recipe couldn’t be saved.")
            }
            if let name = item.marks.recipe, recipe != nil, let preset = model.presets.first(where: { $0.name == name }) { model.notePresetApplied(preset.url, to: photo) }
            if ImportMetadata(options: options).isEmpty == false {
                let metadata = ImportMetadata(options: options)
                Task.detached(priority: .utility) { metadata.write(beside: photo) }
            }
        }
        addRolls(run.folders, project: options.project)
    }

    private func flushMarks(_ run: ImportRun) async {
        let failures = await model.labFlushSidecars()
        for (photo, reason) in failures where run.notes.count < 20 { run.notes.append("\(photo.lastPathComponent): \(reason)") }
    }

    /// The folders photographs arrived in become rolls of the project named (made if it isn't there).
    private func addRolls(_ folders: [URL], project name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !folders.isEmpty else { return }
        let projects = model.lab.projects
        let project = projects.projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? projects.create(named: name)
        let had = Set(project.rolls.map(\.folder))
        let new = folders.filter { !had.contains($0.standardizedFileURL.path) }
        guard !new.isEmpty else { return }
        projects.sidecars = model.sidecarLookup?.store
        projects.addRolls(new, to: project.id)
    }

    private func ended(_ journal: ImportJournal, run: ImportRun, stopped: Bool) {
        runner = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        run.finish(stopped: stopped)
        // An account of it in each folder, with the hashes.
        let folders = Set(journal.items.filter(\.done).map(\.folder))
        if let root = journal.options.destination {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmm"
            let stamp = formatter.string(from: journal.started)
            Task.detached(priority: .utility) {
                for folder in folders {
                    let url = folder.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
                    try? journal.report(folder: folder).write(to: url.appendingPathComponent("Import report \(stamp).txt"), atomically: true, encoding: .utf8)
                }
            }
        }
        if journal.remaining > 0 { setUnfinished(journal) } else { ImportJournal.remove() }
        // The folder open meanwhile shows what arrived; the previews follow by themselves.
        model.library.refreshNow()
        model.lab.projects.countAll()
        importedNow()
        if journal.options.ejectAfter, journal.remaining == 0, journal.failures.isEmpty, let volume = source?.volume {
            run.ejected = (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil
        }
        if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Stops the import after the file being copied. What's done stays; the rest can be taken up later.
    func stop() { runner?.cancel() }
    func togglePause() {
        guard let runner, let run else { return }
        runner.paused.toggle()
        run.paused = runner.paused
    }
    /// Leaves the finished import's account and goes back to the source.
    func dismissRun() { if run?.finished == true { run = nil } }

    /// Add in Place: nothing is copied. Each folder becomes a roll, and the marks made here are written beside
    /// the photographs where they lie.
    private func addInPlace(_ frames: [ImportFrame], marks: [URL: ImportMarks]) {
        Task {
            var recipes: [String: EditState] = [:]
            for name in Set(marks.values.compactMap(\.recipe)) {
                if let preset = model.presets.first(where: { $0.name == name }), let state = await model.labRecipeState(preset) { recipes[name] = state }
            }
            for frame in frames {
                guard let mark = marks[frame.id] else { continue }
                model.labWriteImported(frame.id, marks: mark, recipe: mark.recipe.flatMap { recipes[$0] })
            }
            await model.labFlushSidecars()
            var folders: [URL] = []
            for frame in frames {
                let folder = frame.file.url.deletingLastPathComponent()
                if !folders.contains(folder) { folders.append(folder) }
            }
            let name = options.project.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { model.lab.importFolders(folders) } else { addRolls(folders, project: name) }
            if let first = folders.first { model.lab.open(folder: first) }
        }
    }

    /// Opens what the import brought in on its contact sheet.
    func openImported() {
        guard let run, let first = run.folders.first else { return }
        let name = options.project.trimmingCharacters(in: .whitespaces)
        if run.folders.count > 1, let project = model.lab.projects.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            model.lab.openWhole(project)
        } else {
            model.lab.open(folder: first)
        }
        self.run = nil
    }

    func eject() {
        guard let volume = source?.volume, run == nil || run?.finished == true else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}

/// The words an import adds to every photograph: in a standard `.xmp` file beside it, which is where other
/// programs look for a RAW's keywords and copyright. One that's already there is left as it is.
struct ImportMetadata: Sendable {
    var keywords: [String]
    var creator: String
    var copyright: String
    var caption: String

    init(options: ImportOptions) {
        keywords = options.keywords.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        creator = options.creator.trimmingCharacters(in: .whitespaces)
        copyright = options.copyright.trimmingCharacters(in: .whitespaces)
        caption = options.caption.trimmingCharacters(in: .whitespaces)
    }

    var isEmpty: Bool { keywords.isEmpty && creator.isEmpty && copyright.isEmpty && caption.isEmpty }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var packet: String {
        var body = ""
        if !keywords.isEmpty { body += "   <dc:subject><rdf:Bag>\(keywords.map { "<rdf:li>\(Self.escape($0))</rdf:li>" }.joined())</rdf:Bag></dc:subject>\n" }
        if !creator.isEmpty { body += "   <dc:creator><rdf:Seq><rdf:li>\(Self.escape(creator))</rdf:li></rdf:Seq></dc:creator>\n" }
        if !copyright.isEmpty {
            body += "   <dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.escape(copyright))</rdf:li></rdf:Alt></dc:rights>\n"
            body += "   <xmpRights:Marked>True</xmpRights:Marked>\n"
        }
        if !caption.isEmpty { body += "   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.escape(caption))</rdf:li></rdf:Alt></dc:description>\n" }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/">
        \(body)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }

    /// `L1004394.DNG` → `L1004394.xmp`, never over one that's there.
    @discardableResult func write(beside photo: URL) -> Bool {
        guard !isEmpty else { return false }
        let url = photo.deletingPathExtension().appendingPathExtension("xmp")
        return (try? Data(packet.utf8).write(to: url, options: .withoutOverwriting)) != nil
    }
}
