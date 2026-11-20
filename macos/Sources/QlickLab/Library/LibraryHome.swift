// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The library: every Archive and its folders on one page, then the Boxes, found again by name, film, camera, note or
/// file name. A folder is where it lies; nothing here copies, moves or changes a photograph.
struct LibraryHome: View {
    let model: EditorModel
    @State private var query = ""
    @State private var dropping = false
    @FocusState private var searching: Bool

    private var lab: LabState { model.lab }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    TextField("Search Archives, folders, Boxes, films, files…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).focused($searching)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).frame(width: 340, height: 28)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                Spacer()
                Button { lab.importPanel() } label: { Label("Import a Folder…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(QPillButtonStyle())
                Button { lab.newArchive() } label: { Label("New Archive", systemImage: "plus") }
                    .buttonStyle(QPrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

            let results = LibrarySearch.results(query, projects: lab.projects.projects, stats: lab.projects.stats, stocks: model.films,
                                                roots: { lab.projects.roots(of: $0) })
            let boxes = LibrarySearch.boxes(query, in: lab.holderChoicesAll)
            if lab.projects.projects.isEmpty && lab.projects.boxes.isEmpty {
                LibraryEmpty(model: model)
            } else if results.isEmpty && boxes.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing matches “\(query)”").font(Theme.title(16)).foregroundStyle(Theme.paper)
                    Text("Search looks at Archive, folder and Box names, the film, the camera, the notes,\nthe films frames were developed on, and file names.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        ForEach(results) { result in
                            ProjectSection(model: model, project: result.project, rolls: result.rolls, reasons: result.reasons, whole: query.isEmpty)
                        }
                        if !boxes.isEmpty { BoxesShelf(model: model, boxes: boxes) }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 26)
                }
            }
        }
        .background(Theme.bg)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2).padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in LabDrop.load(providers) { lab.importFolders($0) } }
        .environment(\.colorScheme, .dark)
    }
}

/// The library's search: every word must be found somewhere in the folder or its Archive.
enum LibrarySearch {
    struct Result: Identifiable {
        var project: LabProject
        var rolls: [LabRoll]
        /// Why a roll was found, when it isn't by its own name: a film of its developments, a file.
        var reasons: [UUID: String]
        var id: UUID { project.id }
    }

    /// Without words, each Archive with its Folders on top (`roots`); with words, every folder of the catalogue that
    /// matches, a folder under another included.
    static func results(_ query: String, projects: [LabProject], stats: [UUID: RollStats], stocks: [Stock],
                        roots: (LabProject) -> [URL] = { $0.rolls.map(\.url) }) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return projects.filter { !$0.archived }.map { project in
                let top = Set(roots(project).map(\.path))
                return Result(project: project, rolls: project.rolls.filter { top.contains($0.folder) }, reasons: [:])
            }
        }
        let stockNames = Dictionary(stocks.map { ($0.id, $0.name) }) { first, _ in first }
        var results: [Result] = []
        for project in projects {
            var rolls: [LabRoll] = [], reasons: [UUID: String] = [:]
            for roll in project.rolls {
                let stat = stats[roll.id]
                let films = (stat?.films ?? [:]).map { (name: stockNames[$0.key] ?? $0.key, count: $0.value) }
                let own = [project.name, project.notes, roll.name, roll.film, roll.camera, roll.notes].joined(separator: " ")
                var reason: String?
                let found = words.allSatisfy { word in
                    if own.localizedStandardContains(word) { return true }
                    if let film = films.first(where: { $0.name.localizedStandardContains(word) }) {
                        reason = "\(film.count) frame\(film.count > 1 ? "s" : "") developed on \(film.name)"
                        return true
                    }
                    if let name = stat?.names.first(where: { $0.localizedStandardContains(word) }) {
                        reason = name
                        return true
                    }
                    return false
                }
                if found { rolls.append(roll); if let reason { reasons[roll.id] = reason } }
            }
            if !rolls.isEmpty { results.append(Result(project: project, rolls: rolls, reasons: reasons)) }
        }
        return results
    }

    /// The Boxes and Rolls whose names (or their Boxes') hold every word; every Box on top without words.
    static func boxes(_ query: String, in choices: [(holder: Holder, name: String, depth: Int)]) -> [(holder: Holder, name: String, depth: Int)] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices.filter { $0.depth == 0 } }
        return choices.filter { choice in words.allSatisfy { choice.name.localizedStandardContains($0) } }
    }
}

private struct ProjectSection: View {
    let model: EditorModel
    let project: LabProject
    let rolls: [LabRoll]
    let reasons: [UUID: String]
    /// Every Folder shown (no search): the card that adds one follows them.
    var whole = true
    @State private var renaming = false
    @State private var name = ""
    @State private var notes = ""
    @State private var editingNotes = false

    private var lab: LabState { model.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if renaming {
                    TextField("Archive name", text: $name)
                        .textFieldStyle(.plain).font(Theme.title(20)).frame(maxWidth: 380)
                        .onSubmit { lab.projects.update(project.id) { $0.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? $0.name : name }; renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    Text(project.name).font(Theme.title(20)).foregroundStyle(Theme.paper)
                        .onTapGesture(count: 2) { name = project.name; renaming = true }
                        .help("Double-click to rename")
                }
                Text(Self.summary(project, roots: rolls, stats: lab.projects.stats)).font(Theme.value(11.5)).foregroundStyle(Theme.dim)
                Spacer()
                Menu {
                    Button("Show All Its Photographs") { lab.open(.archive(project.id)) }
                    Button("Add a Folder…") { lab.importPanel(into: project.id) }
                    Button("Rename") { name = project.name; renaming = true }
                    Button(project.notes.isEmpty ? "Add a Note" : "Edit the Note") { notes = project.notes; editingNotes = true }
                    Divider()
                    Button("Remove the Archive from the Catalog…") { lab.removeProject(project) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if editingNotes {
                TextField("Archive note", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.8)).lineLimit(1...5)
                    .padding(9).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))).frame(maxWidth: 560)
                    .onSubmit { lab.projects.update(project.id) { $0.notes = notes }; editingNotes = false }
                    .onExitCommand { editingNotes = false }
            } else if !project.notes.isEmpty {
                Text(project.notes).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62)).frame(maxWidth: 620, alignment: .leading)
                    .onTapGesture(count: 2) { notes = project.notes; editingNotes = true }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 264, maximum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(rolls) { roll in
                    RollCard(model: model, project: project, roll: roll, reason: reasons[roll.id])
                }
                if whole {
                    Button { lab.importPanel(into: project.id) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .light))
                            Text("Add a folder").font(.system(size: 11.5))
                        }
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity).frame(height: 96)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func summary(_ project: LabProject, roots: [LabRoll], stats: [UUID: RollStats]) -> String {
        let all = roots.compactMap { stats[$0.id] }
        let total = all.reduce(0) { $0 + $1.total }, picks = all.reduce(0) { $0 + $1.picks }
        var parts = ["\(roots.count) folder\(roots.count == 1 ? "" : "s")"]
        if total > 0 { parts.append(total == 1 ? "1 frame" : "\(total) frames") }
        if picks > 0 { parts.append("\(picks) picked") }
        return parts.joined(separator: " · ")
    }
}

/// The Boxes on the library's page: each a chip that opens it, with its count.
private struct BoxesShelf: View {
    let model: EditorModel
    let boxes: [(holder: Holder, name: String, depth: Int)]
    private var lab: LabState { model.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Boxes").font(Theme.title(20)).foregroundStyle(Theme.paper)
                Text("Photographs gathered from any Archive").font(Theme.value(11.5)).foregroundStyle(Theme.dim)
                Spacer()
                Button { lab.newBox() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 28, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("New Box")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, choice in BoxChip(lab: lab, holder: choice.holder, name: choice.name) }
            }
        }
    }
}

private struct BoxChip: View {
    let lab: LabState
    let holder: Holder
    let name: String
    @State private var hovered = false

    var body: some View {
        let view: LabView = switch holder { case .box(let id): .box(id); case .roll(let id, let box): .roll(id, box: box) }
        Button { lab.open(view) } label: {
            HStack(spacing: 8) {
                Image(systemName: { if case .box = holder { return "shippingbox" } else { return "film" } }()).font(.system(size: 12)).foregroundStyle(Theme.dim)
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(lab.projects.frames(of: holder).count)").font(Theme.value(11.5)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A folder as a short strip of its first frames, with its counts (the folders under it included).
private struct RollCard: View {
    let model: EditorModel
    let project: LabProject
    let roll: LabRoll
    let reason: String?
    @State private var hovered = false
    @State private var editing = false

    private var lab: LabState { model.lab }

    var body: some View {
        let stats = lab.projects.stats[roll.id]
        let open = lab.current?.roll.folder == roll.folder
        VStack(alignment: .leading, spacing: 8) {
            RollStrip(folder: roll.url, names: Array((stats?.names ?? []).prefix(6)))
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(hovered ? 0.28 : 0.08), lineWidth: 1))
                .opacity(stats?.missing == true ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if open { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                    Text(roll.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { editing = true } label: { Image(systemName: "pencil").font(.system(size: 10.5)).foregroundStyle(Theme.dim).frame(width: 20, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).opacity(hovered || editing ? 1 : 0)
                        .help("The folder's film, camera and notes")
                        .popover(isPresented: $editing, arrowEdge: .bottom) { RollEditor(lab: lab, project: project.id, roll: roll) }
                }
                if !roll.film.isEmpty || !roll.camera.isEmpty {
                    Text([roll.film, roll.camera].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.68)).lineLimit(1)
                }
                if let stats {
                    if stats.missing {
                        Text("Folder not found").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                    } else {
                        HStack(spacing: 9) {
                            Text(stats.total == 1 ? "1 frame" : "\(stats.total) frames").font(Theme.value(11.5)).foregroundStyle(Theme.dim)
                            if stats.picks > 0 { count(.pick, stats.picks) }
                            if stats.rejects > 0 { count(.reject, stats.rejects) }
                            if stats.edited > 0 { Text("\(stats.edited) developed").font(Theme.value(11.5)).foregroundStyle(Theme.dim) }
                        }
                    }
                }
                if let reason { Text(reason).font(.system(size: 11)).foregroundStyle(Theme.paper.opacity(0.8)).lineLimit(1) }
                if !roll.notes.isEmpty { Text(roll.notes).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(2) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { lab.open(.folder(roll.folder, archive: project.id)) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open the Contact Sheet") { lab.open(.folder(roll.folder, archive: project.id)) }
            Button("Film, Camera and Notes…") { editing = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([roll.url]) }
            RollMoveMenu(lab: lab, project: project, roll: roll)
            Divider()
            Button("Remove the Folder from the Archive") { lab.projects.removeRoll(roll.id, from: project.id) }
        }
        .help(roll.folder)
    }

    private func count(_ flag: PhotoSidecar.Flag, _ value: Int) -> some View {
        HStack(spacing: 3) {
            MarkGlyph(flag: flag).frame(width: 13, height: 10)
            Text("\(value)").font(Theme.value(11.5)).foregroundStyle(Color(white: 0.75))
        }
    }
}

/// A folder's first frames on a piece of film.
private struct RollStrip: View {
    let folder: URL
    let names: [String]
    @State private var images: [String: CGImage] = [:]

    var body: some View {
        GeometryReader { geometry in
            let perforation: CGFloat = 7
            let height = geometry.size.height - 2 * perforation
            let width = height * 1.5, gap: CGFloat = 4
            let count = max(Int(((geometry.size.width - gap) / (width + gap)).rounded(.up)), 1)
            ZStack(alignment: .topLeading) {
                Color.black
                Canvas { context, size in
                    // Perforations along both edges.
                    var x: CGFloat = 4
                    while x + 5 < size.width {
                        for y in [1.5, size.height - perforation + 1.5] {
                            context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 5, height: 4), cornerRadius: 1), with: .color(Color(white: 0.16)))
                        }
                        x += 8.6
                    }
                }
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        ZStack {
                            Color(white: 0.07)
                            if names.indices.contains(index), let image = images[names[index]] {
                                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: width, height: height).clipped()
                    }
                }
                .padding(.leading, gap).padding(.top, perforation)
            }
            .clipped()
        }
        .task(id: names) {
            for name in names where images[name] == nil {
                let file = PhotoFile(url: folder.appendingPathComponent(name))
                let image = await PhotoThumbnails.shared.image(for: file, size: .medium)
                guard !Task.isCancelled else { return }
                if let image { images[name] = image }
            }
        }
    }
}

/// A folder's card: its name in the lab, the film, camera and notes, edited in place (the library's cards and the
/// sidebar).
struct RollEditor: View {
    let lab: LabState
    let project: UUID
    @State var roll: LabRoll

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Folder")
            field("Name", $roll.name)
            field("Film loaded", $roll.film, prompt: "Portra 400, pushed +1…")
            field("Camera", $roll.camera, prompt: "Leica M6, 35 mm")
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.system(size: 11)).foregroundStyle(Theme.dim)
                TextField("Place, light, development…", text: $roll.notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            }
            Text("The film is printed along the edge of the contact sheet's strips.\nKept in a small card (Roll.qlickroll) in the folder, so it goes wherever the folder goes. The name is the lab's: the folder keeps its own on the disk, and the photographs aren't changed.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .onChange(of: roll) { _, roll in
            lab.projects.updateRoll(roll.id, in: project) { stored in
                stored.name = roll.name.trimmingCharacters(in: .whitespaces).isEmpty ? stored.name : roll.name
                stored.film = roll.film; stored.camera = roll.camera; stored.notes = roll.notes
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.dim)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

private struct LibraryEmpty: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 16) {
            QMark(size: 54)
            Text("Your lab is empty").font(Theme.title(19)).foregroundStyle(Theme.paper)
            Text("Drop a folder of photographs here: it becomes the first folder of an Archive.\nNothing is copied; your files stay where they are and are never changed.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            Button("Import a Folder…") { model.lab.importPanel() }.buttonStyle(QPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Moves a Folder to another Archive, with its card (nothing moves on disk): the library's cards and the sidebar.
struct RollMoveMenu: View {
    let lab: LabState
    let project: LabProject
    let roll: LabRoll

    var body: some View {
        let others = lab.projects.ordinary.filter { $0.id != project.id }
        Menu("Move to Archive") {
            ForEach(others) { other in
                Button(other.name) { lab.projects.moveRoll(roll.id, from: project.id, to: other.id) }
            }
        }
        .disabled(others.isEmpty)
    }
}
