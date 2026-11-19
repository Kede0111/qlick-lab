// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The library: every project and its rolls on one page, found again by name, film, camera, note or file name.
/// A roll is a folder where it lies; nothing here copies, moves or changes a photograph.
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
                    TextField("Search projects, rolls, films, files…", text: $query)
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
                Button { lab.naming = LabState.ProjectNaming(name: lab.projects.uniqueName("New Project")) } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(QPrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

            let results = LibrarySearch.results(query, projects: lab.projects.projects.filter { !$0.isSelection && (!$0.isArrivals || !$0.rolls.isEmpty) }, stats: lab.projects.stats, stocks: model.films)
            if lab.projects.ordinary.isEmpty && lab.projects.arrivals == nil {
                LibraryEmpty(model: model)
            } else if results.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing matches “\(query)”").font(Theme.title(16)).foregroundStyle(Theme.paper)
                    Text("Search looks at project and roll names, the film, the camera, the notes,\nthe films frames were developed on, and file names.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        ForEach(results) { result in
                            ProjectSection(model: model, project: result.project, rolls: result.rolls, reasons: result.reasons)
                        }
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

/// The library's search: every word must be found somewhere in the roll or its project.
enum LibrarySearch {
    struct Result: Identifiable {
        var project: LabProject
        var rolls: [LabRoll]
        /// Why a roll was found, when it isn't by its own name: a film of its developments, a file.
        var reasons: [UUID: String]
        var id: UUID { project.id }
    }

    static func results(_ query: String, projects: [LabProject], stats: [UUID: RollStats], stocks: [Stock]) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return projects.filter { !$0.archived }.map { Result(project: $0, rolls: $0.rolls, reasons: [:]) } }
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
}

private struct ProjectSection: View {
    let model: EditorModel
    let project: LabProject
    let rolls: [LabRoll]
    let reasons: [UUID: String]
    @State private var renaming = false
    @State private var name = ""
    @State private var notes = ""
    @State private var editingNotes = false

    private var lab: LabState { model.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if renaming {
                    TextField("Project name", text: $name)
                        .textFieldStyle(.plain).font(Theme.title(20)).frame(maxWidth: 380)
                        .onSubmit { lab.projects.update(project.id) { $0.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? $0.name : name }; renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    Text(project.name).font(Theme.title(20)).foregroundStyle(Theme.paper)
                        .onTapGesture(count: 2) { if !project.isArrivals { name = project.name; renaming = true } }
                        .help(project.isArrivals ? "Rolls imported without a project wait here. Move each one to a project from its menu."
                              : "Double-click to rename")
                }
                Text(Self.summary(project, stats: lab.projects.stats)).font(Theme.value(11.5)).foregroundStyle(Theme.dim)
                Spacer()
                Menu {
                    if !project.isArrivals {
                        Button("Add a Folder…") { lab.importPanel(into: project.id) }
                        Button("Rename") { name = project.name; renaming = true }
                    }
                    Button(project.notes.isEmpty ? "Add a Note" : "Edit the Note") { notes = project.notes; editingNotes = true }
                    Divider()
                    Button("Remove the Project from the Catalog…") { lab.removeProject(project) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if editingNotes {
                TextField("Project note", text: $notes, axis: .vertical)
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
                if rolls.count == project.rolls.count, !project.isArrivals {
                    Button { lab.importPanel(into: project.id) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .light))
                            Text("Add a roll").font(.system(size: 11.5))
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

    static func summary(_ project: LabProject, stats: [UUID: RollStats]) -> String {
        let all = project.rolls.compactMap { stats[$0.id] }
        let total = all.reduce(0) { $0 + $1.total }, picks = all.reduce(0) { $0 + $1.picks }
        var parts = ["\(project.rolls.count) roll\(project.rolls.count > 1 ? "s" : "")"]
        if total > 0 { parts.append("\(total) frames") }
        if picks > 0 { parts.append("\(picks) picked") }
        return parts.joined(separator: " · ")
    }
}

/// A roll as a short strip of its first frames, with its counts.
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
        let open = lab.current?.roll.id == roll.id
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
                        .help("The roll's film, camera and notes")
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
                            Text("\(stats.total) frames").font(Theme.value(11.5)).foregroundStyle(Theme.dim)
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
        .onTapGesture { lab.open(roll, in: project) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open the Contact Sheet") { lab.open(roll, in: project) }
            Button("Film, Camera and Notes…") { editing = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([roll.url]) }
            RollMoveMenu(lab: lab, project: project, roll: roll)
            Divider()
            Button("Remove the Roll from the Project") { lab.projects.removeRoll(roll.id, from: project.id) }
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

/// A roll's first frames on a piece of film.
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

/// A roll's name, film, camera and notes, edited in place (the library's roll cards and the sidebar).
struct RollEditor: View {
    let lab: LabState
    let project: UUID
    @State var roll: LabRoll

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Roll")
            field("Name", $roll.name)
            field("Film loaded", $roll.film, prompt: "Portra 400, pushed +1…")
            field("Camera", $roll.camera, prompt: "Leica M6, 35 mm")
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.system(size: 11)).foregroundStyle(Theme.dim)
                TextField("Place, light, development…", text: $roll.notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            }
            Text("The film is printed along the edge of the contact sheet's strips.\nKept in a small Roll.qlickroll card in the roll's folder, so it goes wherever the folder goes. The photographs aren't changed.")
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
            Text("Drop a folder of photographs here: it becomes the first roll of a project.\nNothing is copied; your files stay where they are and are never changed.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            Button("Import a Folder…") { model.lab.importPanel() }.buttonStyle(QPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Moves a roll to another project, with its card: the library's roll cards and the sidebar's rolls.
struct RollMoveMenu: View {
    let lab: LabState
    let project: LabProject
    let roll: LabRoll

    var body: some View {
        let others = lab.projects.ordinary.filter { $0.id != project.id }
        Menu("Move to Project") {
            ForEach(others) { other in
                Button(other.name) { lab.projects.moveRoll(roll.id, from: project.id, to: other.id) }
            }
        }
        .disabled(others.isEmpty)
    }
}
