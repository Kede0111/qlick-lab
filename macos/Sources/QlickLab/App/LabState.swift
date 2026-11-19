// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// The lab's rooms. `develop` is NEgs's editor, untouched underneath; the others are laid over it.
enum Workspace: String, CaseIterable, Identifiable, Sendable {
    case library, contactSheet, develop, compare, recipes, films, papers, importer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .contactSheet: "Contact Sheet"
        case .develop: "Develop"
        case .compare: "Compare"
        case .recipes: "Recipes"
        case .films, .papers: "Stocks"
        case .importer: "Import"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.stack.3d.up"
        case .contactSheet: "film"
        case .develop: "slider.horizontal.3"
        case .compare: "rectangle.split.2x1"
        case .recipes: "flask"
        case .films: "film.stack"
        case .papers: "doc.plaintext"
        case .importer: "square.and.arrow.down"
        }
    }

    /// ⌘1…⌘7 in the Espace menu.
    var key: String { self == .importer ? "0" : String((Workspace.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// As the sidebar and the menu list them: Import first, where a session starts; the others keep their keys.
    /// Films and papers are one room, Stocks, with a switch inside (`StockLibrary`): only `films` is listed.
    static let ordered: [Workspace] = [.importer] + allCases.filter { $0 != .importer && $0 != .papers }

    /// The room a sidebar row or menu item stands for: Stocks is lit for its films and its papers.
    func listed(as room: Workspace) -> Bool { self == room || (room == .films && self == .papers) }
}

/// How the contact sheet is laid out and worked on. Kept between launches.
struct SheetOptions: Codable, Equatable, Sendable {
    /// `grid` is NEgs's own sheet: the photographs side by side at their proportions, no film.
    enum Style: String, Codable, CaseIterable, Sendable { case classic, compact, detail, grid }
    enum Tool: String, Codable, Sendable { case pencil, pointer, loupe }
    /// What the pencil draws at a click: a ring (pick) or a cross (reject). ⌥ draws the other.
    enum Mark: String, Codable, Sendable { case ring, cross }

    var style = Style.classic
    var pencilMark = Mark.ring
    /// The strips of film under the frames; off, only the photographs lie on the sheet.
    var showFilm = true
    /// A frame's width in points.
    var frameWidth = 168.0
    var tool = Tool.pencil
    /// A light box under the strips rather than the dark sheet.
    var lightTable = false
    var showNames = true
    /// File names under each frame, on the sheet, rather than printed on the film's edge. Optional so options saved
    /// before it read as they were (on the edge).
    var namesUnder: Bool? = nil
    var showInfo = false

    /// Where file names show, in every view of the photographs: the contact sheet's four, Develop's film strip.
    enum FileNames: String, CaseIterable, Sendable {
        case off, edge, under
        var title: String {
            switch self {
            case .off: "Off"
            case .edge: "On the Edge"
            case .under: "Under the Frame"
            }
        }
    }

    var fileNames: FileNames {
        get { !showNames ? .off : namesUnder == true ? .under : .edge }
        set { showNames = newValue != .off; namesUnder = newValue == .under ? true : nil }
    }
    /// Upright frames lie on their side, as they do on a strip of film.
    var sidewaysVerticals = false

    static let widths: ClosedRange<Double> = 84...420
    static let key = "qlick.sheetOptions2"

    static func load(_ defaults: UserDefaults = .standard) -> SheetOptions {
        guard let data = defaults.data(forKey: key), let options = try? JSONDecoder().decode(SheetOptions.self, from: data) else { return SheetOptions() }
        return options
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// What Qlick Lab adds round NEgs's editor: which room is open, the projects, and the contact sheet's state.
/// The photographs, their marks, their developments and the selection stay NEgs's (`EditorModel`), so every
/// command of the editor (rating, copy and paste of edits, batch export, duplicates) works on the sheet as it is.
@MainActor @Observable final class LabState {
    @ObservationIgnored unowned let model: EditorModel
    let projects: ProjectStore
    let keys = ShortcutStore()
    let catalogs = CatalogList()
    /// Builds the photographs' previews ahead, in the background.
    @ObservationIgnored private(set) lazy var previewBuilder = PreviewBuilder(model: model)
    /// Qlick Lab: moves to open the background work's panel (automation, the menu).
    var workPanelAsked = 0
    /// Qlick Lab: the RAW photographs' proxies, made ahead.
    @ObservationIgnored private(set) lazy var proxyMaker = ProxyMaker(model: model)
    /// The import room: its source, what's chosen of it, and the import running.
    let importer: ImportSession

    private(set) var workspace = Workspace.develop
    /// The adjustments float over the photograph on glass, instead of in a column beside it.
    var floatingPanel = NSClassFromString("XCTestCase") == nil && (UserDefaults.standard.object(forKey: "qlick.floatingPanel") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(floatingPanel, forKey: "qlick.floatingPanel") }
    }
    var toolbarVisible = UserDefaults.standard.object(forKey: "qlick.toolbar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(toolbarVisible, forKey: "qlick.toolbar") }
    }
    /// What the caption over the photograph shows (View › Caption).
    var caption = CaptionOptions.load() { didSet { if caption != oldValue { caption.save() } } }
    /// The targets of Develop's right-click menu and of the caption's.
    @ObservationIgnored private(set) lazy var developCommands = DevelopCommands(lab: self)
    @ObservationIgnored private(set) lazy var captionCommands = CaptionCommands(lab: self)
    /// The photograph's metadata, on glass over the canvas (View › Photograph Information).
    var infoVisible = UserDefaults.standard.bool(forKey: "qlick.photoInfo") {
        didSet { UserDefaults.standard.set(infoVisible, forKey: "qlick.photoInfo") }
    }
    var sidebarVisible = UserDefaults.standard.object(forKey: "qlick.sidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "qlick.sidebar") }
    }
    var sheet = SheetOptions.load() {
        didSet { if sheet != oldValue { sheet.save() } }
    }
    /// Développement's loupe tool (Z): a click on the photograph zooms to its pixels there.
    var developLoupe = false { didSet { model.canvasScale.loupe = developLoupe; if developLoupe { pickingWhite = false } } }
    /// The white balance eyedropper is out (W): a click on the photograph balances it there.
    var pickingWhite = false { didSet { model.canvasScale.picking = pickingWhite; if pickingWhite { developLoupe = false } } }
    /// The photographs' order (`LibrarySort`).
    var sort = LibrarySort.load() { didSet { if sort != oldValue { sort.save() } } }
    /// The filter bar under the grid and over the contact sheet (`\`).
    var filterBarVisible = UserDefaults.standard.object(forKey: "qlick.filterBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filterBarVisible, forKey: "qlick.filterBar") }
    }
    /// The frame shown large over the sheet (Space).
    var loupe: URL?
    /// The photographs laid side by side in Comparaison.
    var compare = CompareSetup()
    var favouriteStocks: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qlick.favouriteStocks") ?? []) {
        didSet { UserDefaults.standard.set(favouriteStocks.sorted(), forKey: "qlick.favouriteStocks") }
    }
    /// The print dialog of the contact sheet.
    var printing = false
    /// A sheet asking for a new project's name, and the folders waiting for it.
    var naming: ProjectNaming?

    struct ProjectNaming: Identifiable {
        let id = UUID()
        var name: String
        var folders: [URL] = []
    }

    /// Comparaison's panes, and the helper that develops for it and for the loupe.
    @ObservationIgnored private(set) lazy var compareModel = CompareModel(model: model)
    /// Set by the menu, which owns the Settings window.
    @ObservationIgnored var openSettings: () -> Void = {}
    /// The stocks' own data, read from their profiles.
    let stockProfiles = StockProfiles()
    /// The camera's own white balance of the photographs developed, as a temperature and a tint.
    let asShot = AsShotBalances()
    /// EXIF of the frames on screen.
    let facts = FrameFactsCache()
    /// The sheet on screen, for commands that need its view (print, automation).
    @ObservationIgnored weak var sheetView: ContactSheetView?

    @ObservationIgnored private var seenMode = LibraryMode.photo
    /// The sheet is wanted for a folder whose first photograph is still opening.
    @ObservationIgnored private var sheetPending = false

    init(model: EditorModel) {
        self.model = model
        importer = ImportSession(model: model)
        projects = ProjectStore(directory: CatalogList().initial)
        model.canvasScale.contextMenu = { [weak self] point in self?.developCommands.menu(at: point) }
    }

    // MARK: Rooms

    /// Opens a room, bringing NEgs's editor to the state it needs: the sheet works on the folder as NEgs's grid
    /// does (rating and edit commands act on the selection), developing on one photograph.
    func show(_ next: Workspace) {
        guard !model.cropping || next == .develop else { NSSound.beep(); return }
        loupe = nil
        switch next {
        case .contactSheet:
            if model.source != nil, model.mode != .grid { model.showGrid() }
        case .develop:
            if model.mode == .grid { model.editCurrent() }
        default: break
        }
        seenMode = model.mode
        if next == .library { projects.sidecars = model.sidecarLookup?.store; projects.countAll() }
        if next == .importer { importer.refreshVolumes() }
        if workspace != next { workspace = next }
    }

    /// Follows the editor when it changes between one photograph and the folder by itself (G, Esc, a double-click).
    func follow(mode: LibraryMode) {
        guard mode != seenMode else { return }
        seenMode = mode
        if mode == .grid, workspace == .develop { workspace = .contactSheet }
        if mode == .photo, workspace == .contactSheet { workspace = .develop }
    }

    // MARK: Rolls

    /// The roll being worked on: the one whose folder is open.
    var current: (project: LabProject, roll: LabRoll)? { projects.find(folder: model.library.directory) }

    var title: String {
        switch workspace {
        case .develop: return model.sourceItem.map { model.library.name(of: $0) } ?? "Qlick Lab"
        case .contactSheet, .compare:
            if let current { return "\(current.project.name) — \(current.roll.name)" }
            if let whole = wholeProject { return "\(whole.name) — all rolls" }
            return model.library.directory?.lastPathComponent ?? workspace.title
        default: return workspace.title
        }
    }

    /// The project shown whole, all its rolls on one sheet.
    var wholeProject: LabProject? { projects.project(viewFolder: model.library.directory) }

    /// Removes a project from the catalogue, once asked. Its photographs and their sidecars stay where they are;
    /// its contact sheet closes, its previews leave the cache and the import forgets it, so it can come back whole.
    func removeProject(_ project: LabProject) {
        Task {
            let answer = await model.ask(AppAlert(
                title: "Remove “\(project.name)” from the catalog?",
                detail: "Its photographs and their marks stay where they are: its folders can be added again at any time. Its previews are removed from the cache.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Remove", role: .destructive)]))
            guard answer.button == 1, projects.projects.contains(where: { $0.id == project.id }) else { return }
            let others = Set(projects.projects.filter { $0.id != project.id }.flatMap { $0.rolls.map(\.folder) })
            let folders = project.rolls.compactMap { projects.resolve($0, in: project.id) }.filter { !others.contains($0.standardizedFileURL.path) }
            // What's open of it closes: its contact sheet, its photograph.
            let open = model.library.directory?.standardizedFileURL.path
            let showing = wholeProject?.id == project.id || folders.contains { $0.standardizedFileURL.path == open }
            if showing { model.closeFolder() }
            previewBuilder.cancel(); proxyMaker.cancel()
            // Shown whole, its photographs are reached through its folder of links: their previews are named by
            // those paths too. Read before the folder goes.
            let links = projects.directory.appendingPathComponent("Views", isDirectory: true).appendingPathComponent(project.id.uuidString, isDirectory: true)
            var aliases: [URL: [URL]] = [:]
            for link in (try? FileManager.default.contentsOfDirectory(at: links, includingPropertiesForKeys: nil)) ?? [] {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { continue }
                let real = URL(fileURLWithPath: target).standardizedFileURL
                if let folder = folders.first(where: { $0.standardizedFileURL.path == real.path }) { aliases[folder, default: []].append(link) }
            }
            projects.remove(project.id)
            if showing || workspace == .contactSheet || workspace == .develop { show(.library) }
            // The cache and the import's memory, off the main thread: a disk on the network answers slowly.
            importer.ledger.forget(folders: Set(folders.map { $0.standardizedFileURL.path }))
            let archive = model.renderArchive
            Task.detached(priority: .utility) {
                for folder in folders {
                    guard let photos = try? PhotoFolder.listing(in: folder).photos else { continue }
                    for photo in photos {
                        // The photograph as its folder lists it, and as its project's folder of links did.
                        let places = [photo.url] + (aliases[folder] ?? []).map { $0.appendingPathComponent(photo.url.lastPathComponent) }
                        for place in places {
                            archive.removePreview(of: PhotoFile(url: place))
                            for lens in [false, true] { if let proxy = PreviewStorage.proxyFile(for: photo.url, as: place, lensCorrection: lens) { try? FileManager.default.removeItem(at: proxy) } }
                        }
                    }
                }
            }
        }
    }

    /// Opens every roll of a project on one contact sheet.
    func openWhole(_ project: LabProject) {
        guard !project.rolls.isEmpty else { return show(.library) }
        guard let folder = projects.viewFolder(for: project) else {
            model.error = "The project “\(project.name)” couldn’t be opened."
            return
        }
        // Listed again, in case the project's rolls changed since.
        if model.library.directory?.standardizedFileURL.path == folder.standardizedFileURL.path { model.library.refreshNow() }
        open(folder: folder)
        model.libraryRoot = folder
    }

    /// Opens a roll on its contact sheet.
    func open(_ roll: LabRoll, in project: LabProject) {
        guard let folder = projects.resolve(roll, in: project.id) else {
            model.error = "The folder “\(roll.name)” can't be found. It may have moved, or its disk isn't connected."
            return
        }
        open(folder: folder)
    }

    func open(folder: URL) {
        guard !model.cropping else { NSSound.beep(); return }
        loupe = nil
        if model.library.directory?.standardizedFileURL.path != folder.standardizedFileURL.path || model.source == nil {
            model.open(folder)
        } else if model.mode != .grid {
            model.showGrid()
        }
        seenMode = model.mode
        workspace = .contactSheet
    }

    /// Folders dropped on the window or chosen in the panel: rolls of `project`, or of a new project that asks its name.
    func importFolders(_ urls: [URL], into project: UUID? = nil) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        // A photograph dropped alone opens, as in NEgs.
        guard !folders.isEmpty else {
            if let file = urls.first(where: \.isFileURL) { model.open(file); show(.develop) }
            return
        }
        guard !folders.flatMap({ ProjectStore.rollFolders(in: $0) }).isEmpty else {
            model.error = "No readable photographs in “\(folders[0].lastPathComponent)”."
            return
        }
        // One counter: a single folder opens the Import room on it, Leave Where They Are chosen, the project already
        // named, so the recipe, the marks and the words are chosen as for a card. Several at once are added directly.
        let target = (project ?? current?.project.id).flatMap { id in projects.ordinary.first { $0.id == id } }
        if folders.count == 1, importer.run == nil {
            importer.open(ImportVolumes.folder(folders[0]))
            importer.options.mode = .add
            importer.choose(project: target)
            show(.importer)
        } else if let target {
            add(folders, to: target.id)
        } else {
            naming = ProjectNaming(name: projects.uniqueName(folders.count == 1 ? folders[0].lastPathComponent : "New Project"), folders: folders)
        }
    }

    func add(_ folders: [URL], to project: UUID) {
        projects.sidecars = model.sidecarLookup?.store
        let added = projects.addRolls(folders, to: project)
        if let first = added.first { open(folder: first.url) }
    }

    func finishNaming(_ naming: ProjectNaming) {
        self.naming = nil
        let project = projects.create(named: naming.name)
        if !naming.folders.isEmpty { add(naming.folders, to: project.id) }
    }

    func importPanel(into project: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import a Folder"
        panel.message = "Choose a folder of photographs. Import opens on it: copy it, move it, or leave it where it is."
        panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.importFolders(panel.urls, into: project) }
        }
    }

    // MARK: The sheet's marks

    /// The photographs the sheet shows, as NEgs's grid would.
    var frames: [PhotoFile] { model.library.filtering ? [] : model.shownPhotos }

    /// Counts for the sheet's filters, over the whole roll.
    var counts: RollStats {
        var stats = RollStats()
        for item in model.library.items {
            stats.total += 1
            let summary = model.library.summary(for: item.url)
            if summary.flag == .pick { stats.picks += 1 }
            if summary.flag == .reject { stats.rejects += 1 }
            if summary.edited { stats.edited += 1 }
        }
        return stats
    }

    /// The pencil's key: rings (or crosses) the frames the keys act on, or lifts the mark if they all carry it.
    func toggleMark(_ flag: PhotoSidecar.Flag) {
        let targets = model.ratingTargets
        guard !targets.isEmpty else { return }
        let all = targets.allSatisfy { model.library.summary(for: $0).flag == flag }
        model.setFlag(all ? nil : flag)
    }

    enum MarkFilter: Equatable { case all, picks, rejects, unmarked, other }

    var markFilter: MarkFilter {
        get {
            let filter = model.library.filter
            guard filter.rating == .any, !filter.editedOnly else { return .other }
            switch filter.flags {
            case []: return .all
            case [.pick]: return .picks
            case [.reject]: return .rejects
            case [.unflagged]: return .unmarked
            default: return .other
            }
        }
        set {
            var filter = LibraryFilter()
            switch newValue {
            case .all, .other: break
            case .picks: filter.flags = [.pick]
            case .rejects: filter.flags = [.reject]
            case .unmarked: filter.flags = [.unflagged]
            }
            model.library.filter = filter
        }
    }

    // MARK: Compare

    /// Lays the selected photographs side by side; with one or none, the current one beside the next.
    func compareSelection() {
        let order = model.shownPhotos.map(\.url)
        var items = model.selection.ordered(order)
        if items.count < 2, let current = model.selection.current ?? model.sourceItem, let index = order.firstIndex(of: current) {
            items = [current] + (order.indices.contains(index + 1) ? [order[index + 1]] : [])
        }
        compare = CompareSetup(kind: .photographs, items: Array(items.prefix(CompareSetup.most)))
        show(.compare)
    }

    /// Favourite recipes, by name (a recipe is a file the photographer names).
    var favouriteRecipes: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qlick.favouriteRecipes") ?? []) {
        didSet { UserDefaults.standard.set(favouriteRecipes.sorted(), forKey: "qlick.favouriteRecipes") }
    }

    func toggleFavouriteRecipe(_ name: String) {
        if favouriteRecipes.contains(name) { favouriteRecipes.remove(name) } else { favouriteRecipes.insert(name) }
    }

    func toggleFavourite(_ stock: String) {
        if favouriteStocks.contains(stock) { favouriteStocks.remove(stock) } else { favouriteStocks.insert(stock) }
    }
}
