// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation

/// Qlick Lab: makes the RAW photographs' proxies ahead (`PreviewStorage.proxyMode` "Ahead"), in the background, so
/// that their thumbnails, previews and Develop read 2560 pixels instead of the RAW. The engine makes each one
/// (`make_proxy`); this only decides which, in what order, and how many at once.
///
/// What it counts is photographs that need a proxy, each once: one that has its proxy already is never queued, nor
/// one queued or being made, and a folder's every change adds only what's new. It makes no more than the cache keeps
/// (`PreviewStorage.proxiesLimit`): a folder larger than that would see its first proxies pruned to make its last,
/// and made again the next time it opens. The rest get theirs as they're opened.
///
/// A few at a time, each in a helper of its own at utility priority (`helpers`), waiting while the editor works.
/// Stopping it kills its helpers, so a proxy being made stops at once rather than being finished unseen.
@MainActor @Observable final class ProxyMaker {
    @ObservationIgnored unowned let model: EditorModel
    /// Photographs done (made, or that couldn't be) since the work started, and how many it has had to do.
    private(set) var done = 0
    private(set) var total = 0
    /// The photographs being made now.
    private(set) var current: Set<URL> = []
    /// The photographs left without a proxy ahead because the cache keeps no more: they get theirs as they open.
    private(set) var leftOut: Set<URL> = []
    /// Queued, or looked for on disk before being queued.
    var busy: Bool { !queue.isEmpty || !current.isEmpty || checking > 0 }

    @ObservationIgnored private var queue: [URL] = []
    /// Those wanted first (their thumbnails or previews asked for).
    @ObservationIgnored private var front: Set<URL> = []
    /// An import's photographs that get their own Auto white balance from their proxy, once it's made.
    @ObservationIgnored private var balancing: Set<URL> = []
    @ObservationIgnored private var failed: Set<URL> = []
    /// Known to have their proxy: a folder's every change doesn't look for them again.
    @ObservationIgnored private var have: Set<URL> = []
    @ObservationIgnored private var remade: Set<URL> = []
    @ObservationIgnored private var workers: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var engines: [Int: EngineClient] = [:]
    @ObservationIgnored private var idle: Task<Void, Never>?
    /// Moves on every stop: a look on disk from before adds nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var checking = 0
    /// How many helpers this work may use; one when the photographs are on another computer.
    @ObservationIgnored private var helpersNow = 1
    @ObservationIgnored private var madeSincePrune = 0

    /// The proxy a large RAW makes, about: what the cache's room is counted in until proxies are there to measure.
    nonisolated static let typicalSize = 9 * 1024 * 1024

    init(model: EditorModel) { self.model = model }

    // MARK: What's asked

    /// Makes the proxies these photographs don't have yet (an import's, a folder's); nothing when proxies are made
    /// only as photographs open, or never. `first` puts them before those waiting.
    func make(_ items: [URL], first: Bool = false) {
        guard PreviewStorage.buildsProxiesAhead, NSClassFromString("XCTestCase") == nil else { return }
        // Stopped by hand in this folder: only what's asked for, until another folder opens.
        if first { heldIn = nil } else if held { return }
        let candidates = Self.candidates(items, skipping: Set(queue).union(current).union(failed).union(have).union(leftOut))
        if first { prioritise(items) }
        guard !candidates.isEmpty else { return }
        let asked = Set(Self.candidates(items, skipping: []))
        let generation = generation, limit = PreviewStorage.proxiesLimit
        let order = Self.order(candidates, around: centre(), in: model.library.items.map(\.url))
        checking += 1
        Task { [weak self] in
            // Off the main thread: thousands of photographs, each looked for on disk.
            let found = await Task.detached(priority: .utility) {
                (missing: order.filter { !Self.hasProxy($0) }, stats: PreviewStorage.proxiesStats(),
                 remote: order.prefix(1).contains { !Self.isLocal($0) })
            }.value
            guard let self else { return }
            self.checking -= 1
            guard generation == self.generation else { return }
            let waiting = Set(self.queue).union(self.current)
            let missing = found.missing.filter { !waiting.contains($0) }
            let gone = Set(found.missing)
            self.have.formUnion(order.filter { !gone.contains($0) })
            // The cache's room, less what these photographs' proxies already take: made beyond it, the first ones
            // made would be pruned for the last.
            let average = found.stats.count > 20 ? found.stats.bytes / found.stats.count : Self.typicalSize
            let room = Self.room(limit: limit, averageSize: average,
                                 queued: self.queue.count + self.current.count + self.have.intersection(asked).count)
            let taken = Array(missing.prefix(room))
            self.leftOut.formUnion(missing.dropFirst(room))
            if found.remote { self.helpersNow = 1 } else if self.workers.isEmpty { self.helpersNow = Self.helpers() }
            self.enqueue(taken)
            if self.queue.isEmpty, self.current.isEmpty, self.checking == 0 { self.model.pumpThumbnails() }
        }
    }

    /// These photographs' proxies, and right after each, its own Auto white balance read from it; their thumbnails
    /// wait for both, and are developed once. One that has its proxy is balanced from it at once.
    func balanceAfter(_ items: [URL]) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        heldIn = nil
        let photos = items.map(\.photoFile).filter { balancing.insert($0).inserted }
        // A proxy that couldn't be made is still balanced, from the RAW.
        failed.subtract(photos)
        let waiting = Set(queue).union(current)
        enqueue(photos.filter { !waiting.contains($0) })
    }

    /// The cache's limit changed: those left out for want of room are looked at again.
    func roomChanged() {
        leftOut = []
        make(model.library.items.map(\.url))
    }

    /// Stops the balancing still to come; the proxies are still made.
    func stopBalancing() { balancing = [] }

    /// Puts these photographs' proxies first, if they're waiting.
    func prioritise(_ items: [URL]) {
        let photos = Set(items.map(\.photoFile))
        front.formUnion(photos)
        let first = queue.filter(photos.contains)
        guard !first.isEmpty else { return }
        queue = first + queue.filter { !photos.contains($0) }
    }

    /// The photographs whose proxy is waiting or being made: their thumbnails wait for it.
    var pending: Set<URL> { Set(queue).union(balancing).union(current) }

    /// Stopped by hand (the background work's Stop): the open folder's proxies aren't made ahead again until
    /// they're asked for, or another folder opens.
    @ObservationIgnored private var heldIn: URL?
    private var held: Bool { heldIn != nil && heldIn == model.library.directory }

    /// Stop, by hand: `cancel`, and the folder's changes don't start it again.
    func stop() {
        heldIn = model.library.directory
        cancel()
    }

    /// Stops it all: nothing more is queued, the proxies being made stop now, and their helpers quit.
    func cancel() {
        generation += 1
        queue = []; balancing = []; front = []; leftOut = []
        workers.values.forEach { $0.cancel() }
        workers = [:]
        current = []
        done = 0; total = 0
        stopEngines()
        model.pumpThumbnails()
    }

    func shutdown() { cancel() }

    // MARK: The work

    private func enqueue(_ photos: [URL]) {
        guard !photos.isEmpty else { return }
        if queue.isEmpty, current.isEmpty { done = 0; total = 0 }
        queue += photos
        total += photos.count
        start()
    }

    private func start() {
        idle?.cancel(); idle = nil
        for slot in 0..<helpersNow where workers[slot] == nil && !queue.isEmpty {
            let generation = generation
            workers[slot] = Task { [weak self] in
                await self?.work(slot: slot)
                guard let self, generation == self.generation else { return }
                self.workers[slot] = nil
                if self.workers.isEmpty { self.finished() }
            }
        }
    }

    private func finished() {
        if queue.isEmpty { done = 0; total = 0; front = [] }
        madeSincePrune = 0
        Task.detached(priority: .utility) { PreviewStorage.pruneProxies() }
        model.pumpThumbnails()
        stopSoon()
    }

    /// The next to make: one wanted now, then those on screen whose edits are written (writing into a DNG can
    /// change its size, and its proxy's name with it), then any written, then on screen, then the first.
    private func next() -> URL? {
        guard !queue.isEmpty else { return nil }
        let onScreen = Set(model.thumbnailsOnScreen.map(\.photoFile))
        let store = model.sidecarLookup?.store
        let written = { (photo: URL) in store?.isPending(photo) != true }
        let index = queue.firstIndex { front.contains($0) && written($0) } ?? queue.firstIndex { onScreen.contains($0) && written($0) }
            ?? queue.firstIndex(where: written) ?? queue.firstIndex(where: onScreen.contains) ?? 0
        let photo = queue.remove(at: index)
        front.remove(photo)
        return photo
    }

    private func work(slot: Int) async {
        while !Task.isCancelled, let photo = next() {
            current.insert(photo)
            defer { current.remove(photo) }
            // The editor goes first.
            while !Task.isCancelled, !model.backgroundMayRun { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let present = await Task.detached(priority: .utility) { Self.hasProxy(photo) }.value
            guard !Task.isCancelled else { return }
            if !present, !failed.contains(photo) {
                guard let engine = engine(slot) else { return }
                let state = model.labEdits(for: photo).state
                do {
                    _ = try await engine.request(["command": EngineCommand.makeProxy.json, "input": .string(photo.path), "params": state.params])
                    guard !Task.isCancelled else { return }
                    // Its file changed while it was being made (its edits written into it): once more.
                    let there = await Task.detached(priority: .utility) { Self.hasProxy(photo) }.value
                    if there { have.insert(photo) } else if remade.insert(photo).inserted { queue.append(photo); total += 1 }
                } catch {
                    // Stopped: its helper was killed, which isn't the photograph's fault.
                    guard !Task.isCancelled else { return }
                    failed.insert(photo)
                }
                madeSincePrune += 1
                if madeSincePrune >= 16 {
                    madeSincePrune = 0
                    Task.detached(priority: .utility) { PreviewStorage.pruneProxies() }
                }
            } else if present {
                have.insert(photo)
            }
            // An import's photograph: its own white balance, read from the proxy just made.
            if balancing.remove(photo) != nil, let engine = engine(slot) {
                await model.labBalance(photo, with: engine)
                guard !Task.isCancelled else { return }
            }
            done += 1
            // Its thumbnail can be developed now, from it.
            model.pumpThumbnails()
        }
    }

    private func engine(_ slot: Int) -> EngineClient? {
        if let engine = engines[slot] { return engine }
        guard let paths = model.labEnginePaths, let engine = try? EngineClient(paths: paths, quality: .utility) else { return nil }
        engine.label = "proxies\(slot)"
        engines[slot] = engine
        return engine
    }

    /// The helpers quit a while after the last proxy, so their memory goes.
    private func stopSoon() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.workers.isEmpty else { return }
            self.stopEngines()
        }
    }

    private func stopEngines() {
        idle?.cancel(); idle = nil
        let running = Array(engines.values)
        engines = [:]
        guard !running.isEmpty else { return }
        Task.detached(priority: .utility) { running.forEach { $0.stop() } }
    }

    /// Where the work starts from: the open photograph, else the first on screen.
    private func centre() -> URL? {
        model.sourceItem?.photoFile ?? model.library.items.first { model.thumbnailsOnScreen.contains($0.url) }?.url.photoFile
    }

    // MARK: Decisions, apart so they can be tested

    /// How many proxies are made at once: each helper reads a RAW whole (about 1.2 GB for 60 MP at its peak), and
    /// a RAW's read is partly on one core, so a second or third helper nearly doubles or triples the pace on a Mac
    /// with the cores and memory (measured on an M4 Max: 1.8 s a proxy alone, 1 s with two, 0.6 s with four). Never
    /// more than three: the thumbnails' helpers and Develop's share the machine. One in Low Power Mode.
    nonisolated static func helpers(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                                    memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                    lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> Int {
        if lowPower || cores < 8 || memory < 16 << 30 { return 1 }
        if cores >= 12 && memory >= 32 << 30 { return 3 }
        return 2
    }

    /// How many more proxies the cache keeps: its pruning brings it down to three quarters of its share, so no more
    /// than that is made ahead, less those already waiting.
    nonisolated static func room(limit: Int, averageSize: Int, queued: Int) -> Int {
        max(0, limit * 3 / 4 / max(averageSize, 1) - queued)
    }

    /// The RAW photographs among `items`, each once (a duplicate is its photograph's), but those in `skipping`.
    nonisolated static func candidates(_ items: [URL], skipping: Set<URL>) -> [URL] {
        var seen = Set<URL>()
        return items.map(\.photoFile).filter { photo in
            guard seen.insert(photo).inserted, !skipping.contains(photo) else { return false }
            return EditorModel.rawExtensions.contains(photo.pathExtension.lowercased())
        }
    }

    /// `photos` from the nearest to `centre` outward, in the folder's order (`all`); as given without a centre.
    nonisolated static func order(_ photos: [URL], around centre: URL?, in all: [URL]) -> [URL] {
        var index: [URL: Int] = [:]
        for (position, item) in all.enumerated() where index[item.photoFile] == nil { index[item.photoFile] = position }
        guard let centre, let middle = index[centre] else { return photos }
        return photos.enumerated().sorted { a, b in
            let (x, y) = (abs((index[a.element] ?? Int.max / 2) - middle), abs((index[b.element] ?? Int.max / 2) - middle))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// Whether `photo` has its proxy, with either lens correction (the app keeps one).
    nonisolated static func hasProxy(_ photo: URL) -> Bool {
        [false, true].contains { lens in PreviewStorage.proxyFile(for: photo, lensCorrection: lens).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    nonisolated static func isLocal(_ photo: URL) -> Bool {
        (try? photo.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
    }
}
