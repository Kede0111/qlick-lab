// Qlick Lab — GPL-3.0-only.
import Foundation

/// A stack: photographs kept together (a burst, a few frames of one moment), shown as the first, its top, with how
/// many it holds, until it's opened. By path, in the catalogue only (`stacks.json`): nothing on disk changes.
struct PhotoStack: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Top first.
    var frames: [String]
    /// Opened: every photograph of it shows, the top still badged.
    var open = false
}

/// The catalogue's stacks, `stacks.json` beside the Archives, top-level key `qlick`.
enum StacksFile {
    static let fileName = "stacks.json"
    static let schema = 1

    private struct File: Codable { var qlick: Content }
    private struct Content: Codable { var schema: Int; var stacks: [PhotoStack] }

    static func url(inCatalog directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The stacks, or nil when there's no file, or one this version can't read (a newer schema is left alone).
    static func read(inCatalog directory: URL) -> [PhotoStack]? {
        guard let data = try? Data(contentsOf: url(inCatalog: directory)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.qlick.schema <= schema else { return nil }
        return file.qlick.stacks
    }

    static func isForeign(inCatalog directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(inCatalog: directory).path) && read(inCatalog: directory) == nil
    }

    @discardableResult static func write(_ stacks: [PhotoStack], inCatalog directory: URL) -> Bool {
        guard !isForeign(inCatalog: directory) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(File(qlick: Content(schema: schema, stacks: stacks))).write(to: url(inCatalog: directory), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("stacks: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

/// What the stacks do to a list of photographs, apart from where they're kept: pure, so tests answer for it.
enum Stacking {
    /// `paths` (in the order shown) with each closed stack down to one photograph: its top if it's there, else the
    /// first of it that is. Photographs in no stack, and open stacks, stay as they are.
    static func collapsed(_ paths: [String], stacks: [PhotoStack]) -> [String] {
        // By one spelling of each path (`ManualOrder.canonical`); the paths come back as given.
        let key = ManualOrder.canonical
        var member: [String: Int] = [:]
        for (index, stack) in stacks.enumerated() where !stack.open { for path in stack.frames { member[key(path)] = index } }
        guard !member.isEmpty else { return paths }
        let present = Set(paths.map(key))
        var keep: [Int: String] = [:]
        for (index, stack) in stacks.enumerated() where !stack.open {
            if let first = stack.frames.first(where: { present.contains(key($0)) }) { keep[index] = key(first) }
        }
        return paths.filter { path in member[key(path)].map { keep[$0] == key(path) } ?? true }
    }

    /// Runs of photographs taken less than `gap` seconds apart with the same camera, in the order taken: each run of
    /// two or more is a burst. `photos`: path, time (seconds), camera.
    static func bursts(_ photos: [(path: String, time: TimeInterval?, camera: String?)], gap: TimeInterval = 2) -> [[String]] {
        let dated = photos.compactMap { photo in photo.time.map { (photo.path, $0, photo.camera ?? "") } }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        var runs: [[String]] = [], run: [String] = [], last: (time: TimeInterval, camera: String)?
        for (path, time, camera) in dated {
            if let previous = last, time - previous.time < gap, camera == previous.camera { run.append(path) }
            else {
                if run.count >= 2 { runs.append(run) }
                run = [path]
            }
            last = (time, camera)
        }
        if run.count >= 2 { runs.append(run) }
        return runs
    }
}

extension ProjectStore {
    /// The stack holding `path`, if any.
    func stack(holding path: String) -> PhotoStack? { stackIndex[ManualOrder.canonical(path)].map { stacks[$0] } }

    /// Stacks the photographs (in this order, the first on top): those already in a stack leave it first. Fewer than
    /// two make none. The new stack, closed.
    @discardableResult func makeStack(_ frames: [URL]) -> PhotoStack? {
        let paths = Self.paths(frames)
        guard paths.count >= 2 else { return nil }
        let taken = Set(paths.map(ManualOrder.canonical))
        var changed = stacks.compactMap { stack -> PhotoStack? in
            var stack = stack
            stack.frames.removeAll { taken.contains(ManualOrder.canonical($0)) }
            return stack.frames.count >= 2 ? stack : nil
        }
        let stack = PhotoStack(frames: paths)
        changed.append(stack)
        replaceStacks(changed)
        return stack
    }

    /// Unstacks every stack holding one of `frames`. The photographs stay where they are, each shown again.
    func unstack(_ frames: [URL]) {
        let paths = Set(Self.paths(frames).map(ManualOrder.canonical))
        replaceStacks(stacks.filter { !$0.frames.contains { paths.contains(ManualOrder.canonical($0)) } })
    }

    /// Opens or closes the stacks holding `frames`.
    func setStacksOpen(_ open: Bool, holding frames: [URL]) {
        let paths = Set(Self.paths(frames).map(ManualOrder.canonical))
        replaceStacks(stacks.map { stack in
            var stack = stack
            if stack.frames.contains(where: { paths.contains(ManualOrder.canonical($0)) }) { stack.open = open }
            return stack
        })
    }

    /// Stacks the bursts among `photos` (by capture time, under 2 s apart, same camera) whose photographs are in no
    /// stack yet. How many stacks were made.
    @discardableResult func stackBursts(_ photos: [(path: String, time: TimeInterval?, camera: String?)]) -> Int {
        let free = photos.filter { stackIndex[ManualOrder.canonical($0.path)] == nil }
        let runs = Stacking.bursts(free)
        guard !runs.isEmpty else { return 0 }
        replaceStacks(stacks + runs.map { PhotoStack(frames: $0) })
        return runs.count
    }

    /// The badge a photograph shown carries: its stack's size and whether it's open, on the photograph standing for
    /// a closed stack (the only one of it shown) and on an open stack's top.
    func stackBadge(_ url: URL) -> (count: Int, open: Bool)? {
        let path = url.photoFile.labStandardized.path
        guard let stack = stack(holding: path) else { return nil }
        if stack.open, stack.frames.first.map(ManualOrder.canonical) != ManualOrder.canonical(path) { return nil }
        return (stack.frames.count, stack.open)
    }
}

extension LabState {
    /// The photographs shown, each closed stack down to the one standing for it (`Stacking.collapsed`).
    func stacked(_ items: [PhotoFile]) -> [PhotoFile] {
        let stacks = projects.stacks
        guard !stacks.isEmpty else { return items }
        let paths = items.map { $0.url.photoFile.labStandardized.path }
        let kept = Set(Stacking.collapsed(paths, stacks: stacks))
        return zip(items, paths).filter { kept.contains($0.1) }.map(\.0)
    }

    /// The photographs the stack commands act on: the selection as shown, else the current one.
    private var stackTargets: [URL] {
        let shown = model.shownPhotos.map(\.url)
        let ordered = model.selection.ordered(shown)
        return (ordered.isEmpty ? (model.sourceItem ?? model.selection.current).map { [$0] } ?? [] : ordered).map(\.photoFile)
    }

    /// Whether the photographs selected hold a stack, and whether it's open.
    var selectionStack: PhotoStack? {
        stackTargets.lazy.compactMap { self.projects.stack(holding: $0.labStandardized.path) }.first
    }

    /// Photo › Stack (⌘G): the photographs selected become one stack, the first shown on top, closed.
    func stackSelection() {
        let targets = stackTargets
        guard targets.count >= 2 else { return note("Not Stacked", "select two photographs or more") }
        if undoable("Stack \(Self.title(targets.count))", { projects.makeStack(targets) != nil }) {
            // The stack stands for its photographs by its top: that's the one selected now.
            selectShown(targets[0].labStandardized.path)
            note("Stacked", "\(photographs(targets.count)), under the first")
        }
    }

    /// Photo › Unstack (⇧⌘G): every stack holding a photograph selected comes apart.
    func unstackSelection() {
        let targets = stackTargets
        guard let stack = selectionStack else { return note("Not Unstacked", "no stack is selected") }
        if undoable("Unstack", { projects.unstack(targets); return true }) {
            note("Unstacked", photographs(stack.frames.count))
        }
    }

    /// Photo › Open Stack / Close Stack: every photograph of it shows, or only its top.
    func toggleStackOpen() {
        let targets = stackTargets
        guard let stack = selectionStack else { return }
        undoable(stack.open ? "Close Stack" : "Open Stack") { projects.setStacksOpen(!stack.open, holding: targets); return true }
        // Closed, the stack stands for itself by its top: that's the photograph selected.
        if stack.open, let top = stack.frames.first { selectShown(top) }
    }

    /// Selects the photograph shown at `path` alone (whatever its spelling).
    private func selectShown(_ path: String) {
        let key = ManualOrder.canonical(path)
        if let shown = model.shownPhotos.first(where: { ManualOrder.canonical($0.url.photoFile.labStandardized.path) == key }) { model.click(shown.url) }
    }

    /// Photo › Stack Bursts: the photographs shown taken less than 2 seconds apart with the same camera, each run a
    /// stack (those already in one left as they are). Read from the files, off the main thread.
    func stackBursts() {
        let photos = model.library.items.map(\.url.photoFile)
        Task { [weak self] in
            let facts = await Task.detached(priority: .userInitiated) {
                photos.map { url -> (path: String, time: TimeInterval?, camera: String?) in
                    let read = FrameFacts.read(url)
                    return (url.labStandardized.path, read.date?.timeIntervalSinceReferenceDate, read.camera)
                }
            }.value
            guard let self else { return }
            var made = 0
            undoable("Stack Bursts") { made = self.projects.stackBursts(facts); return made > 0 }
            note(made == 0 ? "No Burst" : "Stacked", made == 0 ? "no photographs here were taken under 2 s apart" : "\(made) \(made == 1 ? "burst" : "bursts")")
        }
    }
}
