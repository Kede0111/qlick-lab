// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The undo target of the Boxes' and the Archives' changes (`LabState.undoable`), apart from the editor's own so
/// opening a photograph doesn't forget them.
final class LibraryEditsUndoTarget: NSObject {}

/// The sidebar's gestures and the frames' commands on Boxes and Rolls: drag and drop, copy and paste, Add to Box,
/// Remove. Each is one undo step. Only the catalogue changes: never a file on the disk.
extension LabState {
    // MARK: Undo

    /// Makes a change to the Boxes or the Archives one undo step, named `name` in the Edit menu. Whether it changed
    /// anything.
    @discardableResult func undoable(_ name: String, _ change: () -> Bool) -> Bool {
        let before = projects.snapshot
        guard change(), projects.snapshot != before else { return false }
        registerUndo(name, back: before)
        libraryChanged()
        return true
    }

    private func registerUndo(_ name: String, back: ProjectStore.Snapshot) {
        guard let undo = model.undoManager else { return }
        let now = projects.snapshot
        undo.registerUndo(withTarget: libraryEdits) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.projects.restore(back)
                // Undone, it can be done again.
                self.registerUndo(name, back: now)
                self.libraryChanged()
            }
        }
        undo.setActionName(name)
    }

    /// The Boxes or the Archives changed: the list open on the sheet is listed again; a Roll moved to another Box is
    /// followed there; a list whose Box or Roll is gone or empty closes.
    func libraryChanged() {
        guard let directory = model.library.directory?.standardizedFileURL else { return }
        let views = projects.directory.appendingPathComponent("Views", isDirectory: true).standardizedFileURL.path
        guard directory.path.hasPrefix(views + "/") else { return }
        if let open = projects.view(of: directory) {
            if let holder = open.holder, !projects.isSmart(holder) {
                // A Box stays open while it's there (its shelf, or its empty state, shows); an empty Roll closes.
                let gone: Bool = switch holder {
                case .box(let id): projects.box(id) == nil
                case .roll: projects.frames(of: holder).isEmpty
                }
                if gone { model.closeFolder(); show(.library); return }
            }
            projects.viewFolder(for: open)
            // A Box whose own photographs all left keeps its shelf, no photograph open.
            if case .box(let id) = open, projects.ownFrames(of: .box(id)).isEmpty, model.source != nil {
                model.openList(directory, allowEmpty: true)
            }
            model.library.refreshNow()
            return
        }
        let parts = directory.path.dropFirst(views.count + 1).split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "roll", let id = UUID(uuidString: parts[2]), let box = projects.box(holdingRoll: id) {
            open(.roll(id, box: box))
            return
        }
        model.closeFolder()
        show(.library)
    }

    func note(_ text: String, _ detail: String) {
        model.libraryNote = EditorModel.LibraryNote(text: text, detail: detail, serial: (model.libraryNote?.serial ?? 0) + 1)
    }

    // MARK: Drops

    /// What a drop in the sidebar does: the same for the mouse and the lab's automation.
    func perform(_ plan: DropPlan, finder urls: [URL] = []) {
        guard plan.operation != .refused, let action = plan.action else { return }
        if case .importFinder(let archive) = action {
            if !urls.isEmpty { importFolders(urls, into: archive) }
            return
        }
        // Qlick Lab: folders from the Finder on the Archives' heading: an Archive of them, the photographs where they are.
        if case .newArchive(let folders, let from) = action, folders.isEmpty {
            let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
            guard !dirs.isEmpty else { return }
            return perform(DropPlan(operation: plan.operation, verb: plan.verb, rest: plan.rest, action: .newArchive(folders: dirs, from: from)))
        }
        let done = undoable(undoName(action, plan: plan)) { projects.apply(action) }
        guard done else { return }
        switch action {
        case .movePhotos(let urls, _, let target), .addPhotos(let urls, let target):
            note(action.isMove ? "Moved" : "Copied", "\(photographs(urls.count)) to “\(projects.shortName(target) ?? "")”")
        case .rollFromFolder(_, _, let box):
            sidebarFold.unfold(.box(box))
            note("Made", "the Roll " + (plan.rest.components(separatedBy: ",").first ?? ""))
        case .placeBox(_, let parent?, _): sidebarFold.unfold(.box(parent))
        case .newArchive: note("Made", "the Archive " + plan.rest)
        case .newBox, .newBoxForRoll, .newBoxFromArchive: note("Made", "the Box " + (plan.rest.components(separatedBy: ",").first ?? ""))
        case .rollFromArchive(_, let box):
            sidebarFold.unfold(.box(box))
            note("Made", "the Roll " + plan.rest)
        case .placeRoll(_, _, let into, _): sidebarFold.unfold(.box(into))
        default: break
        }
    }

    private func undoName(_ action: DropAction, plan: DropPlan) -> String {
        switch action {
        case .addPhotos(let urls, _): "Copy \(Self.title(urls.count))"
        case .movePhotos(let urls, _, _): "Move \(Self.title(urls.count))"
        case .rollFromFolder: "New Roll"
        case .addFolder: "Copy Photographs"
        case .placeBox: "Move Box"
        case .placeRoll: "Move Roll"
        case .placeArchive: "Move Archive"
        case .moveFolder: plan.operation == .move ? "Move Folder" : "Add Folder"
        case .importFinder: "Import"
        case .newArchive: "New Archive"
        case .newBox, .newBoxForRoll, .newBoxFromArchive: "New Box"
        case .rollFromArchive: "New Roll"
        case .addArchive: "Copy Photographs"
        case .looseRoll: "Move Roll"
        case .newLooseRoll: "New Roll"
        }
    }

    /// "Photograph", "12 Photographs": for the Edit menu's Undo.
    static func title(_ count: Int) -> String { count == 1 ? "Photograph" : "\(count) Photographs" }

    // MARK: Drags

    /// The photographs a drag from a frame carries: the selection if the frame is in it, else the frame alone; and the
    /// Box or Roll open, which a drop on another one moves them out of.
    func photoDrag(from url: URL) -> LabDragItem {
        let frames = model.contextTargets(url).map(\.photoFile)
        var seen: Set<URL> = []
        return .photos(frames.filter { seen.insert($0).inserted }, from: openHolder)
    }

    /// Starts a drag inside the lab: what it carries is kept here, the item says only that it's the lab's.
    func provider(dragging item: LabDragItem) -> NSItemProvider {
        dragging = item
        sidebarDrop.dragStarted()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: LabDragItem.type.identifier, visibility: .ownProcess) { done in
            done(Data("qlick-lab".utf8), nil)
            return nil
        }
        return provider
    }

    // MARK: Copy and paste

    /// ⌘C: the photographs selected, for ⌘V in a Box or a Roll (and the edits, as before, for Paste Edits).
    func copyPhotos() {
        let frames = selectionTargets
        guard !frames.isEmpty else { return }
        var seen: Set<URL> = []
        copiedPhotos = frames.filter { seen.insert($0).inserted }
    }

    /// Where ⌘V puts the photographs copied: the Box or Roll open, if some of them aren't in it yet. Otherwise ⌘V
    /// pastes the edits, as it always has.
    var pasteTarget: Holder? {
        guard let holder = openHolder, !copiedPhotos.isEmpty else { return nil }
        let inside = Set(projects.ownFrames(of: holder))
        return copiedPhotos.contains { !inside.contains($0.standardizedFileURL.path) } ? holder : nil
    }

    /// ⌘V, or Paste in a Box's menu: the photographs copied are added (never moved: they stay where they were too).
    func pastePhotos(into holder: Holder? = nil) {
        guard let holder = holder ?? pasteTarget, !copiedPhotos.isEmpty, !projects.isSmart(holder) else { return }
        let inside = Set(projects.ownFrames(of: holder))
        let new = copiedPhotos.filter { !inside.contains($0.standardizedFileURL.path) }
        guard !new.isEmpty else { return note("Already There", "in “\(projects.shortName(holder) ?? "")”") }
        if undoable("Paste \(Self.title(new.count))", { projects.addFrames(new, to: holder); return true }) {
            note("Pasted", "\(photographs(new.count)) in “\(projects.shortName(holder) ?? "")”")
        }
    }

    // MARK: The frames' commands

    func add(_ frames: [URL], to holder: Holder) {
        guard !frames.isEmpty else { return }
        guard !projects.isSmart(holder) else { return note("Not Added", "a Smart Roll is filled by its rules") }
        let inside = Set(projects.ownFrames(of: holder))
        let new = frames.filter { !inside.contains($0.photoFile.standardizedFileURL.path) }
        guard !new.isEmpty else { return note("Already There", "in “\(projects.shortName(holder) ?? "")”") }
        if undoable("Add \(Self.title(new.count)) to Box", { projects.addFrames(new, to: holder); return true }) {
            note("Added", "\(photographs(new.count)) to “\(projects.shortName(holder) ?? "")”")
            // Qlick Lab: with "One film stock per Roll", what goes into a Roll takes its look.
            if Self.oneStockPerRoll, case .roll(let id, let box) = holder, let look = projects.boxRoll(id, in: box)?.roll.look {
                model.labApplyLook(look, to: new)
            }
        }
    }

    /// Settings › Photographs › Rolls › "One film stock per Roll".
    static let oneStockKey = "qlick.oneStockPerRoll"
    static var oneStockPerRoll: Bool { UserDefaults.standard.bool(forKey: oneStockKey) }

    /// A Roll's look chosen from its menu: kept on the Roll and given to its photographs.
    func setRollLook(_ look: String, of holder: Holder) {
        guard case .roll(let id, let box) = holder else { return }
        projects.changeBox(box) { b in
            if let i = b.rolls.firstIndex(where: { $0.id == id }) { b.rolls[i].look = look }
        }
        let photos = projects.frames(of: holder).map { URL(fileURLWithPath: $0, isDirectory: false) }
        model.labApplyLook(look, to: photos)
    }

    /// Remove from Box: out of the Box or Roll open (a Box's own photographs: its Boxes' and Rolls' stay). The files stay.
    func removeFromOpenHolder(_ frames: [URL]) {
        guard let holder = openHolder, !frames.isEmpty else { return }
        let name = projects.shortName(holder) ?? ""
        if undoable("Remove \(Self.title(frames.count)) from Box", { projects.removeFrames(frames, from: holder); return true }) {
            note("Removed", "\(photographs(frames.count)) from “\(name)”")
        }
    }
}

extension DropAction {
    var isMove: Bool { if case .movePhotos = self { return true }; return false }
}
