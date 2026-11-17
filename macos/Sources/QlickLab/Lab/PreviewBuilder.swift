// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation

/// Builds each photograph's preview ahead, in the background, as Lightroom builds its standard previews: the develop
/// NEgs keeps of a photograph (`renderArchive`, 2560 pixels, uncropped) is made before it's ever opened, so opening
/// or stepping to it shows it developed at once while the editor's own develop follows.
///
/// A helper of its own at utility priority, one photograph at a time, the nearest to the open one first. It waits
/// whenever the editor works (an edit, a develop, an export) and quits a while after the last one. It runs by
/// itself over the open folder (Settings), after a paste of edits, and on demand for a selection.
@MainActor @Observable final class PreviewBuilder {
    @ObservationIgnored unowned let model: EditorModel
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current: URL?
    var running: Bool { task != nil }
    /// A word for a moment after a build was asked for: that every preview is already there, or that it's done.
    private(set) var note: String?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// Asked for by hand (the menus), not by itself: its progress shows wherever you are.
    private(set) var asked = false
    /// Those wanted now (Space on the sheet): built first, without waiting for the editor.
    @ObservationIgnored private var urgent: Set<URL> = []
    @ObservationIgnored private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var engine: EngineClient?
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var failed: Set<String> = []

    static let longSide = EditedThumbnailStore.renderLongSide
    /// Settings: build the open folder's previews by themselves.
    var automatic = UserDefaults.standard.object(forKey: "qlick.autoPreviews") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "qlick.autoPreviews"); if automatic { folderChanged() } }
    }

    init(model: EditorModel) {
        self.model = model
        // Proxies over their share of the limit, from last time.
        if NSClassFromString("XCTestCase") == nil { Task.detached(priority: .background) { PreviewStorage.removeFormerProxies(); PreviewStorage.pruneProxies() } }
    }

    /// The folder's photographs or their edits changed: what's missing is built, if that's on.
    func folderChanged() {
        guard automatic, NSClassFromString("XCTestCase") == nil else { return }
        build(model.library.items.map(\.url), front: false)
    }

    /// Builds `items`' previews; `front` puts them before what's waiting. Asked for by hand, it says so at once,
    /// and says when there was nothing to build.
    func build(_ items: [URL], front: Bool = true) {
        let waiting = Set(queue)
        let new = items.filter { !waiting.contains($0) && needs($0) }
        if front {
            asked = true
            if new.isEmpty && queue.isEmpty && task == nil {
                return say(items.isEmpty ? "No photographs to build previews for" : items.count == 1 ? "Its preview is already built" : "All \(items.count) previews are already built")
            }
        }
        guard !new.isEmpty || front else { return }
        if front { queue = new + queue.filter { !Set(new).contains($0) } } else { queue += new }
        total = done + queue.count
        start()
    }

    /// Builds `item`'s preview now, ahead of the rest and without waiting for the editor, and returns once it's
    /// there (or couldn't be made).
    func ensure(_ item: URL) async {
        guard needs(item) else { return }
        urgent.insert(item)
        queue.removeAll { $0 == item }
        queue.insert(item, at: 0)
        total = done + queue.count
        await withCheckedContinuation { continuation in
            waiters[item, default: []].append(continuation)
            start()
        }
    }

    private func finished(_ item: URL) {
        urgent.remove(item)
        for waiter in waiters.removeValue(forKey: item) ?? [] { waiter.resume() }
    }

    private func say(_ words: String) {
        note = words
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    func cancel() {
        queue = []
        task?.cancel(); task = nil
        done = 0; total = 0; current = nil; asked = false
        for item in Array(waiters.keys) { finished(item) }
    }

    /// The archive's name for `item`'s preview as it opens now, if it has a look to name it by.
    private func key(_ item: URL) -> String? {
        guard let look = model.thumbnailLook(for: item), let file = model.library.items.first(where: { $0.url == item }) else { return nil }
        return model.renderArchive.key(for: file, look: look)
    }

    func needs(_ item: URL) -> Bool {
        guard let key = key(item) else { return false }
        return !failed.contains(key) && (!model.renderArchive.contains(key) || needsProxy(item))
    }

    /// A RAW without its proxy (`PreviewStorage`).
    private func needsProxy(_ item: URL) -> Bool {
        let photo = item.photoFile
        guard PreviewStorage.buildsProxiesAhead, EditorModel.rawExtensions.contains(photo.pathExtension.lowercased()), !failedProxies.contains(photo) else { return false }
        let lens = model.labEdits(for: item).state.params[EditorModel.lensCorrectionPath].bool
        guard let file = PreviewStorage.proxyFile(for: photo, lensCorrection: lens) else { return false }
        return !FileManager.default.fileExists(atPath: file.path)
    }
    @ObservationIgnored private var failedProxies: Set<URL> = []

    /// The next to build: the nearest to the open photograph.
    private func next() -> URL? {
        guard !queue.isEmpty else { return nil }
        if let index = queue.firstIndex(where: urgent.contains) { return queue.remove(at: index) }
        let order = model.library.items.map(\.url)
        let centre = model.sourceItem.flatMap { order.firstIndex(of: $0) } ?? 0
        let index = queue.indices.min { a, b in
            abs((order.firstIndex(of: queue[a]) ?? .max / 2) - centre) < abs((order.firstIndex(of: queue[b]) ?? .max / 2) - centre)
        } ?? 0
        return queue.remove(at: index)
    }

    private func start() {
        guard task == nil, !queue.isEmpty else { return }
        idle?.cancel(); idle = nil
        task = Task { [weak self] in
            await self?.run()
            guard let self else { return }
            self.task = nil
            self.current = nil
            if self.queue.isEmpty {
                if self.asked, self.total > 0 { self.say(self.total == 1 ? "Preview built" : "\(self.total) previews built") }
                self.done = 0; self.total = 0; self.asked = false
            }
            for item in Array(self.waiters.keys) { self.finished(item) }
            self.stopSoon()
        }
    }

    private func run() async {
        while !Task.isCancelled, let item = next() {
            // The editor goes first, unless the preview is wanted now; one wanted now goes before this one.
            var deferred = false
            while !Task.isCancelled, !urgent.contains(item), !model.backgroundMayRun {
                if !urgent.isEmpty { deferred = true; break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if deferred { queue.insert(item, at: 0); continue }
            defer { finished(item) }
            guard !Task.isCancelled else { return }
            guard let key = key(item), !failed.contains(key),
                  let look = model.thumbnailLook(for: item), let file = model.library.items.first(where: { $0.url == item }) else { done += 1; continue }
            let proxy = needsProxy(item)
            guard proxy || !model.renderArchive.contains(key) else { done += 1; continue }
            guard let paths = model.labEnginePaths else { return }
            if engine == nil { engine = try? EngineClient(paths: paths, quality: .utility); engine?.label = "previews" }
            guard let engine else { return }
            current = item
            // The proxy first: the develop after reads it, not the RAW, and so will Develop.
            if proxy {
                let state = model.labEdits(for: item).state
                do {
                    _ = try await engine.request(["command": .string("make_proxy"), "input": .string(item.photoFile.path), "params": state.params])
                } catch {
                    failedProxies.insert(item.photoFile)
                }
                PreviewStorage.pruneProxies()
                if model.renderArchive.contains(key) { done += 1; continue }
            }
            var size = CGSize.zero
            let image = await model.labDevelop(item, longSide: Self.longSide, engine: engine, whole: true) { size = $0 }
            if let image {
                let archive = model.renderArchive, loose = archive.looseKey(for: file, look: look), photo = archive.photoKey(for: file)
                await Task.detached(priority: .utility) { try? archive.save(image, as: key, loose: loose, photo: photo, photoSize: size) }.value
            } else {
                failed.insert(key)
            }
            done += 1
        }
    }

    private func stopSoon() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.task == nil, let engine = self.engine else { return }
            self.engine = nil
            await Task.detached(priority: .utility) { engine.stop() }.value
        }
    }

    func shutdown() {
        cancel()
        if let engine { self.engine = nil; Task.detached(priority: .utility) { engine.stop() } }
    }
}
