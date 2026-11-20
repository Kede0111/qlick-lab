// Qlick Lab — GPL-3.0-only.
import AppKit
import ImageIO

/// The developed previews of the photographs the next steps will open, read into memory ahead, in the direction the
/// lab is walked through, and the one just left: stepping on shows the photograph developed in the very first frame,
/// without reading or decoding its preview then. Only what the lab keeps on disk anyway (`renderArchive`) is read; a
/// photograph without a kept develop opens as before.
///
/// A few photographs at most (each ~17 MB decoded, 2560 pixels): the next ones in the direction of travel, one behind.
/// Emptied when the Mac asks for memory back.
final class RenderAhead: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let image: CGImage
        let photoSize: CGSize
    }

    /// How many photographs ahead, in the direction of travel, and behind.
    static let ahead = 2, behind = 1
    /// The photographs held: those ahead and behind, and the one open (stepping back to it).
    let capacity: Int

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Most recently used last.
    private var order: [String] = []
    private var reading: Set<String> = []
    private var wanted: Set<String> = []
    private let queue = DispatchQueue(label: "be.jackfrom.qlicklab.render-ahead", qos: .utility, attributes: .concurrent)
    private var pressure: DispatchSourceMemoryPressure?
    /// For the benchmarks and tests: what was found in memory, and what had to be read.
    private(set) var hits = 0, misses = 0

    init(capacity: Int = RenderAhead.ahead + RenderAhead.behind + 1) {
        self.capacity = max(1, capacity)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.removeAll() }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    /// The preview kept as `key`, if it's in memory; it stays there (stepping back to it).
    func take(_ key: String) -> Entry? {
        lock.withLock {
            guard let entry = entries[key] else { misses += 1; return nil }
            hits += 1
            order.removeAll { $0 == key }; order.append(key)
            return entry
        }
    }

    func contains(_ key: String) -> Bool { lock.withLock { entries[key] != nil } }

    /// Holds `image` as `key`: the develop of the photograph just left, before its file is even written.
    func keep(_ image: CGImage, photoSize: CGSize, as key: String) {
        lock.withLock {
            entries[key] = Entry(image: image, photoSize: photoSize)
            order.removeAll { $0 == key }; order.append(key)
            trim()
        }
    }

    /// Reads `wanted`'s previews (nearest first) into memory, off the main thread, and lets go of the others but
    /// `keeping`. Each read gives nil when there's no kept develop.
    func prefetch(_ wanted: [(key: String, read: @Sendable () -> Entry?)], keeping: Set<String> = []) {
        let keys = Set(wanted.map(\.key)).union(keeping)
        let starts: [(key: String, read: @Sendable () -> Entry?)] = lock.withLock {
            self.wanted = keys
            // What's no longer wanted goes first, so the reads below have room.
            for key in order where !keys.contains(key) { entries[key] = nil }
            order.removeAll { !keys.contains($0) }
            let starts = wanted.filter { entries[$0.key] == nil && !reading.contains($0.key) }
            for item in starts { reading.insert(item.key) }
            return starts
        }
        for item in starts {
            queue.async { [weak self] in
                // Not wanted any more by the time its turn came (several steps at once): not read.
                guard let self, self.lock.withLock({ self.wanted.contains(item.key) }) else {
                    self?.lock.withLock { _ = self?.reading.remove(item.key) }
                    return
                }
                let entry = item.read()
                self.lock.withLock {
                    self.reading.remove(item.key)
                    guard let entry, self.wanted.contains(item.key) else { return }
                    self.entries[item.key] = entry
                    self.order.removeAll { $0 == item.key }; self.order.append(item.key)
                    self.trim()
                }
            }
        }
    }

    func removeAll() {
        lock.withLock { entries = [:]; order = []; wanted = [] }
    }

    /// The bytes held, decoded.
    var bytes: Int { lock.withLock { entries.values.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height } } }
    var count: Int { lock.withLock { entries.count } }

    /// Waits for the reads under way (tests and benchmarks).
    func settle() { queue.sync(flags: .barrier) {} }

    private func trim() {
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    // MARK: Which photographs, apart so they can be tested

    /// The photographs `ahead` places on in `direction` and `behind` the other way from `index` in a list of `count`,
    /// nearest first, ahead before behind.
    static func neighbours(of index: Int, count: Int, direction: Int, ahead: Int = RenderAhead.ahead, behind: Int = RenderAhead.behind) -> [Int] {
        let step = direction < 0 ? -1 : 1
        let forward = (1...max(ahead, 1)).prefix(ahead).map { index + $0 * step }
        let back = (1...max(behind, 1)).prefix(behind).map { index - $0 * step }
        return (forward + back).filter { (0..<count).contains($0) }
    }

    /// `items` by how soon walking in `direction` from `centre` reaches them: those ahead by their distance, those
    /// behind as if `behindCost` times as far; of two as near, the one before. No direction: nearest first.
    static func walkOrder<Item>(_ items: [(index: Int, item: Item)], from centre: Int, direction: Int?, behindCost: Int = 3) -> [Item] {
        func cost(_ index: Int) -> Int {
            let distance = abs(index - centre)
            guard let direction, direction != 0, index != centre else { return distance }
            let ahead = (index - centre).signum() == direction.signum()
            return ahead ? distance : distance * behindCost
        }
        return items.sorted { (cost($0.index), $0.index) < (cost($1.index), $1.index) }.map(\.item)
    }
}

extension EditorModel {
    /// Notes the direction the photographs are walked through from the open one to `item`: forward or back in the
    /// list shown. A jump far away keeps the last direction.
    func noteWalk(to item: URL) {
        guard let from = sourceItem, from != item else { return }
        let shown = shownPhotos
        guard let a = shown.firstIndex(where: { $0.url == from }), let b = shown.firstIndex(where: { $0.url == item }) else { return }
        walkDirection = b > a ? 1 : -1
    }

    /// The archive's key for `item`'s kept develop as it opens now.
    func renderKey(of item: URL, file: PhotoFile? = nil) -> String? {
        guard let look = thumbnailLook(for: item),
              let file = file ?? library.items.first(where: { $0.url == item }) else { return nil }
        return renderArchive.key(for: file, look: look)
    }

    /// Reads the kept develops of the photographs the next steps open into memory: `RenderAhead.ahead` in the
    /// direction of travel, `behind` the other way, and keeps the open one's. Called once a photograph has opened,
    /// and when a kept develop is made.
    func prepareAhead() {
        guard !closing, mode != .grid || source != nil, let open = sourceItem else { return }
        let shown = shownPhotos
        guard let index = shown.firstIndex(where: { $0.url == open }) else { return }
        let archive = renderArchive
        var wanted: [(key: String, read: @Sendable () -> RenderAhead.Entry?)] = []
        for neighbour in RenderAhead.neighbours(of: index, count: shown.count, direction: walkDirection) {
            let file = shown[neighbour], item = file.url
            guard let look = thumbnailLook(for: item), let key = archive.key(for: file, look: look) else { continue }
            wanted.append((key, {
                (archive.render(key) ?? archive.previousKey(for: file, look: look).flatMap { archive.render($0) })
                    .map { RenderAhead.Entry(image: $0.image, photoSize: $0.photoSize) }
            }))
        }
        let keeping = renderKey(of: open, file: shown[index]).map { Set([$0]) } ?? []
        renderAhead.prefetch(wanted, keeping: keeping)
    }
}
