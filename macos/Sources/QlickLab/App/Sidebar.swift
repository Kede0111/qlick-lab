// Qlick Lab — GPL-3.0-only.
import SwiftUI
import UniformTypeIdentifiers

/// The lab's navigation: its rooms, then the projects and their rolls. It sits in the window's sidebar, which
/// macOS 26 draws as a floating pane of Liquid Glass.
struct LabSidebar: View {
    let model: EditorModel
    @State private var expanded: Set<UUID> = []
    /// Folded by hand: stays folded even while one of its rolls is open.
    @State private var folded: Set<UUID> = []
    @State private var dropping = false

    private var lab: LabState { model.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Level with the traffic lights; the title bar takes the clicks here.
            HStack(spacing: 9) {
                QMark(size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Qlick Lab").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.paper)
                    CatalogMenu(lab: lab)
                }
                Spacer()
            }
            .padding(.leading, 20)
            .frame(height: 40)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Workspace.ordered) { room in
                    // A card that's in says so beside Import.
                    RoomRow(room: room, on: lab.workspace.listed(as: room), trailing: room == .importer ? lab.importer.cards.first?.name : nil) { lab.show(room) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if let arrivals = lab.projects.arrivals, !arrivals.rolls.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    let current = lab.current
                    let open = expanded.contains(arrivals.id) || (current?.project.id == arrivals.id && !folded.contains(arrivals.id))
                    ProjectRows(model: model, project: arrivals, currentRoll: current?.roll.id, open: open) {
                        if open { expanded.remove(arrivals.id); folded.insert(arrivals.id) }
                        else { expanded.insert(arrivals.id); folded.remove(arrivals.id) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
            }

            HStack {
                CapsLabel("Projects")
                Spacer()
                Button { lab.naming = LabState.ProjectNaming(name: lab.projects.uniqueName("New Project")) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New project")
            }
            .padding(.leading, 20).padding(.trailing, 12)
            .padding(.top, 22).padding(.bottom, 6)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    let current = lab.current
                    ForEach(lab.projects.ordinary) { project in
                        // The project being worked on unfolds by itself, unless it was folded by hand.
                        let open = expanded.contains(project.id) || (current?.project.id == project.id && !folded.contains(project.id))
                        ProjectRows(model: model, project: project, currentRoll: current?.roll.id, open: open) {
                            if open { expanded.remove(project.id); folded.insert(project.id) }
                            else { expanded.insert(project.id); folded.remove(project.id) }
                        }
                    }
                    if lab.projects.ordinary.isEmpty && lab.projects.arrivals == nil {
                        Text("Drop a folder of photographs here to make a project.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            ImportSidebarProgress(model: model)
            SidebarWork(model: model)
            Divider().overlay(Color.white.opacity(0.06))
            RoomButton(symbol: "gearshape", title: "Settings", on: false) {
                lab.openSettings()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2).padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in LabDrop.load(providers) { lab.importFolders($0) } }
        .environment(\.colorScheme, .dark)
    }
}

private struct RoomRow: View {
    let room: Workspace
    let on: Bool
    var trailing: String? = nil
    let action: () -> Void
    var body: some View {
        RoomButton(symbol: room.symbol, title: room.title, on: on, trailing: trailing, action: action)
            .help("\(room.title) (⌥⌘\(room.key))")
    }
}

/// A row of the sidebar. The open room is marked by the pencil's red and a faint fill.
struct RoomButton: View {
    let symbol: String
    let title: String
    let on: Bool
    var trailing: String? = nil
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13, weight: .regular)).frame(width: 20)
                    .foregroundStyle(on ? Theme.accent : Color(white: 0.72))
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.paper : Color(white: 0.82)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(Theme.value(11)).foregroundStyle(Theme.dim) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(on ? 0.1 : hovered ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct ProjectRows: View {
    let model: EditorModel
    let project: LabProject
    let currentRoll: UUID?
    let open: Bool
    let toggle: () -> Void
    @State private var hovered = false
    @State private var dropping = false

    private var lab: LabState { model.lab }

    var body: some View {
        let shown = lab.wholeProject?.id == project.id
        HStack(spacing: 0) {
            // The arrow only folds or unfolds the project's rolls: nothing opens.
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 26, height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the rolls" : "Show the rolls")
            Button { lab.openWhole(project); if !open { toggle() } } label: {
                HStack(spacing: 6) {
                    Text(project.name).font(.system(size: 12.5, weight: shown ? .semibold : .medium)).foregroundStyle(shown ? Theme.paper : Color(white: 0.86)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(project.rolls.count)").font(Theme.value(11, weight: project.isArrivals ? .semibold : .regular))
                        .foregroundStyle(project.isArrivals ? Theme.accent : Theme.faint)
                }
                .padding(.trailing, 8)
                .frame(height: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(dropping ? 0.12 : shown ? 0.08 : hovered ? 0.05 : 0)))
        .onHover { hovered = $0 }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            LabDrop.load(providers) { project.isArrivals ? lab.importFolders($0) : lab.importFolders($0, into: project.id) }
        }
        .help(project.isArrivals ? "Rolls imported without a project. Move each one to a project from its menu." : "")
        .contextMenu {
            Button("Show All Its Photographs") { lab.openWhole(project) }
            if !project.isArrivals {
                Button("Add a Folder…") { lab.importPanel(into: project.id) }
                Divider()
                Button("Remove the Project from the Catalog…") { lab.removeProject(project) }
            }
        }
        if open {
            ForEach(project.rolls) { roll in
                SidebarRoll(model: model, project: project, roll: roll, on: roll.id == currentRoll)
            }
        }
    }
}

/// A roll in the sidebar, with what can be done to it from there: its card, moving it, removing it.
private struct SidebarRoll: View {
    let model: EditorModel
    let project: LabProject
    let roll: LabRoll
    let on: Bool
    @State private var editing = false

    private var lab: LabState { model.lab }

    var body: some View {
        RollRow(roll: roll, stats: lab.projects.stats[roll.id], on: on) { lab.open(roll, in: project) }
            .popover(isPresented: $editing, arrowEdge: .trailing) { RollEditor(lab: lab, project: project.id, roll: roll) }
            .contextMenu {
                Button("Rename, Film, Camera and Notes…") { editing = true }
                RollMoveMenu(lab: lab, project: project, roll: roll)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([roll.url]) }
                Divider()
                Button("Remove the Roll from the Project") { lab.projects.removeRoll(roll.id, from: project.id) }
            }
    }
}

private struct RollRow: View {
    let roll: LabRoll
    let stats: RollStats?
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(on ? Theme.accent : Color.clear).frame(width: 5, height: 5).frame(width: 12)
                Text(roll.name).font(.system(size: 12.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.paper : Color(white: 0.72)).lineLimit(1)
                Spacer(minLength: 4)
                if let stats, !stats.missing { Text("\(stats.total)").font(Theme.value(11)).foregroundStyle(Theme.faint) }
                if stats?.missing == true { Image(systemName: "questionmark.folder").font(.system(size: 10)).foregroundStyle(Theme.dim).help("Folder not found") }
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 25)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.08 : hovered ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Folders and files dropped from the Finder.
enum LabDrop {
    static func load(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let group = DispatchGroup()
        let found = Found()
        for provider in files {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.add(url) }
                group.leave()
            }
        }
        // Called on the main queue only, where `then` runs.
        nonisolated(unsafe) let then = then
        group.notify(queue: .main) { MainActor.assumeIsolated { then(found.urls) } }
        return true
    }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        func add(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
    }
}

/// Asks a new project's name.
struct ProjectNamingSheet: View {
    let lab: LabState
    @State var naming: LabState.ProjectNaming
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(Theme.title(17)).foregroundStyle(Theme.paper)
            Text(naming.folders.isEmpty ? "A project gathers rolls or sessions: folders of photographs, where they are."
                 : "The folders chosen become this project's rolls. Nothing is copied or moved.")
                .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $naming.name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { lab.naming = nil }.buttonStyle(QPillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create", action: create).buttonStyle(QPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(naming.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    private func create() {
        guard !naming.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lab.finishNaming(naming)
    }
}

/// The open catalog's name, which opens the catalogs' commands.
private struct CatalogMenu: View {
    let lab: LabState
    var body: some View {
        Menu {
            Button("New Catalog…") { lab.newCatalogPanel() }
            Button("Open Catalog…") { lab.openCatalogPanel() }
            Button("Save Catalog As…") { lab.saveCatalogAsPanel() }
            Divider()
            ForEach([CatalogList.defaultDirectory] + lab.catalogs.recent, id: \.self) { url in
                Button(CatalogList.name(of: url) + (url.standardizedFileURL == lab.projects.directory.standardizedFileURL ? "  ✓" : "")) { lab.openCatalog(url) }
            }
        } label: {
            Text(lab.catalogName + "  ⌄").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("The open catalog: a set of projects of its own, kept in a file you can copy, move or archive")
    }
}

/// Qlick Lab: what the lab does in the background, each with its progress and its Stop (`BackgroundWork`); the
/// import has its own, larger, above.
private struct SidebarWork: View {
    let model: EditorModel
    var body: some View {
        ForEach(BackgroundWork.tasks(model).filter { $0.kind != .importing }) { task in BackgroundTaskRow(task: task) }
    }
}
