// Qlick Lab — GPL-3.0-only.
import CoreServices
import Foundation
import Observation

/// One folder of an Archive's tree, as the disk has it: its photographs, and every folder under it.
struct FolderNode: Identifiable, Equatable, Sendable {
    var url: URL
    /// Photographs directly in it.
    var photos: Int
    var children: [FolderNode]
    /// Photographs in it and in every folder under it.
    var total: Int

    init(url: URL, photos: Int, children: [FolderNode]) {
        self.url = url; self.photos = photos; self.children = children
        total = photos + children.reduce(0) { $0 + $1.total }
    }

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// Every folder of the tree, this one first.
    var all: [FolderNode] { [self] + children.flatMap(\.all) }

    /// Whether folders under it hold photographs: then it opens as a list, with theirs.
    var photosBelow: Bool { total > photos }
}

/// The Archives' Folders as the disk has them: each Folder on top read with every folder under it, at any depth, and
/// followed (FSEvents) so a folder made, renamed or removed in the Finder shows at once. Read only: nothing here
/// changes the disk.
@MainActor @Observable final class FolderTrees {
    /// How many folders at most under one Folder, and how deep: a whole disk added by mistake stays quick.
    nonisolated static let limit = 20_000, depth = 64

    /// Each Folder's tree by its path, once read; nil while it's read the first time or when it's not there.
    private(set) var trees: [String: FolderNode] = [:]
    private(set) var roots: Set<URL> = []
    @ObservationIgnored private var watchers: [URL: FolderWatcher] = [:]
    @ObservationIgnored private var scans: [URL: Task<Void, Never>] = [:]
    /// Off until `start`: the tests read trees only when they ask.
    @ObservationIgnored private(set) var started = false

    /// Reads every Folder and follows them.
    func start() {
        started = true
        for root in roots { watch(root) }
        // Qlick Lab: a Folder whose disk didn't answer is read and followed once it does (`VolumeReach`).
        reach = NotificationCenter.default.addObserver(forName: VolumeReach.changed, object: nil, queue: .main) { [weak self] note in
            guard let volume = note.userInfo?["volume"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self, !VolumeReach.isSilent(volume) else { return }
                for root in self.roots where root.path.hasPrefix(volume + "/") && self.watchers[root] == nil { self.watch(root) }
            }
        }
    }
    @ObservationIgnored private var reach: NSObjectProtocol?

    /// The Folders to read and follow now: the new ones are read, those gone are let go.
    func follow(_ wanted: Set<URL>) {
        let wanted = Set(wanted.map(\.standardizedFileURL))
        guard wanted != roots else { return }
        for gone in roots.subtracting(wanted) {
            watchers[gone]?.stop(); watchers[gone] = nil
            scans[gone]?.cancel(); scans[gone] = nil
            trees[gone.path] = nil
        }
        let new = wanted.subtracting(roots)
        roots = wanted
        if started { for root in new { watch(root) } }
    }

    private func watch(_ root: URL) {
        rescan(root)
        watchers[root]?.stop(); watchers[root] = nil
        // Not followed while its disk doesn't answer: read again when it does.
        guard VolumeReach.answers(root.path) else { return }
        watchers[root] = FolderWatcher(root: root) { [weak self] in
            MainActor.assumeIsolated { self?.rescan(root) }
        }
    }

    /// Reads a Folder again, off the main thread; a burst of changes (an import writing) is read once, after it.
    func rescan(_ root: URL) {
        scans[root]?.cancel()
        scans[root] = Task { [weak self] in
            let tree = await Task.detached(priority: .utility) { Self.read(root) }.value
            guard !Task.isCancelled, let self, self.roots.contains(root) else { return }
            if self.trees[root.path] != tree { self.trees[root.path] = tree }
        }
    }

    /// Reads one Folder now, on this thread, when it's wanted at once (a folder just added, opened straight away).
    func rescanNow(_ root: URL) {
        let root = root.standardizedFileURL
        guard roots.contains(root) else { return }
        trees[root.path] = Self.read(root)
    }

    /// Reads every Folder now, on this thread: for the tests.
    func readNow() { for root in roots { trees[root.path] = Self.read(root) } }

    /// The tree under `root`: every folder, holding photographs or not. Hidden folders and packages (a catalogue, an
    /// app) are passed by.
    nonisolated static func read(_ root: URL) -> FolderNode? {
        var budget = limit
        guard VolumeReach.answers(root.path, patience: Thread.isMainThread ? VolumeReach.patience : 3), FileManager.default.fileExists(atPath: root.path) else { return nil }
        return read(root.standardizedFileURL, depth: depth, budget: &budget, excluded: PhotoFolder.excluded)
    }

    private nonisolated static func read(_ folder: URL, depth: Int, budget: inout Int, excluded: Set<String>) -> FolderNode {
        budget -= 1
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return FolderNode(url: folder, photos: 0, children: [])
        }
        var photos = 0
        var folders: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true, values?.isSymbolicLink != true { folders.append(entry) }
            } else if PhotoFolder.extensions.contains(entry.pathExtension.lowercased()),
                      excluded.isEmpty || !excluded.contains(folder.appendingPathComponent(entry.lastPathComponent).standardizedFileURL.path) {
                photos += 1
            }
        }
        var children: [FolderNode] = []
        if depth > 0 {
            for child in folders.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard budget > 0 else { break }
                children.append(read(folder.appendingPathComponent(child.lastPathComponent, isDirectory: true), depth: depth - 1, budget: &budget, excluded: excluded))
            }
        }
        return FolderNode(url: folder, photos: photos, children: children)
    }
}

/// Follows a folder and everything under it (FSEvents, by folder): a folder made, renamed or removed, photographs
/// copied in. The events come in bursts; the tree is read once a burst is over.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable () -> Void

    init?(root: URL, changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    private func fire() { changed() }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
