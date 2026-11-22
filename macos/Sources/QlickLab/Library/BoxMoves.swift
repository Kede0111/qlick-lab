// Qlick Lab — GPL-3.0-only.
import Foundation
import UniformTypeIdentifiers

/// What a drag inside the lab carries: photographs (with the Box or Roll they were dragged out of, if any), or a row
/// of the sidebar. Files from the Finder are known only once dropped.
enum LabDragItem: Equatable, Sendable {
    case photos([URL], from: Holder?)
    case box(UUID)
    case roll(UUID, box: UUID)
    case archive(UUID)
    case folder(String, archive: UUID)
    case finder

    /// The lab's own drags: seen by the lab only (`visibility: .ownProcess`), never by the Finder, so nothing dragged
    /// out of the lab can move a file.
    static let type = UTType(exportedAs: "be.jackfrom.qlicklab.drag", conformingTo: .data)
}

/// A row of the sidebar a drag can end on.
enum SidebarTarget: Hashable, Sendable {
    case archive(UUID)
    case folder(String, archive: UUID)
    case box(UUID)
    case roll(UUID, box: UUID)
    /// Qlick Lab: the Archives' heading: a folder dropped there becomes an Archive of its own.
    case archives
    /// The Boxes' heading and the empty place under them: what's dropped there makes a new Box.
    case boxes
}

/// Where a drop goes against a row: before it, in it, after it.
enum DropZone: Sendable { case before, on, after }

/// What a drop does. Only the catalogue changes: the Boxes, the Archives' order and Folders. Never a file.
enum DropAction: Equatable, Sendable {
    case addPhotos([URL], to: Holder)
    case movePhotos([URL], from: Holder, to: Holder)
    /// A Folder dropped on a Box: a Roll in it, holding the folder's photographs.
    case rollFromFolder(String, archive: UUID, in: UUID)
    /// A Folder dropped on a Roll: its photographs added.
    case addFolder(String, to: Holder)
    case placeBox(UUID, in: UUID?, at: Int)
    case placeRoll(UUID, from: UUID, in: UUID, at: Int)
    case placeArchive(UUID, at: Int)
    /// A Folder dropped on another Archive: it joins it (an imported location leaves the first one).
    case moveFolder(String, from: UUID, to: UUID)
    /// Folders from the Finder: Import opens on them.
    case importFinder(into: UUID?)
    /// Qlick Lab: folders (from an Archive, `from`, or the Finder) made a new Archive, named after the first, the
    /// photographs where they are.
    case newArchive(folders: [String], from: UUID?)
    /// A new Box at the top, named `name`, holding `frames`, or the photographs of `folder`.
    case newBox(String, frames: [URL], folder: String?)
    /// A Roll dropped on the Boxes: a new Box named after it, holding it.
    case newBoxForRoll(UUID, from: UUID)
    /// A whole Archive dropped on a Box: a Roll named after it, holding its photographs.
    case rollFromArchive(UUID, in: UUID)
    /// A whole Archive dropped on a Roll: its photographs added.
    case addArchive(UUID, to: Holder)
    /// A whole Archive dropped on the Boxes: a new Box named after it, holding its photographs.
    case newBoxFromArchive(UUID)
    /// Qlick Lab: a Roll at the top of the Boxes, in no Box (`ProjectStore.looseID`): one moved out of its Box, or a
    /// new one named `name` holding `frames`, the photographs of `folder`, or those of an Archive.
    case looseRoll(UUID, from: UUID)
    case newLooseRoll(String, frames: [URL], folder: String?, archive: UUID?)
}

/// What a drop on a row would do, said before it's done: the label under the row and the pointer's badge.
struct DropPlan: Equatable, Sendable {
    /// Copy: the green + by the pointer; move: the plain arrow; refused: nothing happens, the row stays dark.
    enum Operation: Sendable { case copy, move, refused }
    var operation: Operation
    /// The label's first word, shown stronger ("Move", "Copy"); empty for a refusal.
    var verb: String
    var rest: String
    var action: DropAction?
    /// A line before or after the row (a place among others), rather than the row lit (into it).
    var line: DropZone? = nil

    var label: String { verb.isEmpty ? rest : verb + " " + rest }

    static func refused(_ why: String) -> DropPlan { DropPlan(operation: .refused, verb: "", rest: why, action: nil) }
}

/// "1 photograph", "12 photographs".
func photographs(_ count: Int) -> String { count == 1 ? "1 photograph" : "\(count) photographs" }

extension ProjectStore {
    // MARK: What a drop would do

    /// What dropping `item` on the row `target` does, `fraction` of the way down the row (0 at its top); `copying`
    /// when ⌥ is held. Nil when it would do nothing worth saying (a row dropped where it already is).
    func plan(_ item: LabDragItem, onto target: SidebarTarget, at fraction: Double, copying: Bool) -> DropPlan? {
        if target == .archives { return planOntoArchives(item) }
        if target == .boxes { return planOntoBoxes(item, alternate: copying) }
        let edges: DropZone = fraction < 0.25 ? .before : fraction > 0.75 ? .after : .on
        let halves: DropZone = fraction < 0.5 ? .before : .after
        switch item {
        case .photos(let urls, let source):
            guard !urls.isEmpty else { return nil }
            guard let holder = target.holder else { return .refused(Self.diskAsItIs) }
            let name = shortName(holder) ?? ""
            if isSmart(holder) { return .refused(Self.smartByRules(name)) }
            if source == holder { return .refused("Already in “\(name)”") }
            if let source, exists(source), !copying {
                return DropPlan(operation: .move, verb: "Move", rest: "\(photographs(urls.count)) to “\(name)”",
                                action: .movePhotos(urls, from: source, to: holder))
            }
            let inside = Set(ownFrames(of: holder))
            let new = urls.filter { !inside.contains($0.photoFile.labStandardized.path) }
            guard !new.isEmpty else { return .refused(urls.count == 1 ? "Already in “\(name)”" : "All already in “\(name)”") }
            let already = urls.count - new.count
            return DropPlan(operation: .copy, verb: "Copy",
                            rest: "\(photographs(new.count)) to “\(name)”" + (already > 0 ? " (\(already) already in it)" : ""),
                            action: .addPhotos(new, to: holder))

        case .folder(let path, let archiveID):
            let folderName = archive(archiveID).map { folder(path, in: $0).name } ?? (path as NSString).lastPathComponent
            let count = node(path)?.total
            switch target {
            case .box(let id):
                guard let box = box(id) else { return nil }
                if count == 0 { return .refused("No photographs in “\(folderName)”") }
                return DropPlan(operation: .copy, verb: "New Roll",
                                rest: "“\(folderName)” in “\(box.name)”" + (count.map { ", \(photographs($0))" } ?? ""),
                                action: .rollFromFolder(path, archive: archiveID, in: id))
            case .roll(let id, let boxID):
                guard let roll = boxRoll(id, in: boxID)?.roll else { return nil }
                if roll.isSmart { return .refused(Self.smartByRules(roll.name)) }
                if count == 0 { return .refused("No photographs in “\(folderName)”") }
                return DropPlan(operation: .copy, verb: "Copy", rest: "the photographs of “\(folderName)” to “\(roll.name)”",
                                action: .addFolder(path, to: .roll(id, box: boxID)))
            case .archive(let id):
                guard let other = archive(id) else { return nil }
                if id == archiveID || other.rolls.contains(where: { $0.folder == path }) { return .refused("Already in “\(other.name)”") }
                let leaves = archive(archiveID).map { roots(of: $0).contains(URL(fileURLWithPath: path, isDirectory: true)) } ?? false
                return DropPlan(operation: leaves ? .move : .copy, verb: leaves ? "Move" : "Add", rest: "the folder “\(folderName)” to “\(other.name)”",
                                action: .moveFolder(path, from: archiveID, to: id))
            case .folder:
                return .refused(Self.diskAsItIs)
            case .archives, .boxes: return nil
            }

        case .box(let id):
            guard let moving = box(id) else { return nil }
            switch target {
            case .box(let other) where edges == .on, .roll(_, box: let other):
                if other == id || moving.all.contains(where: { $0.id == other }) { return .refused("A Box can’t go inside itself") }
                guard let into = box(other) else { return nil }
                if place(ofBox: id)?.parent == other { return .refused("Already in “\(into.name)”") }
                return DropPlan(operation: .move, verb: "Move", rest: "“\(moving.name)” into “\(into.name)”",
                                action: .placeBox(id, in: other, at: into.boxes.count))
            case .box(let other):
                guard other != id, let beside = box(other), let at = place(ofBox: other) else { return nil }
                if let parent = at.parent, parent == id || moving.all.contains(where: { $0.id == parent }) {
                    return .refused("A Box can’t go inside itself")
                }
                let index = at.index + (edges == .after ? 1 : 0)
                if let now = place(ofBox: id), now.parent == at.parent, index == now.index || index == now.index + 1 { return nil }
                return DropPlan(operation: .move, verb: "Place", rest: "“\(moving.name)” \(edges == .after ? "after" : "before") “\(beside.name)”",
                                action: .placeBox(id, in: at.parent, at: index), line: edges)
            case .archive, .folder:
                return .refused("A Box goes in the Boxes, not in an Archive")
            case .archives, .boxes: return nil
            }

        case .roll(let id, let from):
            guard let moving = boxRoll(id, in: from)?.roll else { return nil }
            switch target {
            case .box(let other):
                guard let into = box(other) else { return nil }
                if other == from { return .refused("Already in “\(into.name)”") }
                return DropPlan(operation: .move, verb: "Move", rest: "“\(moving.name)” into “\(into.name)”",
                                action: .placeRoll(id, from: from, in: other, at: into.rolls.count))
            case .roll(let other, let otherBox):
                guard other != id, let into = box(otherBox), let at = into.rolls.firstIndex(where: { $0.id == other }) else { return nil }
                let index = at + (halves == .after ? 1 : 0)
                if otherBox == from, let now = into.rolls.firstIndex(where: { $0.id == id }), index == now || index == now + 1 { return nil }
                return DropPlan(operation: .move, verb: "Place", rest: "“\(moving.name)” \(halves == .after ? "after" : "before") “\(into.rolls[at].name)”",
                                action: .placeRoll(id, from: from, in: otherBox, at: index), line: halves)
            case .archive, .folder:
                return .refused("A Roll goes in a Box, not in an Archive")
            case .archives, .boxes: return nil
            }

        case .archive(let id):
            // Qlick Lab: a whole Archive on a Box makes a Roll of its photographs there; on a Roll, they're added.
            if let holder = target.holder, let source = archive(id) {
                let name = shortName(holder) ?? ""
                if isSmart(holder) { return .refused(Self.smartByRules(name)) }
                if case .box(let boxID) = holder {
                    return DropPlan(operation: .copy, verb: "New Roll", rest: "“\(source.name)” in “\(name)”", action: .rollFromArchive(id, in: boxID))
                }
                return DropPlan(operation: .copy, verb: "Copy", rest: "the photographs of “\(source.name)” to “\(name)”", action: .addArchive(id, to: holder))
            }
            guard case .archive(let other) = target else { return nil }
            guard other != id, let moving = archive(id), let at = projects.firstIndex(where: { $0.id == other }) else { return nil }
            let index = at + (halves == .after ? 1 : 0)
            if let now = projects.firstIndex(where: { $0.id == id }), index == now || index == now + 1 { return nil }
            return DropPlan(operation: .move, verb: "Place", rest: "“\(moving.name)” \(halves == .after ? "after" : "before") “\(projects[at].name)”",
                            action: .placeArchive(id, at: index), line: halves)

        case .finder:
            switch target {
            case .archive(let id), .folder(_, archive: let id):
                guard let into = archive(id) else { return nil }
                return DropPlan(operation: .copy, verb: "Import", rest: "into “\(into.name)”", action: .importFinder(into: id))
            case .box, .roll:
                return DropPlan(operation: .copy, verb: "Import", rest: "the folder", action: .importFinder(into: nil))
            case .archives, .boxes: return nil
            }
        }
    }

    static let diskAsItIs = "The disk is shown as it is: drop photographs on a Box or a Roll"
    /// Qlick Lab: why nothing goes into a Smart Roll by hand.
    static func smartByRules(_ name: String) -> String { "“\(name)” is a Smart Roll: its rules fill it" }

    /// A Box's or a Roll's own name (not its Boxes').
    func shortName(_ holder: Holder) -> String? {
        switch holder {
        case .box(let id): box(id)?.name
        case .roll(let id, let boxID): boxRoll(id, in: boxID)?.roll.name
        }
    }

    // MARK: Doing it

    /// Does a drop's action on the catalogue. Whether anything changed. (`importFinder` is the lab's: nothing here.)
    @discardableResult func apply(_ action: DropAction) -> Bool {
        let before = snapshot
        switch action {
        case .addPhotos(let urls, let holder): addFrames(urls, to: holder)
        case .movePhotos(let urls, let source, let target): moveFrames(urls, from: source, to: target)
        case .rollFromFolder(let path, let archiveID, let boxID):
            let name = archive(archiveID).map { folder(path, in: $0).name } ?? (path as NSString).lastPathComponent
            createRoll(named: name, in: boxID, frames: folderPhotos(path))
        case .addFolder(let path, let holder): addFrames(folderPhotos(path), to: holder)
        case .placeBox(let id, let parent, let index): moveBox(id, into: parent, at: index)
        case .placeRoll(let id, let from, let into, let index): moveBoxRoll(id, from: from, into: into, at: index)
        case .placeArchive(let id, let index):
            var ids = projects.map(\.id)
            guard let now = ids.firstIndex(of: id) else { return false }
            ids.remove(at: now)
            ids.insert(id, at: min(index > now ? index - 1 : index, ids.count))
            reorderArchives(ids)
        case .moveFolder(let path, let from, let to):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if let source = archive(from), let entry = source.rolls.first(where: { $0.folder == path }), roots(of: source).contains(url) {
                moveRoll(entry.id, from: from, to: to)
            } else {
                addRolls([url], to: to)
            }
        case .importFinder: return false
        case .newArchive(let folders, let from):
            guard let first = folders.first else { return false }
            let made = create(named: (first as NSString).lastPathComponent)
            for path in folders {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if let from, let source = archive(from), let entry = source.rolls.first(where: { $0.folder == path }), roots(of: source).contains(url) {
                    moveRoll(entry.id, from: from, to: made.id)
                } else {
                    addRolls([url], to: made.id)
                }
            }
        case .newBox(let name, let frames, let folder):
            createBox(named: name, frames: folder.map(folderPhotos) ?? frames)
        case .newBoxForRoll(let id, let from):
            guard let roll = boxRoll(id, in: from)?.roll, let box = createBox(named: roll.name) else { return false }
            moveBoxRoll(id, from: from, into: box.id, at: 0)
        case .rollFromArchive(let id, let boxID):
            guard let source = archive(id) else { return false }
            createRoll(named: source.name, in: boxID, frames: archivePhotos(id))
        case .addArchive(let id, let holder):
            addFrames(archivePhotos(id), to: holder)
        case .newBoxFromArchive(let id):
            guard let source = archive(id) else { return false }
            createBox(named: source.name, frames: archivePhotos(id))
        case .looseRoll(let id, let from):
            let loose = looseBoxID()
            moveBoxRoll(id, from: from, into: loose, at: box(loose)?.rolls.count ?? 0)
        case .newLooseRoll(let name, let frames, let folder, let archiveID):
            let photos = archiveID.map(archivePhotos) ?? folder.map(folderPhotos) ?? frames
            createRoll(named: name, in: looseBoxID(), frames: photos)
        }
        return snapshot != before
    }

    /// A drop on the Archives' heading: a folder becomes an Archive of its own.
    private func planOntoArchives(_ item: LabDragItem) -> DropPlan? {
        switch item {
        case .folder(let path, let archiveID):
            let name = archive(archiveID).map { folder(path, in: $0).name } ?? (path as NSString).lastPathComponent
            return DropPlan(operation: .copy, verb: "New Archive", rest: "“\(name)”", action: .newArchive(folders: [path], from: archiveID))
        case .finder:
            return DropPlan(operation: .copy, verb: "New Archive", rest: "of the folder, where it is", action: .newArchive(folders: [], from: nil))
        default:
            return .refused("Drop a folder here to make an Archive")
        }
    }

    /// A drop on the Boxes' heading or under them: a new Box, named after the folder, holding what's dropped.
    /// A drop on the Boxes' heading or the place under them: a new Box, or with ⌥ (`alternate`) a new Roll at the top,
    /// in no Box. A Roll from a Box goes to the top as it is; with ⌥ a new Box is made round it.
    private func planOntoBoxes(_ item: LabDragItem, alternate: Bool) -> DropPlan? {
        switch item {
        case .photos(let urls, _):
            guard let first = urls.first else { return nil }
            let name = first.photoFile.deletingLastPathComponent().lastPathComponent
            if alternate {
                return DropPlan(operation: .copy, verb: "New Roll", rest: "“\(name)”, \(photographs(urls.count)) (⌥: a Roll, not a Box)",
                                action: .newLooseRoll(name, frames: urls, folder: nil, archive: nil))
            }
            return DropPlan(operation: .copy, verb: "New Box", rest: "“\(name)”, \(photographs(urls.count)) (⌥ for a Roll)", action: .newBox(name, frames: urls, folder: nil))
        case .folder(let path, let archiveID):
            let name = archive(archiveID).map { folder(path, in: $0).name } ?? (path as NSString).lastPathComponent
            if node(path)?.total == 0 { return .refused("No photographs in “\(name)”") }
            if alternate {
                return DropPlan(operation: .copy, verb: "New Roll", rest: "“\(name)” (⌥: a Roll, not a Box)", action: .newLooseRoll(name, frames: [], folder: path, archive: nil))
            }
            return DropPlan(operation: .copy, verb: "New Box", rest: "“\(name)” (⌥ for a Roll)", action: .newBox(name, frames: [], folder: path))
        case .roll(let id, let from):
            guard let roll = boxRoll(id, in: from)?.roll else { return nil }
            if alternate {
                return DropPlan(operation: .move, verb: "New Box", rest: "“\(roll.name)” holding the Roll", action: .newBoxForRoll(id, from: from))
            }
            if from == Self.looseID { return .refused("Already at the top of the Boxes") }
            return DropPlan(operation: .move, verb: "Move", rest: "“\(roll.name)” to the top of the Boxes (⌥ for a Box round it)", action: .looseRoll(id, from: from))
        case .box(let id):
            guard let at = place(ofBox: id), at.parent != nil else { return .refused("Already in the Boxes") }
            return DropPlan(operation: .move, verb: "Move", rest: "“\(box(id)?.name ?? "")” to the top of the Boxes", action: .placeBox(id, in: nil, at: boxes.count))
        case .finder:
            return .refused("Drop the folder on Archives first")
        case .archive(let id):
            guard let source = archive(id) else { return nil }
            if alternate {
                return DropPlan(operation: .copy, verb: "New Roll", rest: "“\(source.name)” (⌥: a Roll, not a Box)", action: .newLooseRoll(source.name, frames: [], folder: nil, archive: id))
            }
            return DropPlan(operation: .copy, verb: "New Box", rest: "“\(source.name)” (⌥ for a Roll)", action: .newBoxFromArchive(id))
        }
    }

    /// The photographs of every Folder of an Archive.
    func archivePhotos(_ id: UUID) -> [URL] {
        guard let source = archive(id) else { return [] }
        var seen = Set<String>()
        return roots(of: source).flatMap { folderPhotos($0.path) }.filter { seen.insert($0.labStandardized.path).inserted }
    }

    /// The photographs of a folder and of every folder under it, as its sheet shows them.
    func folderPhotos(_ path: String) -> [URL] {
        photoFolders(under: path).flatMap { (try? PhotoFolder.images(in: $0)) ?? [] }
    }

    // MARK: The Boxes' moves

    /// Takes photographs from one Box or Roll to another: in the second, out of the first (and out of everything inside
    /// it that shows them, except the second itself). The photographs stay where they are on the disk.
    func moveFrames(_ frames: [URL], from source: Holder, to target: Holder) {
        guard source != target, exists(source), exists(target) else { return }
        let moving = Self.paths(frames)
        var tree = boxes
        tree.add(moving, to: target)
        tree.strip(Set(moving), from: source, keeping: target)
        replaceBoxes(tree)
    }

    /// Where a Box is: the Box holding it (nil on top) and its place there.
    func place(ofBox id: UUID) -> (parent: UUID?, index: Int)? {
        if let index = boxes.firstIndex(where: { $0.id == id }) { return (nil, index) }
        for box in allBoxes {
            if let index = box.boxes.firstIndex(where: { $0.id == id }) { return (box.id, index) }
        }
        return nil
    }

    /// The Box holding the Roll `id`, wherever it went.
    func box(holdingRoll id: UUID) -> UUID? { allBoxes.first { $0.rolls.contains { $0.id == id } }?.id }

    /// Puts a Box inside another (or on top, `parent` nil), at `index` among those there. Never inside itself or a Box
    /// inside it. Whether it moved.
    @discardableResult func moveBox(_ id: UUID, into parent: UUID?, at index: Int) -> Bool {
        guard let moving = box(id), let from = place(ofBox: id) else { return false }
        if let parent {
            guard box(parent) != nil, !moving.all.contains(where: { $0.id == parent }) else { return false }
        }
        var tree = boxes
        if from.parent == nil { tree.remove(at: from.index) } else { _ = tree.change(from.parent!) { $0.boxes.remove(at: from.index) } }
        let index = from.parent == parent && from.index < index ? index - 1 : index
        if let parent {
            _ = tree.change(parent) { $0.boxes.insert(moving, at: max(0, min(index, $0.boxes.count))) }
        } else {
            tree.insert(moving, at: max(0, min(index, tree.count)))
        }
        guard tree != boxes else { return false }
        replaceBoxes(tree)
        return true
    }

    /// Puts a Roll in a Box (the same or another), at `index` among its Rolls. Whether it moved.
    @discardableResult func moveBoxRoll(_ id: UUID, from: UUID, into: UUID, at index: Int) -> Bool {
        guard let roll = boxRoll(id, in: from)?.roll, box(into) != nil,
              let now = box(from)?.rolls.firstIndex(where: { $0.id == id }) else { return false }
        var tree = boxes
        _ = tree.change(from) { $0.rolls.remove(at: now) }
        let index = from == into && now < index ? index - 1 : index
        _ = tree.change(into) { $0.rolls.insert(roll, at: max(0, min(index, $0.rolls.count))) }
        guard tree != boxes else { return false }
        replaceBoxes(tree)
        return true
    }
}

extension SidebarTarget {
    var holder: Holder? {
        switch self {
        case .box(let id): .box(id)
        case .roll(let id, let box): .roll(id, box: box)
        default: nil
        }
    }
}

extension Array where Element == LabBox {
    /// Changes the Box `id`, at any depth. Whether it was found.
    mutating func change(_ id: UUID, _ body: (inout LabBox) -> Void) -> Bool {
        for index in indices where self[index].change(id, body) { return true }
        return false
    }

    /// Puts paths in a Box or a Roll, after those it has, each once.
    mutating func add(_ paths: [String], to holder: Holder) {
        func add(_ list: inout [String]) {
            let known = Set(list)
            var seen: Set<String> = []
            list += paths.filter { !known.contains($0) && seen.insert($0).inserted }
        }
        switch holder {
        case .box(let id): _ = change(id) { add(&$0.frames) }
        case .roll(let id, let boxID):
            _ = change(boxID) { box in if let index = box.rolls.firstIndex(where: { $0.id == id }) { add(&box.rolls[index].frames) } }
        }
    }

    /// Takes paths out of a Box (its own photographs: what its list shows) or a Roll, leaving `keeping` as it is.
    mutating func strip(_ gone: Set<String>, from holder: Holder, keeping: Holder?) {
        switch holder {
        case .box(let id):
            guard keeping != holder else { return }
            _ = change(id) { $0.frames.removeAll { gone.contains($0) } }
        case .roll(let id, let boxID):
            _ = change(boxID) { box in if let index = box.rolls.firstIndex(where: { $0.id == id }) { box.rolls[index].frames.removeAll { gone.contains($0) } } }
        }
    }
}
