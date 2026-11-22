// Qlick Lab — GPL-3.0-only.
import SwiftUI
import UniformTypeIdentifiers

/// The lab's navigation: the rooms of the part chosen (Library, Lab or Print), then the Archives and their folders,
/// then the Boxes. It sits in the window's sidebar, which macOS 26 draws as a floating pane of Liquid Glass.
struct LabSidebar: View {
    let model: EditorModel
    @State private var dropping = false
    @AppStorage("qlick.sidebar.libraryOpen") private var libraryOpen = true
    @AppStorage(Theme.solidKey) private var solid = false

    private var lab: LabState { model.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Level with the traffic lights; the title bar takes the clicks here.
            HStack(spacing: 9) {
                QMark(size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    // The app's name: the one bold word of the sidebar.
                    Text("Qlick Lab").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper)
                    CatalogMenu(lab: lab)
                }
                Spacer()
            }
            .padding(.leading, 20)
            .frame(height: 40)

            // One drop target for the whole list (`SidebarDropDelegate`): photographs on a Box or a Roll, rows among
            // rows, a folder on a Box, folders from the Finder; the label over the list says what a drop does.
            // Qlick Lab: the part's own section first (its heading, then its entries), then the places: in the
            // Library its Archives and Boxes; in the Lab and in Print the Boxes alone, the film strip being enough
            // there and sorting the Library's.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    // Qlick Lab: the active part only (the selector is the main way round), under its small heading;
                    // one set of measures for every part (`SidebarMetrics`). The Library lists Import, the Contact
                    // Sheet with its list, then the Archives and the Boxes with theirs; the Lab and Print their rooms.
                    SidebarSectionHeading(lab.part.title, first: true)
                    ForEach(lab.part.rooms) { room in
                        SidebarEntry(symbol: room.symbol, title: room == .print ? "Export" : room.title, on: lab.workspace.listed(as: room) && !(lab.part == .library && room == .contactSheet && lab.litView != nil),
                                     trailing: room == .importer ? lab.importer.cards.first?.name : nil) { lab.show(room) }
                            .help(room == .print ? "Print: the photograph as printed, and its export" : "\(room.title) (⌥⌘\(room.key))")
                    }
                    // Archives, Boxes and Rolls are chosen in the Library only (Quentin, 2026-11-21): the Lab and
                    // Print work on what's chosen there, the film strip being the one thing the parts share.
                    if lab.part == .library {
                        // The Library: every photograph, and the lists that sort them (Last Import, Picks, By Date).
                        SidebarEntry(symbol: LabGlyph.prints.symbol, title: "Library", on: lab.litView == .all && !libraryOpen,
                                     unfolded: $libraryOpen, action: { lab.open(.all) })
                            .help("All the photographs of the catalogue, on the contact sheet")
                        if libraryOpen { FindingSection(model: model) }
                        SidebarHairline()
                        ArchivesSection(model: model)
                        // Archives (folders on the disk) and Boxes (gatherings of the catalogue) apart.
                        SidebarHairline()
                        BoxesSection(model: model, asEntry: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .background(SidebarScrollProbe(drop: lab.sidebarDrop))
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: SidebarDropModel.space)
            .onPreferenceChange(SidebarDropRowsKey.self) { rows in
                MainActor.assumeIsolated { lab.sidebarDrop.rows = rows }
            }
            .onDrop(of: [LabDragItem.type, .fileURL], delegate: SidebarDropDelegate(lab: lab))
            .overlay { SidebarDropOverlay(drop: lab.sidebarDrop) }

            Spacer(minLength: 0)
            ImportSidebarProgress(model: model)
            SidebarWork(model: model)
            SidebarHairline().padding(.horizontal, 10)
            SidebarEntry(symbol: "gearshape", title: "Settings") { lab.openSettings() }
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Settings › Photographs › Interface › "Solid surfaces": the sidebar on the lab's black, without the glass.
        .background { if solid { Theme.film.ignoresSafeArea() } }
        // With "Solid surfaces", a hairline between the sidebar and the work, as the panels have.
        .overlay(alignment: .trailing) {
            if solid { Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1).ignoresSafeArea().allowsHitTesting(false) }
        }
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
                // Qlick Lab: as the places' rows (`SidebarRow`), one size for the whole sidebar.
                LabSymbol(symbol: symbol, points: 11, color: on ? Theme.accent : Theme.dim).frame(width: 16)
                Text(title).font(.system(size: 12.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.paper : Color(white: 0.82)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(Theme.value(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail).layoutPriority(-1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.08 : hovered ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
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

/// Asks a name: a new Archive, Box or Roll, or a new name for one.
struct NamingSheet: View {
    let lab: LabState
    @State var naming: LabState.Naming
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.title(17)).foregroundStyle(Theme.paper)
            if let explanation {
                Text(explanation).font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: $naming.name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(finish)
            HStack {
                Spacer()
                Button("Cancel") { lab.naming = nil }.buttonStyle(QPillButtonStyle()).keyboardShortcut(.cancelAction)
                Button(renaming ? "Rename" : "Create", action: finish).buttonStyle(QPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(naming.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    private var renaming: Bool {
        switch naming.kind {
        case .renameArchive, .renameBox, .renameRoll: true
        default: false
        }
    }

    private var title: String {
        switch naming.kind {
        case .archive: "New Archive"
        case .box(let parent): parent.flatMap { lab.projects.box($0) }.map { "New Box in “\($0.name)”" } ?? "New Box"
        case .roll(let box): lab.projects.box(box).map { "New Roll in “\($0.name)”" } ?? "New Roll"
        case .renameArchive: "Rename the Archive"
        case .renameBox: "Rename the Box"
        case .renameRoll: "Rename the Roll"
        }
    }

    private var placeholder: String {
        switch naming.kind {
        case .archive, .renameArchive: "Archive name"
        case .box, .renameBox: "Box name"
        case .roll, .renameRoll: "Roll name"
        }
    }

    private var explanation: String? {
        let photos = naming.frames.count == 1 ? "The photograph chosen goes in it. " : naming.frames.isEmpty ? "" : "The \(naming.frames.count) photographs chosen go in it. "
        switch naming.kind {
        case .archive:
            return naming.folders.isEmpty ? "An Archive holds the folders of one subject, shown as they are on the disk."
                : "The folders chosen become this Archive's folders. Nothing is copied or moved."
        case .box:
            return photos + "A Box gathers photographs from any Archive, in Rolls and in Boxes inside it. The photographs stay where they are."
        case .roll:
            return photos + "A Roll holds photographs from any Archive. The photographs stay where they are."
        case .renameArchive, .renameBox, .renameRoll: return nil
        }
    }

    private func finish() {
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
                Button(CatalogList.name(of: url) + (url.labStandardized == lab.projects.directory.labStandardized ? "  ✓" : "")) { lab.openCatalog(url) }
            }
        } label: {
            Text(lab.catalogName + "  ⌄").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("The open catalog: a set of Archives and Boxes of its own, kept in a file you can copy, move or keep apart")
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
