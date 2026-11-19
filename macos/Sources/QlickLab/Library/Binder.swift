// Qlick Lab — GPL-3.0-only.
import CoreServices
import Foundation
import Observation

/// One folder of the Binder's tree: its photographs, and the folders under it that hold some.
struct BinderFolder: Identifiable, Equatable, Sendable {
    var url: URL
    /// Photographs directly in it: a folder with some can be a roll.
    var photos: Int
    var children: [BinderFolder]

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// Every folder of the tree, this one first.
    var all: [BinderFolder] { [self] + children.flatMap(\.all) }
}

/// The Binder: the folders on disk where the photographs live, chosen once, shown as a tree that follows the disk.
/// A folder holding photographs that no project has is marked, so nothing waits unseen. The roots are this Mac's,
/// kept in its preferences: another Mac has its own disks.
@MainActor @Observable final class Binder {
    static let rootsKey = "qlick.binderRoots"
    /// How deep a root is read, and how many folders at most: a whole disk chosen by mistake stays quick.
    nonisolated static let depth = 5, limit = 3000

    private(set) var roots: [URL]
    /// Each root's tree, once read; nil while it's read the first time or when it's not there.
    private(set) var trees: [URL: BinderFolder] = [:]
    @ObservationIgnored private var watchers: [URL: BinderWatcher] = [:]
    @ObservationIgnored private var scans: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.rootsKey) {
            roots = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            // The first time: the folders the import's old Recent list held, as a start.
            let recent = (defaults.stringArray(forKey: "qlick.importRecent") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            roots = Self.outermost(recent.filter { FileManager.default.fileExists(atPath: $0.path) })
            defaults.set(roots.map(\.path), forKey: Self.rootsKey)
        }
        defaults.removeObject(forKey: "qlick.importRecent")
    }

    /// Reads every root and follows them. Off in tests unless asked.
    func start() { for root in roots { watch(root) } }

    func add(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard !roots.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) else { return }
        // A root under the new one is folded into it.
        for inner in roots where inner.path.hasPrefix(folder.path + "/") { remove(inner) }
        roots.append(folder)
        roots.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        save()
        watch(folder)
    }

    func remove(_ root: URL) {
        roots.removeAll { $0 == root }
        watchers[root]?.stop(); watchers[root] = nil
        scans[root]?.cancel(); scans[root] = nil
        trees[root] = nil
        save()
    }

    private func save() { defaults.set(roots.map(\.path), forKey: Self.rootsKey) }

    private func watch(_ root: URL) {
        rescan(root)
        watchers[root]?.stop()
        watchers[root] = BinderWatcher(root: root) { [weak self] in
            MainActor.assumeIsolated { self?.rescan(root) }
        }
    }

    /// Reads a root again, off the main thread; a burst of changes (an import writing) is read once, after it.
    func rescan(_ root: URL, after delay: Duration = .zero) {
        scans[root]?.cancel()
        scans[root] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let tree = await Task.detached(priority: .utility) { Self.read(root) }.value
            guard !Task.isCancelled, let self, self.roots.contains(root) else { return }
            if self.trees[root] != tree { self.trees[root] = tree }
        }
    }

    /// The tree under `root`: folders that hold photographs, or lead to some. Hidden folders and packages (a
    /// catalogue, an app) are passed by.
    nonisolated static func read(_ root: URL) -> BinderFolder? {
        var budget = limit
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return read(root, depth: depth, budget: &budget, keepEmpty: true)
    }

    private nonisolated static func read(_ folder: URL, depth: Int, budget: inout Int, keepEmpty: Bool) -> BinderFolder? {
        budget -= 1
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return keepEmpty ? BinderFolder(url: folder, photos: 0, children: []) : nil
        }
        var photos = 0
        var folders: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true { folders.append(entry) }
            } else if PhotoFolder.extensions.contains(entry.pathExtension.lowercased()) {
                photos += 1
            }
        }
        var children: [BinderFolder] = []
        if depth > 0 {
            for child in folders.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard budget > 0 else { break }
                if let node = read(child, depth: depth - 1, budget: &budget, keepEmpty: false) { children.append(node) }
            }
        }
        guard keepEmpty || photos > 0 || !children.isEmpty else { return nil }
        return BinderFolder(url: folder.standardizedFileURL, photos: photos, children: children)
    }

    /// The folders of a list that no other one holds.
    nonisolated static func outermost(_ folders: [URL]) -> [URL] {
        var kept: [URL] = []
        for folder in folders.sorted(by: { $0.path.count < $1.path.count }) where !kept.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) {
            kept.append(folder)
        }
        return kept.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Follows a folder and everything under it (FSEvents, by folder): a folder made, renamed or removed, photographs
/// copied in. The events come in bursts; the Binder reads the tree once a burst is over.
final class BinderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable () -> Void

    init?(root: URL, changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<BinderWatcher>.fromOpaque(info).takeUnretainedValue().fire()
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
