// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The sidebar's Archives: each one's Folders as the disk has them, every folder under them at any depth, with their
/// counts, following the disk. Read only: a click opens a folder on the contact sheet, nothing here changes the disk.
struct ArchivesSection: View {
    let model: EditorModel
    /// The folder whose card is being edited, and its Archive.
    @State private var editing: (archive: UUID, roll: LabRoll)?

    private var lab: LabState { model.lab }

    /// The Archives' list shown under their entry.
    @AppStorage("qlick.sidebar.archivesOpen") private var listOpen = true

    var body: some View {
        // Qlick Lab: an entry over the list; a click folds or unfolds it, + makes a new Archive.
        // The word opens the overview of everything the Archives hold; the chevron folds the list.
        SidebarEntry(symbol: LabGlyph.archive.symbol, title: "Archives", on: lab.workspace == .library && lab.overview == .archives,
                     unfolded: $listOpen, action: { lab.showOverview(.archives) }) {
            SidebarAddButton(help: "New Archive") { lab.newArchive() }
        }
        // A folder dropped here (from an Archive or the Finder) becomes an Archive of its own.
        .sidebarDrop(lab, .archives, depth: 0)
        .help("Every Archive, its folders and their photographs")
        if listOpen { list }
    }

    @ViewBuilder private var list: some View {
        let archives = lab.projects.projects
        if archives.isEmpty {
            SidebarHint("Drop a folder of photographs here to make an Archive.")
        }
        let view = lab.openView
        let current = lab.current
        ForEach(archives) { archive in
            let open = lab.sidebarFold.isOpen(.archive(archive.id), leadsToOpen: current?.project.id == archive.id)
            let roots = lab.projects.roots(of: archive)
            SidebarRow(symbol: LabGlyph.archive.symbol, name: archive.name, depth: 0, count: count(archive, roots: roots), on: view == .archive(archive.id),
                       strong: true, unfoldable: !roots.isEmpty, unfolded: open,
                       toggle: { lab.sidebarFold.toggle(.archive(archive.id), leadsToOpen: current?.project.id == archive.id) },
                       action: { lab.open(.archive(archive.id)); if !open { lab.sidebarFold.unfold(.archive(archive.id)) } })
                .sidebarDrop(lab, .archive(archive.id), depth: 0, folded: !open && !roots.isEmpty ? .archive(archive.id) : nil,
                             drags: .archive(archive.id), symbol: LabGlyph.archive.symbol, name: archive.name)
                .contextMenu {
                    Button("Show All Its Photographs") { lab.open(.archive(archive.id)) }
                    Button("Add a Folder…") { lab.importPanel(into: archive.id) }
                    Button("Rename…") { lab.naming = .init(kind: .renameArchive(archive.id), name: archive.name) }
                    Button("New Rolls by Day") { lab.newRollsByDay(for: .archive(archive.id)) }
                    let removed = lab.projects.removed(in: archive).count
                    if removed > 0 {
                        Divider()
                        Button("Restore Removed Photos (\(removed))") { lab.restoreRemoved(in: archive) }
                    }
                    Divider()
                    Button("Remove the Archive from the Catalog…") { lab.removeProject(archive) }
                }
            if open {
                ForEach(roots, id: \.self) { root in
                    if let tree = lab.projects.folders.trees[root.standardizedFileURL.path] {
                        rows(tree, depth: 1, archive: archive, current: current?.roll.folder)
                    } else {
                        let entry = lab.projects.folder(root.path, in: archive)
                        let missing = !FileManager.default.fileExists(atPath: root.path)
                        SidebarRow(symbol: missing ? "questionmark.folder" : "folder", name: entry.name, depth: 1,
                                   count: missing ? nil : lab.projects.stats[entry.id]?.total, on: current?.roll.folder == root.path,
                                   action: { lab.open(.folder(root.path, archive: archive.id)) })
                            .help(missing ? "Folder not found: its disk may not be connected" : root.path)
                            .sidebarDrop(lab, .folder(root.path, archive: archive.id), depth: 1, drags: .folder(root.path, archive: archive.id),
                                         symbol: "folder", name: entry.name)
                            .contextMenu { folderMenu(root.path, archive: archive) }
                            .popover(isPresented: card(root.path), arrowEdge: .trailing) { cardEditor() }
                    }
                }
            }
        }
    }

    /// The card's editor, beside the folder's row.
    private func card(_ path: String) -> Binding<Bool> {
        Binding(get: { editing?.roll.folder == path }, set: { if !$0 { editing = nil } })
    }

    @ViewBuilder private func cardEditor() -> some View {
        if let editing { RollEditor(lab: lab, project: editing.archive, roll: editing.roll) }
    }

    private func count(_ archive: LabProject, roots: [URL]) -> Int? {
        var total = 0
        for root in roots {
            if let tree = lab.projects.folders.trees[root.standardizedFileURL.path] { total += tree.total }
            else if let stats = lab.projects.stats[lab.projects.folder(root.path, in: archive).id] { total += stats.total }
            else { return nil }
        }
        return total
    }

    private func rows(_ node: FolderNode, depth: Int, archive: LabProject, current: String?) -> AnyView {
        let row = SidebarFold.Row.folder(node.id)
        let leads = current.map { $0.hasPrefix(node.id + "/") } ?? false
        let unfolded = lab.sidebarFold.isOpen(row, leadsToOpen: leads)
        let entry = lab.projects.folder(node.id, in: archive)
        return AnyView(Group {
            SidebarRow(symbol: "folder", name: entry.name, depth: depth, count: node.total > 0 ? node.total : nil, on: node.id == current,
                       dim: node.total == 0, unfoldable: !node.children.isEmpty, unfolded: unfolded,
                       toggle: { lab.sidebarFold.toggle(row, leadsToOpen: leads) },
                       action: {
                           if node.total > 0 { lab.open(.folder(node.id, archive: archive.id)) }
                           else if !node.children.isEmpty { lab.sidebarFold.toggle(row, leadsToOpen: leads) }
                       })
                .help(node.total == 0 ? "No photographs in this folder" : entry.name == node.name ? node.id : "\(node.id)\n(“\(entry.name)” in the lab)")
                .sidebarDrop(lab, .folder(node.id, archive: archive.id), depth: depth, folded: !unfolded && !node.children.isEmpty ? row : nil,
                             drags: .folder(node.id, archive: archive.id), symbol: "folder", name: entry.name)
                .contextMenu { folderMenu(node.id, archive: archive) }
                .popover(isPresented: card(node.id), arrowEdge: .trailing) { cardEditor() }
            if unfolded {
                ForEach(node.children) { child in rows(child, depth: depth + 1, archive: archive, current: current) }
            }
        })
    }

    @ViewBuilder private func folderMenu(_ path: String, archive: LabProject) -> some View {
        let entry = archive.rolls.first { $0.folder == path }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        Button("Open on the Contact Sheet") { lab.open(.folder(path, archive: archive.id)) }
        Button("Film, Camera and Notes…") {
            if let roll = lab.projects.folderEntry(path, in: archive.id) { editing = (archive.id, roll) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("New Rolls by Day") { lab.newRollsByDay(for: .folder(path, archive: archive.id)) }
        if let entry, lab.projects.roots(of: archive).contains(url) {
            RollMoveMenu(lab: lab, project: archive, roll: entry)
            Divider()
            Button("Remove the Folder from the Archive") { lab.projects.removeRoll(entry.id, from: archive.id) }
        }
    }
}

/// The sidebar's Boxes: photographs gathered from any Archive, in Boxes inside Boxes to any depth, and Rolls.
struct BoxesSection: View {
    let model: EditorModel
    /// In the Library, an entry over the list (as the Archives); in the Lab and Print, a small heading.
    var asEntry = true
    private var lab: LabState { model.lab }

    var body: some View {
        if asEntry {
            SidebarEntry(symbol: LabGlyph.box.symbol, title: "Boxes", on: lab.workspace == .library && lab.overview == .boxes,
                         unfolded: $listOpen, action: { lab.showOverview(.boxes) }) { addMenu }
                .sidebarDrop(lab, .boxes, depth: 0)
                .help("Every Box, with its Boxes and Rolls")
            if listOpen { list }
        } else {
            // Right under the hairline: no heading space on top of the hairline's own.
            SidebarSectionHeading("Boxes", first: true) { addMenu }
                .sidebarDrop(lab, .boxes, depth: 0)
            list
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Box…") { lab.newBox() }
            Button("New Smart Roll…") { lab.newSmartRoll() }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.dim)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        // As a plain button, so the + keeps the dim ink of the Archives' one.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("New Box or Smart Roll")
    }

    /// The Boxes' list shown under their entry.
    @AppStorage("qlick.sidebar.boxesOpen") private var listOpen = true

    @ViewBuilder private var list: some View {
        if lab.projects.boxes.isEmpty {
            SidebarHint("Gather photographs from any Archive: make a Box with +, then drag photographs onto it.")
        }
        ForEach(lab.projects.boxes) { box in rows(box, depth: 0, open: lab.openView) }
        // Qlick Lab: the place under the Boxes: photographs, a folder or a Roll dropped there make a new Box.
        Color.clear.frame(height: 64).contentShape(Rectangle())
            .sidebarDrop(lab, .boxes, depth: 0)
            .help("Drop photographs, a folder or a Roll here to make a new Box")
    }

    private func rows(_ box: LabBox, depth: Int, open view: LabView?) -> AnyView {
        let row = SidebarFold.Row.box(box.id)
        let leads: Bool = {
            switch view {
            case .box(let id): return id != box.id && box.all.contains { $0.id == id }
            case .roll(_, let id): return box.all.contains { $0.id == id }
            default: return false
            }
        }()
        let unfolded = lab.sidebarFold.isOpen(row, leadsToOpen: leads)
        let inside = !box.boxes.isEmpty || !box.rolls.isEmpty
        return AnyView(Group {
            SidebarRow(symbol: LabGlyph.box.symbol, name: box.name, depth: depth, count: lab.projects.frames(of: .box(box.id)).count, on: view == .box(box.id),
                       strong: depth == 0, unfoldable: inside, unfolded: unfolded,
                       toggle: { lab.sidebarFold.toggle(row, leadsToOpen: leads) },
                       action: { lab.open(.box(box.id)); if !unfolded && inside { lab.sidebarFold.unfold(row) } },
                       adding: {
                           Button("New Box Inside…") { lab.newBox(in: box.id) }
                           Button("New Roll…") { lab.newRoll(in: box.id) }
                           Button("New Smart Roll…") { lab.newSmartRoll(in: box.id) }
                       })
                .sidebarDrop(lab, .box(box.id), depth: depth, folded: !unfolded && inside ? row : nil, drags: .box(box.id),
                             symbol: LabGlyph.box.symbol, name: box.name)
                .contextMenu {
                    Button("Open on the Contact Sheet") { lab.open(.box(box.id)) }
                    PasteItem(lab: lab, holder: .box(box.id))
                    Divider()
                    Button("New Box Inside…") { lab.newBox(in: box.id) }
                    Button("New Roll…") { lab.newRoll(in: box.id) }
                    Button("New Smart Roll…") { lab.newSmartRoll(in: box.id) }
                    Button("New Rolls by Day") { lab.newRollsByDay(for: .box(box.id)) }
                    Button("Rename…") { lab.naming = .init(kind: .renameBox(box.id), name: box.name) }
                    Divider()
                    Button("Delete the Box…") { lab.deleteBox(box.id) }
                }
            if unfolded {
                ForEach(box.boxes) { inner in rows(inner, depth: depth + 1, open: view) }
                ForEach(box.rolls) { roll in
                    let symbol = (roll.isSmart ? LabGlyph.smartCanister : LabGlyph.canister).symbol
                    SidebarRow(symbol: symbol, name: roll.name, depth: depth + 1, count: lab.projects.frames(of: .roll(roll.id, box: box.id)).count,
                               on: view == .roll(roll.id, box: box.id),
                               action: { lab.open(.roll(roll.id, box: box.id)) })
                        .help(roll.isSmart ? "Smart Roll: the photographs that meet its rules, found again as they change" : "")
                        .sidebarDrop(lab, .roll(roll.id, box: box.id), depth: depth + 1, drags: .roll(roll.id, box: box.id),
                                     symbol: symbol, name: roll.name)
                        .contextMenu {
                            Button("Open on the Contact Sheet") { lab.open(.roll(roll.id, box: box.id)) }
                            if roll.isSmart {
                                Button("Edit Rules…") { lab.editSmartRoll(roll.id, in: box.id) }
                            } else {
                                PasteItem(lab: lab, holder: .roll(roll.id, box: box.id))
                            }
                            Button("Rename…") { lab.naming = .init(kind: .renameRoll(roll.id, box: box.id), name: roll.name) }
                            Divider()
                            Button(roll.isSmart ? "Delete the Smart Roll…" : "Delete the Roll…") { lab.deleteRoll(roll.id, in: box.id) }
                        }
                }
            }
        })
    }
}

/// Paste in a Box's or Roll's menu: the photographs copied (⌘C) are added to it.
private struct PasteItem: View {
    let lab: LabState
    let holder: Holder
    var body: some View {
        let count = lab.copiedPhotos.count
        Button(count > 1 ? "Paste \(count) Photographs" : "Paste the Photograph") { lab.pastePhotos(into: holder) }
            .disabled(count == 0)
    }
}

/// A section's heading in the sidebar, with its + button.
struct SidebarHeading: View {
    let title: String
    let help: String
    let add: () -> Void

    var body: some View {
        HStack {
            CapsLabel(title)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .padding(.leading, 10).padding(.trailing, 2)
        .padding(.top, 10).padding(.bottom, 4)
    }
}

/// A section's heading whose + opens a menu.
struct SidebarMenuHeading<Items: View>: View {
    let title: String
    let help: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        HStack {
            CapsLabel(title)
            Spacer()
            Menu { items() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 22, height: 22)
            .help(help)
        }
        .padding(.leading, 10).padding(.trailing, 2)
        .padding(.top, 10).padding(.bottom, 4)
    }
}

/// The sidebar's fixed entries, above the Archives: All Photographs, Last Import, Picks and By Date (years, months,
/// days). Each opens on the contact sheet; drawn from the catalogue's index.
struct FindingSection: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        let view = lab.openView
        let reading = lab.catalog.building && !lab.catalog.ready
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(symbol: LabGlyph.print.symbol, name: "All Photographs", depth: 0, count: lab.allCount, on: view == .all,
                       action: { lab.open(.all) })
                .help(reading ? "Reading the catalog's photographs…" : "Every photograph of every Archive")
            let imports = lab.lastImportCount
            SidebarRow(symbol: LabGlyph.cardIn.symbol, name: "Last Import", depth: 0, count: imports > 0 ? imports : nil, on: view == .lastImport,
                       dim: imports == 0, action: { lab.open(.lastImport) })
                .help(lab.lastImportDate.map { "Imported " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "The photographs of the last import")
            SidebarRow(symbol: LabGlyph.ring.symbol, name: "Picks", depth: 0, count: lab.picksCount, on: view == .picks,
                       action: { lab.open(.picks) })
                .help("Every picked photograph of every Archive")
            let tree = lab.dateTree
            let leads: Bool = { if case .day? = view { return true }; return false }()
            let open = lab.sidebarFold.isOpen(.date(""), leadsToOpen: leads)
            SidebarRow(symbol: LabGlyph.calendar.symbol, name: "By Date", depth: 0, on: false, unfoldable: !tree.years.isEmpty, unfolded: open,
                       toggle: { lab.sidebarFold.toggle(.date(""), leadsToOpen: leads) },
                       action: { lab.sidebarFold.toggle(.date(""), leadsToOpen: leads) })
                .help(tree.years.isEmpty ? "The days the photographs were taken, once they're read" : "The days the photographs were taken")
            if open {
                ForEach(tree.years) { year in dateRows(year, depth: 1, open: view) }
            }
        }
    }

    private func dateRows(_ node: DateTree.Node, depth: Int, open view: LabView?) -> AnyView {
        let row = SidebarFold.Row.date(node.key)
        let leads: Bool = { if case .day(let key)? = view { return key.hasPrefix(node.key + "-") }; return false }()
        let unfolded = lab.sidebarFold.isOpen(row, leadsToOpen: leads)
        return AnyView(Group {
            SidebarRow(symbol: "", name: node.title, depth: depth, count: node.count, on: view == .day(node.key),
                       unfoldable: !node.children.isEmpty, unfolded: unfolded,
                       toggle: { lab.sidebarFold.toggle(row, leadsToOpen: leads) },
                       action: { lab.open(.day(node.key)) })
            if unfolded {
                ForEach(node.children) { child in dateRows(child, depth: depth + 1, open: view) }
            }
        })
    }
}

/// A line of help where a section has nothing yet.
struct SidebarHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SidebarMetrics.textLeading).padding(.trailing, 8).padding(.top, 2).padding(.bottom, 4)
    }
}

/// One row of the sidebar's trees: an Archive, a folder, a Box, a Roll. What's open is marked by the pencil's red.
struct SidebarRow<Adding: View>: View {
    let symbol: String
    let name: String
    let depth: Int
    var count: Int? = nil
    var on = false
    /// A row on top: its name a little stronger.
    var strong = false
    /// No photographs in it: shown, but quieter.
    var dim = false
    var unfoldable = false
    var unfolded = false
    var dropping = false
    var toggle: () -> Void = {}
    let action: () -> Void
    /// What its + offers at the pointer, if anything.
    @ViewBuilder var adding: () -> Adding
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // The arrow only folds or unfolds: nothing opens.
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(unfolded ? 90 : 0))
                    .opacity(unfoldable ? 1 : 0)
                    .frame(width: 14, height: SidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!unfoldable)
            // Qlick Lab: a click by a tap, not a Button, so the row is also a real drag source (`sidebarDrop(drags:)`):
            // a Button keeps the mouse to itself and no drag ever starts.
            Group {
                // Qlick Lab: a list row of the sidebar (`SidebarMetrics`): 13 pt, a smaller icon, indented by the icon column.
                HStack(spacing: 6) {
                    LabSymbol(symbol: symbol, points: 9.5, color: SidebarMetrics.icon(selected: on, dim: dim)).frame(width: 14)
                    Text(name).font(SidebarMetrics.font(selected: on))
                        .foregroundStyle(SidebarMetrics.text(selected: on, dim: dim))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let count, !(hovered && Adding.self != EmptyView.self) {
                        Text("\(count)").font(Theme.value(11)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.trailing, 8)
                .frame(height: SidebarMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
            .overlay(alignment: .trailing) {
                if hovered && Adding.self != EmptyView.self {
                    Menu { adding() } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, 7)
                    .help("New Box or Roll inside")
                }
            }
        }
        // A deep tree stays readable in a narrow sidebar: each level steps in a little less than the one above.
        // The chevron in the entries' icon column, the icon and the word one column in.
        .padding(.leading, SidebarMetrics.inset + SidebarMetrics.iconColumn - 14 + SidebarRowIndent.of(depth))
        .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
            .fill(Color.white.opacity(dropping ? 0.12 : on ? SidebarMetrics.selectedFill : hovered ? SidebarMetrics.hoverFill : 0)))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension SidebarRow where Adding == EmptyView {
    init(symbol: String, name: String, depth: Int, count: Int? = nil, on: Bool = false, strong: Bool = false, dim: Bool = false,
         unfoldable: Bool = false, unfolded: Bool = false, dropping: Bool = false, toggle: @escaping () -> Void = {}, action: @escaping () -> Void) {
        self.init(symbol: symbol, name: name, depth: depth, count: count, on: on, strong: strong, dim: dim, unfoldable: unfoldable,
                  unfolded: unfolded, dropping: dropping, toggle: toggle, action: action, adding: { EmptyView() })
    }
}
