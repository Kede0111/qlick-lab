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
    /// Add in Place: nothing is copied, each photograph is taken in where it lies.
    let adding: Bool
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
        adding = false
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

    /// Add in Place: the photographs taken in where they lie, one by one.
    init(adding photos: [URL], sourceName: String) {
        total = photos.count
        totalBytes = 0
        self.sourceName = sourceName
        order = photos
        adding = true
    }

    /// Add in Place: a photograph is taken in, its marks written beside it (or not, and why).
    func added(_ id: URL, failure: String?) {
        done += 1
        states[id] = failure == nil ? .verified : .failed
        written[id] = id
        if let failure { failed += 1; failures.append((id.lastPathComponent, failure)) }
        note(folder: id.deletingLastPathComponent())
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
        var parts = ["\(min(done + (finished ? 0 : 1), total)) / \(total)"]
        if !adding { parts.append("\(size.string(fromByteCount: Int64(doneBytes))) of \(size.string(fromByteCount: Int64(totalBytes)))") }
        if !finished, adding, done > 0, elapsed > 2 { parts.append(Self.duration(elapsed / Double(done) * Double(total - done)) + " left") }
        if !finished, !adding {
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
    /// The Archive the import's options name: by its identity first, so a renamed Archive is still found, then by
    /// name. Nil for a name no Archive has yet (the import makes it) and for none.
    var chosenProject: LabProject? {
        let projects = model.lab.projects
        if let id = options.projectID, let project = projects.ordinary.first(where: { $0.id == id }) { return project }
        let name = options.project.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : projects.project(named: name)
    }

    /// Chooses an Archive for the import, by identity.
    func choose(project: LabProject?) {
        options.project = project?.name ?? ""
        options.projectID = project?.id
    }

    /// Chooses a new Archive by its name: made when the import starts.
    func chooseNewArchive(named name: String) {
        options.project = name
        options.projectID = nil
    }

    /// Whether an Archive is set: one that's there, or a new one's name. An import needs one.
    var hasArchive: Bool { chosenProject != nil || !options.project.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The name a new Archive is offered under: the card's or the folder's, and today's date, “M11 · 2026-11-19”.
    var suggestedArchiveName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var base = source?.kind == .card ? (source?.volume?.lastPathComponent ?? source?.name ?? "Import") : (source?.name ?? "Import")
        // A camera's own folder says nothing: the card's (or the folder's holding it) name does.
        if base.uppercased() == "DCIM", let parent = source?.root.deletingLastPathComponent().lastPathComponent, !parent.isEmpty, parent != "/" { base = parent }
        return model.lab.projects.uniqueName("\(base) · \(formatter.string(from: Date()))")
    }

    /// The Box or Roll chosen for the import, while it's still there.
    var chosenHolder: Holder? {
        guard let holder = options.holder, model.lab.projects.exists(holder), !model.lab.projects.isSmart(holder) else { return nil }
        return holder
    }

    /// The bursts among the photographs imported, each made a stack under its first frame (`Stacking.bursts`).
    private func stackImported(_ photos: [(photo: URL, captured: CaptureTime?, camera: String?)]) {
        model.lab.projects.stackBursts(photos.map { ($0.photo.labStandardized.path, $0.captured?.seconds, $0.camera) })
    }

    /// Puts the imported photographs in the Box or Roll chosen, if any, after those it holds.
    private func fileInHolder(_ photos: [URL], options: ImportOptions) {
        guard !photos.isEmpty, let holder = options.holder, model.lab.projects.exists(holder), !model.lab.projects.isSmart(holder) else { return }
        model.lab.projects.addFrames(photos, to: holder)
    }

    /// Starts the import of what's checked. Nothing happens if something stands in its way (`blocker`).
    func start() {
        guard blocker == nil, let source else { return }
        let frames = includedFrames, options = options, ledger = ledger
        var times: [URL: CaptureTime] = [:]
        for frame in frames { if let captured = frame.captured { times[frame.id] = captured } }
        let marks = marks
        if options.mode == .add { return addInPlace(frames, marks: marks) }
        starting = true
        Task {
            defer { self.starting = false }
            // The plan once more, now, on the disk as it is.
            let plan = await Task.detached(priority: .userInitiated) { () -> ImportPlan in
                var world = ImportPlan.World()
                world.imported = { file, captured in options.skipDuplicates ? ledger.imported(file, captured: captured) : nil }
                return ImportPlan.make(frames, options: options, card: source.name, world: world)
            }.value
            guard self.run == nil else { return }
            // Never nothing at all: what stands in the way is said.
            if let problem = plan.problems.first { self.model.error = problem; self.replan(); return }
            if plan.toCopy.isEmpty { self.model.error = "Nothing is left to import: everything checked is already there."; self.replan(); return }
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
                    // Written in the background: the copying never waits for it.
                    if unwritten >= 20 { unwritten = 0; self.flushMarksLater(run) }
                }
                if let end = news.finished {
                    self.flushMarksLater(run)
                    self.ended(end, run: run, stopped: runner.cancelled)
                    return
                }
            }
        }
    }

    /// A photograph's copy is checked: its marks, its recipe and its words are written, and its folder joins the project.
    private func finish(_ items: [ImportJournal.Item], journal: ImportJournal, recipes: [String: EditState], run: ImportRun, counted: Bool = false) async {
        let options = journal.options
        // Each photograph's own white balance comes after, in the background (`ended`): the import doesn't wait.
        for item in items {
            if !counted { run.settled(item) }
            guard item.done, let photo = item.photo else { continue }
            let recipe = item.marks.recipe.flatMap { recipes[$0] }
            if !model.labWriteImported(photo, marks: item.marks, recipe: recipe, matchExposure: options.balanceEach), run.notes.count < 20 {
                run.notes.append("\(photo.lastPathComponent): its marks or recipe couldn’t be saved.")
            }
            if let name = item.marks.recipe, recipe != nil, let preset = model.presets.first(where: { $0.name == name }) { model.notePresetApplied(preset.url, to: photo) }
            if ImportMetadata(options: options).isEmpty == false {
                let metadata = ImportMetadata(options: options)
                Task.detached(priority: .utility) { metadata.write(beside: photo) }
            }
        }
        addRolls(run.folders, options: options)
    }

    private func flushMarks(_ run: ImportRun) async {
        let failures = await model.labFlushSidecars()
        for (photo, reason) in failures where run.notes.count < 20 { run.notes.append("\(photo.lastPathComponent): \(reason)") }
    }

    /// Qlick Lab: the marks and recipes written in the background (into a DNG, a fraction of a second each), the
    /// photographs already there to work on: what's queued is what the lab shows. The progress shows in the sidebar.
    private func flushMarksLater(_ run: ImportRun) {
        Task { [weak self] in await self?.flushMarks(run) }
        model.labWatchSaving()
    }

    /// The folders photographs arrived in become Folders of the Archive named (made if it isn't there), each with the
    /// card typed at the import (film, camera, notes). An import always names an Archive (`blocker`); one started
    /// without (an interrupted import from before 0.4) goes to “To Sort”, so nothing imported is left outside the
    /// library. A folder an Archive's Folder already holds isn't added again: the tree shows it.
    private func addRolls(_ folders: [URL], options: ImportOptions) {
        let name = options.project.trimmingCharacters(in: .whitespaces)
        guard !folders.isEmpty else { return }
        let projects = model.lab.projects
        let project: LabProject
        if let id = options.projectID, let found = projects.archive(id) { project = found }
        else { project = name.isEmpty ? projects.toSort() : projects.project(named: name) ?? projects.create(named: name) }
        // Pins the Archive by identity once it's made, so a rename meanwhile doesn't make a second one.
        if self.options.projectID == nil, self.options.project.trimmingCharacters(in: .whitespaces) == name, !name.isEmpty { self.options.projectID = project.id }
        let held = project.rolls.map(\.folder)
        let new = folders.map(\.labStandardized).filter { folder in
            !held.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") }
        }
        if !new.isEmpty {
            projects.sidecars = model.sidecarLookup?.store
            projects.addRolls(new, to: project.id)
        }
        // The film card on the Folders this import made or filled, written into each folder (`Roll.qlickroll`).
        guard let card = options.card, let current = projects.archive(project.id) else { return }
        for folder in folders.map(\.labStandardized) {
            guard let roll = current.rolls.first(where: { $0.folder == folder.path }) else { continue }
            projects.updateRoll(roll.id, in: project.id) { roll in
                if !card.film.isEmpty { roll.film = card.film }
                if !card.camera.isEmpty { roll.camera = card.camera }
                if !card.notes.isEmpty { roll.notes = card.notes }
            }
        }
    }

    /// Leave in Place: the folder chosen is the Folder, with every folder under it at every depth, as the disk has
    /// it. From a disk (or a card), the deepest folder holding all the photographs added: a whole disk isn't added.
    nonisolated static func placeRoot(of photos: [URL], source: URL, sourceIsFolder: Bool) -> URL? {
        let root = source.labStandardized
        if sourceIsFolder, !photos.isEmpty, photos.allSatisfy({ $0.labStandardized.path.hasPrefix(root.path + "/") }) { return root }
        let folders = Set(photos.map { $0.deletingLastPathComponent().labStandardized.path })
        guard var common = folders.first?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) else { return nil }
        for folder in folders {
            let parts = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var shared = 0
            while shared < min(common.count, parts.count), common[shared] == parts[shared] { shared += 1 }
            common = Array(common.prefix(shared))
        }
        guard !common.isEmpty else { return nil }
        return URL(fileURLWithPath: "/" + common.joined(separator: "/"), isDirectory: true)
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
        // Qlick Lab: an iPhone's transit folder goes once everything it held is imported and checked (what was left
        // out with it): the next time, only what the ledger doesn't know comes over again.
        if !stopped, journal.remaining == 0, journal.items.allSatisfy(\.done), let source, source.kind == .phone {
            close()
            // The deletion asked for (only what was copied and checked), then the transit folder emptied.
            phones.finished(journal, udid: source.uuid, transit: source.root)
        }
        // Qlick Lab: their proxies straight away, so their thumbnails develop in milliseconds.
        let arrived = journal.items.filter(\.done)
        fileInHolder(arrived.compactMap(\.photo), options: journal.options)
        if journal.options.stackBursts == true {
            stackImported(arrived.compactMap { item in item.photo.map { ($0, item.captured, frame(item.id)?.camera) } })
        }
        model.lab.noteImported(arrived.compactMap(\.photo))
        model.lab.proxyMaker.make(arrived.compactMap(\.photo), first: true)
        // Then each one's own white balance, from its proxy as it's made.
        if journal.options.balanceEach { model.labBalanceImported(arrived.filter { $0.marks.recipe != nil }.compactMap(\.photo)) }
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
    func stop() { runner?.cancel(); adding?.cancel() }
    func togglePause() {
        guard let runner, let run else { return }
        runner.paused.toggle()
        run.paused = runner.paused
    }
    /// Leaves the finished import's account and goes back to the source.
    func dismissRun() { if run?.finished == true { run = nil } }

    /// Add in Place: nothing is copied. Each folder becomes a roll of the project, and the marks, recipes and words
    /// chosen here are written beside the photographs where they lie, a few at a time, with the progress in sight.
    private func addInPlace(_ frames: [ImportFrame], marks: [URL: ImportMarks]) {
        let run = ImportRun(adding: frames.map(\.id), sourceName: source?.name ?? "")
        self.run = run
        let options = options
        // The Folder is the folder the photographs are taken from, with its tree (a sub-folder at any depth shows).
        let root = Self.placeRoot(of: frames.map(\.id), source: source?.root ?? URL(fileURLWithPath: "/"), sourceIsFolder: source?.kind == .folder)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Adding photographs")
        adding = Task { [weak self] in
            guard let self else { return }
            var recipes: [String: EditState] = [:]
            for name in Set(marks.values.compactMap(\.recipe)) {
                guard let preset = model.presets.first(where: { $0.name == name }) else { run.notes.append("The recipe “\(name)” isn’t there any more."); continue }
                if let state = await model.labRecipeState(preset) { recipes[name] = state } else { run.notes.append("The recipe “\(name)” couldn’t be read.") }
            }
            let metadata = ImportMetadata(options: options)
            // The rights to each folder, asked once: a disk on the network answers slowly.
            var writable: [URL: Bool] = [:]
            for folder in Set(frames.map { $0.file.url.deletingLastPathComponent() }) {
                writable[folder] = await Task.detached(priority: .userInitiated) { PhotoLibrary.canWrite(in: folder) }.value
            }
            // The recipes and marks at once, a batch at a time; each photograph's own white balance after, in the
            // background, so the photographs are there to work on straight away.
            for start in stride(from: 0, to: frames.count, by: 64) {
                if Task.isCancelled { break }
                let batch = Array(frames[start..<min(start + 64, frames.count)])
                if let first = batch.first { run.began(first.id, name: first.file.name) }
                var failures: [URL: String] = [:]
                for frame in batch {
                    guard let mark = marks[frame.id], !mark.isEmpty else { continue }
                    guard writable[frame.file.url.deletingLastPathComponent()] != false else {
                        failures[frame.id] = "its folder can’t be written to, so its marks and recipe weren’t saved"
                        continue
                    }
                    let recipe = mark.recipe.flatMap { recipes[$0] }
                    if !model.labWriteImported(frame.id, marks: mark, recipe: recipe, matchExposure: options.balanceEach) {
                        failures[frame.id] = "its marks or recipe couldn’t be saved"
                    }
                    if let name = mark.recipe, recipe != nil, let preset = model.presets.first(where: { $0.name == name }) { model.notePresetApplied(preset.url, to: frame.id) }
                }
                if !metadata.isEmpty {
                    let photos = batch.map(\.id)
                    Task.detached(priority: .utility) { for photo in photos { metadata.write(beside: photo) } }
                }
                for frame in batch {
                    let failure = failures[frame.id] ?? failures[frame.id.labStandardized]
                    run.added(frame.id, failure: failure)
                }
                // The Archive is there, and grows, while the photographs are taken in.
                if let root { addRolls([root], options: options) } else { addRolls(run.folders, options: options) }
                await Task.yield()
            }
            // Written in the background: the lab shows what's queued, so the photographs can be worked on now.
            flushMarksLater(run)
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            adding = nil
            // Qlick Lab: their proxies straight away, so their thumbnails develop in milliseconds.
            let added = run.order.filter { run.state(of: $0) == .verified }
            fileInHolder(added, options: options)
            if options.stackBursts == true { stackImported(added.compactMap { id in self.frame(id).map { (id, $0.captured, $0.camera) } }) }
            model.lab.noteImported(added)
            model.lab.proxyMaker.make(added, first: true)
            if options.balanceEach { model.labBalanceImported(added.filter { marks[$0]?.recipe != nil }) }
            run.finish(stopped: Task.isCancelled)
            model.library.refreshNow()
            model.library.reload(added)
            model.lab.projects.countAll()
            importedNow()
            if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// Opens what the import brought in on its contact sheet.
    func openImported() {
        guard let run, let first = run.folders.first else { return }
        let projects = model.lab.projects
        if let holder = chosenHolder {
            model.lab.open(holder.view)
        } else if run.folders.count > 1, let project = chosenProject ?? projects.project(named: options.project.trimmingCharacters(in: .whitespaces)) {
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
