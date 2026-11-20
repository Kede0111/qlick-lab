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
            heading.subtitle = ([roll.isSmart ? "Smart Roll" : "Roll"] + path.map(\.name)).joined(separator: "  ·  ")
        } else if let view, let title = Self.fixedTitle(view) {
            heading.title = title
            switch view {
            case .day(let key):
                heading.title = SmartRule.period(key).map { start in
                    switch key.split(separator: "-").count {
                    case 1: return key
                    case 2: return start.start.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_GB")))
                    default: return start.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "en_GB")))
                    }
                } ?? key
                heading.subtitle = "By Date"
            case .lastImport: heading.subtitle = lastImportDate.map { "Imported " + $0.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "en_GB"))) } ?? "The last import"
            case .picks: heading.subtitle = "Every picked photograph of every Archive"
            case .found: heading.title = "“\(foundQuery)”"; heading.subtitle = "Found in the catalog"
            default: heading.subtitle = "Every photograph of every Archive"
            }
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

    /// Forgets a Box with what's inside it, once asked. The photographs aren't touched. One undo step.
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
            undoable("Delete Box") { projects.deleteBox(id); return true }
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
            undoable("Delete Roll") { projects.deleteRoll(id, in: boxID); return true }
        }
    }

    /// Every Box and Roll, depth first, with the names they go by (“Spain › Madrid › Day 1”) and how deep they are.
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

    /// Add to Box's list: every Box and Roll as the sidebar nests them, the one open greyed (they're in it already).
    func addToBoxMenu(for frames: [URL]) -> NSMenu {
        let menu = NSMenu(title: "Add to Box")
        menu.appearance = NSAppearance(named: .darkAqua)
        let open = openHolder
        for choice in holderChoicesAll where !projects.isSmart(choice.holder) {
            let name = projects.shortName(choice.holder) ?? choice.name
            let item = ClosureMenuItem(name) { [weak self] in self?.add(frames, to: choice.holder) }
            item.indentationLevel = min(choice.depth, 15)
            item.image = NSImage(systemSymbolName: { if case .roll = choice.holder { "film" } else { "shippingbox" } }(), accessibilityDescription: nil)
            item.toolTip = choice.name
            if choice.holder == open { item.action = nil }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No Boxes Yet", action: nil, keyEquivalent: ""))
        }
        return menu
    }

    /// Add to Box, New Box from Selection and Remove from the Box or Roll open: the frames' menus in the contact sheet
    /// and in Develop (AppKit menus), as the Photo menu has them.
    func boxItems(for frames: [URL]) -> [NSMenuItem] {
        let several = frames.count > 1 ? " (\(frames.count) photos)" : ""
        let add = NSMenuItem(title: "Add to Box" + several, action: nil, keyEquivalent: "")
        add.submenu = addToBoxMenu(for: frames)
        var items = [add, ClosureMenuItem("New Box from Selection…") { [weak self] in self?.newBox(with: frames) }]
        if let open = openHolder, let name = projects.shortName(open) {
            items.append(ClosureMenuItem("Remove from “\(name)”" + several) { [weak self] in self?.removeFromOpenHolder(frames) })
        }
        return items
    }

    /// ⇧⌘B: Add to Box's list at the pointer, for the photographs selected.
    func chooseBox(in view: NSView?) {
        let frames = selectionTargets
        guard !frames.isEmpty, let view = view ?? NSApp.keyWindow?.contentView, let window = view.window else { return NSSound.beep() }
        let menu = addToBoxMenu(for: frames)
        let inside = window.mouseLocationOutsideOfEventStream
        let point = view.bounds.contains(view.convert(inside, from: nil)) ? view.convert(inside, from: nil) : CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// The same, for SwiftUI menus (the grid and the film strip).
struct BoxMenuItems: View {
    let lab: LabState
    let frames: [URL]

    var body: some View {
        let several = frames.count > 1 ? " (\(frames.count) photos)" : ""
        let choices = lab.holderChoicesAll.filter { !lab.projects.isSmart($0.holder) }
        let open = lab.openHolder
        Menu("Add to Box" + several) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                // Nested as in the sidebar: each level a step in.
                let indent = String(repeating: "\u{2003}", count: min(choice.depth, 15))
                Button {
                    lab.add(frames, to: choice.holder)
                } label: {
                    if case .roll = choice.holder { Label(indent + (lab.projects.shortName(choice.holder) ?? ""), systemImage: "film") }
                    else { Label(indent + (lab.projects.shortName(choice.holder) ?? ""), systemImage: "shippingbox") }
                }
                .disabled(choice.holder == open)
            }
            if choices.isEmpty { Text("No Boxes Yet") }
        }
        Button("New Box from Selection…") { lab.newBox(with: frames) }
        if let open, let name = lab.projects.shortName(open) {
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
        /// Qlick Lab: By Date (empty), a year or a month.
        case date(String)
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
