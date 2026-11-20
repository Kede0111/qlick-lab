// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Boxes: photographs chosen from any Archive, shown on one contact sheet (`ProjectStore.viewFolder`). The photographs
/// stay in their folders, with their marks and developments; a Box or a Roll only lists them.
extension LabState {
    /// The heading of the sheet on screen and of its print: the Folder (its Archive, film, camera, notes), the whole
    /// Archive, or the Box or Roll (the Boxes holding it).
    var sheetHeading: SheetHeading {
        var heading = SheetHeading()
        let view = openView
        if let current {
            heading.title = current.roll.name
            heading.subtitle = [current.project.name, current.roll.film, current.roll.camera].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            heading.notes = current.roll.notes
        } else if case .archive(let id)? = view, let archive = projects.archive(id) {
            let folders = projects.roots(of: archive).count
            heading.title = archive.name
            heading.subtitle = "Archive  ·  \(folders) folder\(folders == 1 ? "" : "s")"
            heading.notes = archive.notes
        } else if case .box(let id)? = view, let path = projects.boxPath(id) {
            heading.title = path.last?.name ?? ""
            heading.subtitle = (["Box"] + path.dropLast().map(\.name)).joined(separator: "  ·  ")
        } else if case .roll(let id, let box)? = view, let path = projects.boxPath(box), let roll = path.last?.rolls.first(where: { $0.id == id }) {
            heading.title = roll.name
            heading.subtitle = (["Roll"] + path.map(\.name)).joined(separator: "  ·  ")
        }
        return heading
    }

    /// The frames a command acts on: the sheet's selection, or the frame under the pointer.
    var selectionTargets: [URL] { model.ratingTargets.map(\.photoFile) }

    func newBox(in parent: UUID? = nil, with frames: [URL] = []) {
        naming = Naming(kind: .box(in: parent), name: projects.uniqueBoxName("New Box", in: parent), frames: frames)
    }

    func newRoll(in box: UUID, with frames: [URL] = []) {
        naming = Naming(kind: .roll(in: box), name: "New Roll", frames: frames)
    }

    func add(_ frames: [URL], to holder: Holder) {
        guard !frames.isEmpty else { return }
        projects.addFrames(frames, to: holder)
        holderChanged(holder)
    }

    func removeFromOpenHolder(_ frames: [URL]) {
        guard let holder = openHolder, !frames.isEmpty else { return }
        projects.removeFrames(frames, from: holder)
        if projects.frames(of: holder).isEmpty {
            model.closeFolder()
            show(.library)
            return
        }
        holderChanged(holder)
    }

    /// A Box's or Roll's photographs changed: the Box or Roll on the sheet is listed again (it may hold `holder`).
    func holderChanged(_ holder: Holder) {
        guard let open = openView, open.holder != nil else { return }
        let list = projects.viewFolder(for: open)
        if model.library.directory?.standardizedFileURL.path == list.standardizedFileURL.path { model.library.refreshNow() }
    }

    /// Forgets a Box with what's inside it, once asked. The photographs aren't touched.
    func deleteBox(_ id: UUID) {
        guard let box = projects.box(id) else { return }
        let inside = box.all.count - 1 + box.all.reduce(0) { $0 + $1.rolls.count }
        Task {
            let answer = await model.ask(AppAlert(
                title: "Delete the Box “\(box.name)”?",
                detail: (inside > 0 ? "The Boxes and Rolls inside it go with it. " : "")
                    + "The photographs stay where they are, on the disk, in their Archives and in other Boxes.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Delete", role: .destructive)]))
            guard answer.button == 1 else { return }
            let showing = openView.map { view -> Bool in
                switch view {
                case .box(let open): return box.all.contains { $0.id == open }
                case .roll(_, let open): return box.all.contains { $0.id == open }
                default: return false
                }
            } ?? false
            projects.deleteBox(id)
            if showing { model.closeFolder(); show(.library) }
        }
    }

    func deleteRoll(_ id: UUID, in boxID: UUID) {
        guard let found = projects.boxRoll(id, in: boxID) else { return }
        Task {
            let answer = await model.ask(AppAlert(
                title: "Delete the Roll “\(found.roll.name)”?",
                detail: "The photographs stay where they are, on the disk, in their Archives and in other Boxes.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Delete", role: .destructive)]))
            guard answer.button == 1 else { return }
            let showing = openView == .roll(id, box: boxID)
            projects.deleteRoll(id, in: boxID)
            if showing { model.closeFolder(); show(.library) }
        }
    }

    /// Every Box and Roll photographs can go in, by the names they go by (“Spain › Madrid › Day 1”), the one open left out.
    var holderChoices: [(holder: Holder, name: String, depth: Int)] { holderChoicesAll.filter { $0.holder != openHolder } }

    /// Every Box and Roll, depth first, with the names they go by and how deep they are.
    var holderChoicesAll: [(holder: Holder, name: String, depth: Int)] {
        var choices: [(Holder, String, Int)] = []
        func walk(_ box: LabBox, path: [String]) {
            let names = path + [box.name]
            choices.append((.box(box.id), names.joined(separator: " › "), path.count))
            for inner in box.boxes { walk(inner, path: names) }
            for roll in box.rolls { choices.append((.roll(roll.id, box: box.id), (names + [roll.name]).joined(separator: " › "), path.count + 1)) }
        }
        for box in projects.boxes { walk(box, path: []) }
        return choices.map { (holder: $0.0, name: $0.1, depth: $0.2) }
    }

    /// Add to Box, and Remove from the Box or Roll open: the frames' menus in the contact sheet and in Develop
    /// (AppKit menus).
    func boxItems(for frames: [URL]) -> [NSMenuItem] {
        let several = frames.count > 1 ? " (\(frames.count) photos)" : ""
        let menu = NSMenu()
        let choices = holderChoices
        for choice in choices {
            menu.addItem(ClosureMenuItem(choice.name) { [weak self] in self?.add(frames, to: choice.holder) })
        }
        if !choices.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Box…") { [weak self] in self?.newBox(with: frames) })
        let add = NSMenuItem(title: "Add to Box" + several, action: nil, keyEquivalent: "")
        add.submenu = menu
        var items = [add]
        if let open = openHolder, let name = projects.name(of: open) {
            items.append(ClosureMenuItem("Remove from “\(name)”" + several) { [weak self] in self?.removeFromOpenHolder(frames) })
        }
        return items
    }
}

/// The same, for SwiftUI menus (the grid and the film strip).
struct BoxMenuItems: View {
    let lab: LabState
    let frames: [URL]

    var body: some View {
        let several = frames.count > 1 ? " (\(frames.count) photos)" : ""
        let choices = lab.holderChoices
        Menu("Add to Box" + several) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.name) { lab.add(frames, to: choice.holder) }
            }
            if !choices.isEmpty { Divider() }
            Button("New Box…") { lab.newBox(with: frames) }
        }
        if let open = lab.openHolder, let name = lab.projects.name(of: open) {
            Button("Remove from “\(name)”" + several) { lab.removeFromOpenHolder(frames) }
        }
    }
}

/// The sidebar's rows unfolded or folded by hand. A row on the way to what's open unfolds by itself, unless folded
/// by hand.
struct SidebarFold: Equatable {
    enum Row: Hashable {
        case archive(UUID)
        case folder(String)
        case box(UUID)
    }
    private(set) var opened: Set<Row> = []
    private(set) var folded: Set<Row> = []

    func isOpen(_ row: Row, leadsToOpen: Bool = false) -> Bool {
        opened.contains(row) || (leadsToOpen && !folded.contains(row))
    }

    mutating func toggle(_ row: Row, leadsToOpen: Bool = false) {
        if isOpen(row, leadsToOpen: leadsToOpen) { opened.remove(row); folded.insert(row) } else { unfold(row) }
    }

    mutating func unfold(_ row: Row) { opened.insert(row); folded.remove(row) }
}
