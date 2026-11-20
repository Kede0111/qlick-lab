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
    /// The sidebar's rows unfolded or folded by hand (`SidebarFold`), kept while the lab is open.
    var sidebarFold = SidebarFold()
    /// What a drag started in the lab carries (`LabDragItem`), from its start to its drop.
    @ObservationIgnored var dragging: LabDragItem?
    /// The sidebar's side of a drag: its rows, the one under the pointer, what a drop there would do.
    let sidebarDrop = SidebarDropModel()
    /// The photographs copied (⌘C), which ⌘V adds to the Box or Roll open.
    var copiedPhotos: [URL] = []
    /// The undo target of the Boxes' and Archives' changes (`undoable`).
    @ObservationIgnored let libraryEdits = LibraryEditsUndoTarget()
    /// Qlick Lab: every photograph of the catalogue, indexed: All Photographs, Picks, By Date, Smart Rolls, the search.
    let catalog = CatalogIndex()
    /// What's worked out from the index until it changes (`FindingCache`).
    @ObservationIgnored var finding = FindingCache()
    @ObservationIgnored var catalogDirectory: String?
    /// Moves when an import ends, for Last Import.
    var lastImportStamp = 0
    /// The Smart Roll being made or changed in the rule editor.
    var smartRollDraft: SmartRollDraft?
    /// The library's search whose photographs are open on the sheet (`LabView.found`).
    var foundQuery = ""
    /// The library page's search, kept while the lab is open.
    var libraryQuery = ""

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
    /// The photographs' order (`LibrarySort`): a folder's and a list's, and apart from it a Box's or a Roll's, which
    /// is Custom Order (`ManualOrder`) unless another is chosen there.
    var sort: LibrarySort {
        get { openView?.holder != nil ? boxSort : listSort }
        set { if openView?.holder != nil { boxSort = newValue } else { listSort = newValue } }
    }
    var listSort = LibrarySort.load() { didSet { if listSort != oldValue { listSort.save() } } }
    var boxSort = LibrarySort.load(key: LibrarySort.boxKey, fallback: LibrarySort(key: .custom)) {
        didSet { if boxSort != oldValue { boxSort.save(key: LibrarySort.boxKey) } }
    }
    /// The filter bar under the grid and over the contact sheet (`\`).
    var filterBarVisible = UserDefaults.standard.object(forKey: "qlick.filterBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filterBarVisible, forKey: "qlick.filterBar") }
    }
    /// The frame shown large over the sheet (Space).
    var loupe: URL?
    /// Qlick Lab: the Keywords panel over the contact sheet (label, title, caption, keywords); in Develop it's part of
    /// the photograph's information (⌘I).
    var wordsVisible = UserDefaults.standard.bool(forKey: "qlick.keywordsPanel") {
        didSet { UserDefaults.standard.set(wordsVisible, forKey: "qlick.keywordsPanel") }
    }
    /// Moves when ⌘K asks for the Add Keyword field, which then takes the keys (`keywordFocusPending` until it has).
    var keywordFocus = 0
    @ObservationIgnored var keywordFocusPending = false
    /// The keyword set's nine fields are open in the panel.
    var editingKeywordSet = false
    /// The photographs laid side by side in Comparaison.
    var compare = CompareSetup()
    var favouriteStocks: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qlick.favouriteStocks") ?? []) {
        didSet { UserDefaults.standard.set(favouriteStocks.sorted(), forKey: "qlick.favouriteStocks") }
    }
    /// The print dialog of the contact sheet.
    var printing = false
    /// A sheet asking for a name: a new Archive (and the folders waiting for it), a new Box or Roll (and the photographs
    /// going in), or a new name for one of them.
    var naming: Naming?

    struct Naming: Identifiable {
        enum Kind: Equatable {
            case archive
            /// On top, or inside a Box.
            case box(in: UUID?)
            case roll(in: UUID)
            case renameArchive(UUID)
            case renameBox(UUID)
            case renameRoll(UUID, box: UUID)
        }
        let id = UUID()
        var kind: Kind
        var name: String
        var folders: [URL] = []
        var frames: [URL] = []
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
        importer.loadProfiles(inCatalog: projects.directory)
        // The Binder's folders and the import's old Recent list (before 0.4): the Archives' Folders replace them.
        for key in ["qlick.binderRoots", "qlick.importRecent"] { UserDefaults.standard.removeObject(forKey: key) }
        if NSClassFromString("XCTestCase") == nil { projects.folders.start() }
        model.canvasScale.contextMenu = { [weak self] point in self?.developCommands.menu(at: point) }
        projects.removedChanged = { [weak self] in self?.followRemoved($0) }
        setUpFinding()
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
        notePlace(Place(workspace: next, folder: model.library.directory?.standardizedFileURL))
    }

    /// Follows the editor when it changes between one photograph and the folder by itself (G, Esc, a double-click).
    func follow(mode: LibraryMode) {
        guard mode != seenMode else { return }
        seenMode = mode
        if mode == .grid, workspace == .develop { workspace = .contactSheet }
        if mode == .photo, workspace == .contactSheet { workspace = .develop }
        notePlace(place)
    }

    // MARK: Where the lab is

    /// The list open on the sheet, if one is: a whole Archive, a Folder with those under it, a Box, a Roll.
    var openView: LabView? { projects.view(of: model.library.directory) }

    /// The Box or Roll open on the sheet; a Smart Roll is none (its rules fill it, not the hand).
    var openHolder: Holder? {
        guard let holder = openView?.holder, !projects.isSmart(holder) else { return nil }
        return holder
    }

    /// The Folder being worked on, with its Archive: the folder open (or the Folder whose list is open), as the lab
    /// knows it (`ProjectStore.folder`).
    var current: (project: LabProject, roll: LabRoll)? {
        let path: String
        if case .folder(let folder, _)? = openView { path = folder }
        else if let directory = model.library.directory, !PhotoFolder.isList(directory) { path = directory.standardizedFileURL.path }
        else { return nil }
        guard let place = projects.place(of: path) else { return nil }
        return (place.archive, projects.folder(path, in: place.archive))
    }

    /// The Archive being worked on: the one open, or the one whose folder is.
    var workingArchive: LabProject? {
        if case .archive(let id)? = openView { return projects.archive(id) }
        return current?.project
    }

    /// The window's title, as a trail: where the photographs come from, then the photograph. Archive › Folder ›
    /// L1003911.DNG in Develop, Archive › Folder on the sheet, Box › Box › Roll for a Roll of a Box inside a Box.
    var title: String { trail.joined(separator: "  ›  ") }

    var trail: [String] { crumbs.map(\.text) }

    /// One word of the title's trail, and where a click on it leads: the Archive, Box or Roll opens whole, the Folder
    /// on its sheet. The last word is where the lab is, and leads nowhere.
    struct Crumb: Equatable {
        enum Target: Equatable {
            case view(LabView)
        }
        var text: String
        var target: Target? = nil
    }

    var crumbs: [Crumb] {
        var folder: [Crumb] = []
        let view = openView
        if let current {
            folder = [Crumb(text: current.project.name, target: .view(.archive(current.project.id))),
                      Crumb(text: current.roll.name, target: .view(.folder(current.roll.folder, archive: current.project.id)))]
        } else if case .archive(let id)? = view, let archive = projects.archive(id) {
            folder = [Crumb(text: archive.name, target: .view(.archive(id)))]
        } else if case .box(let id)? = view, let path = projects.boxPath(id) {
            folder = path.map { Crumb(text: $0.name, target: .view(.box($0.id))) }
        } else if case .roll(let id, let boxID)? = view, let path = projects.boxPath(boxID), let roll = path.last?.rolls.first(where: { $0.id == id }) {
            folder = path.map { Crumb(text: $0.name, target: .view(.box($0.id))) } + [Crumb(text: roll.name, target: .view(.roll(id, box: boxID)))]
        } else if let view, let fixed = fixedCrumbs(view) {
            folder = fixed
        } else if let directory = model.library.directory, !PhotoFolder.isList(directory) {
            folder = [Crumb(text: directory.lastPathComponent)]
        }
        let room = Crumb(text: workspace.title)
        var crumbs: [Crumb]
        switch workspace {
        case .develop:
            guard let item = model.sourceItem else { return [Crumb(text: "Qlick Lab")] }
            crumbs = folder + [Crumb(text: model.library.name(of: item))]
        case .contactSheet: crumbs = folder.isEmpty ? [room] : folder
        case .compare: crumbs = folder.isEmpty ? [room] : folder + [room]
        default: crumbs = [room]
        }
        // Where the lab is leads nowhere: the last word, and any word that is the list already open.
        if !crumbs.isEmpty { crumbs[crumbs.count - 1].target = nil }
        if workspace == .contactSheet, let view {
            for index in crumbs.indices where crumbs[index].target == .view(view) { crumbs[index].target = nil }
        }
        return crumbs
    }

    /// A click on a word of the trail.
    func follow(_ target: Crumb.Target) {
        switch target {
        case .view(let view): open(view)
        }
    }

    // MARK: Back and forward

    /// A place in the lab: a room and the folder open in it. Back and Forward (⌘[ ⌘]) walk the places visited, so
    /// opening a roll, finishing an import or Esc never leaves the way back unknown.
    struct Place: Equatable {
        var workspace: Workspace
        var folder: URL?
    }

    @ObservationIgnored private(set) var places: [Place] = []
    @ObservationIgnored private(set) var placeIndex = -1
    @ObservationIgnored private var walking = false
    /// Moves when Back or Forward become possible or not, for the menus.
    private(set) var placesChanged = 0

    var place: Place { Place(workspace: workspace, folder: model.library.directory?.standardizedFileURL) }
    var canGoBack: Bool { placeIndex > 0 }
    var canGoForward: Bool { placeIndex >= 0 && placeIndex < places.count - 1 }

    /// Notes where the lab goes: called by `show`, `open(folder:)` and `follow(mode:)` with where they lead, since a
    /// folder opens a moment after it's asked for.
    func notePlace(_ now: Place) {
        guard !walking, placeIndex < 0 || places[placeIndex] != now else { return }
        places.removeSubrange((placeIndex + 1)...)
        places.append(now)
        if places.count > 100 { places.removeFirst(places.count - 100) }
        placeIndex = places.count - 1
        placesChanged += 1
    }

    func goBack() { if canGoBack { walk(to: placeIndex - 1) } }
    func goForward() { if canGoForward { walk(to: placeIndex + 1) } }

    private func walk(to index: Int) {
        guard !model.cropping else { NSSound.beep(); return }
        let target = places[index]
        walking = true
        defer { walking = false }
        if let folder = target.folder, folder != model.library.directory?.standardizedFileURL {
            // A list is listed again (its Box may have changed since); a list whose Box went is skipped.
            if let view = projects.view(of: folder) { projects.viewFolder(for: view) }
            let gone = folder.path.hasPrefix(projects.directory.appendingPathComponent("Views").path + "/") && projects.view(of: folder) == nil
            guard !gone, PhotoFolder.isList(folder) || FileManager.default.fileExists(atPath: folder.path) else {
                // The folder went (a card taken out): that place is skipped.
                places.remove(at: index)
                if placeIndex > index { placeIndex -= 1 }
                placesChanged += 1
                return
            }
            open(folder: folder)
        }
        show(target.workspace)
        placeIndex = index
        placesChanged += 1
    }

    /// The Archive shown whole, all its Folders on one sheet.
    var wholeProject: LabProject? { projects.project(viewFolder: model.library.directory) }

    /// Removes an Archive from the catalogue, once asked. Its photographs and their sidecars stay where they are;
    /// its contact sheet closes, its previews leave the cache and the import forgets it, so it can come back whole.
    func removeProject(_ project: LabProject) {
        Task {
            let answer = await model.ask(AppAlert(
                title: "Remove the Archive “\(project.name)” from the catalog?",
                detail: "Its photographs and their marks stay where they are, on the disk and in their Boxes: its folders can be added again at any time. Its previews are removed from the cache.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Remove", role: .destructive)]))
            guard answer.button == 1, projects.projects.contains(where: { $0.id == project.id }) else { return }
            let others = Set(projects.projects.filter { $0.id != project.id }.flatMap { $0.rolls.map(\.folder) })
            let folders = projects.photoFolders(of: project).filter { !others.contains($0.standardizedFileURL.path) }
            // What's open of it closes: its contact sheet, its photograph.
            let showing = workingArchive?.id == project.id
            if showing { model.closeFolder() }
            previewBuilder.cancel(); proxyMaker.cancel()
            projects.remove(project.id)
            if showing || workspace == .contactSheet || workspace == .develop { show(.library) }
            // The cache and the import's memory, off the main thread: a disk on the network answers slowly.
            importer.ledger.forget(folders: Set(folders.map { $0.standardizedFileURL.path }))
            let archive = model.renderArchive
            Task.detached(priority: .utility) {
                for folder in folders {
                    guard let photos = try? PhotoFolder.listing(in: folder).photos else { continue }
                    for photo in photos {
                        archive.removePreview(of: PhotoFile(url: photo.url))
                        for lens in [false, true] { if let proxy = PreviewStorage.proxyFile(for: photo.url, as: photo.url, lensCorrection: lens) { try? FileManager.default.removeItem(at: proxy) } }
                    }
                }
            }
        }
    }

    /// Opens every Folder of an Archive on one contact sheet.
    func openWhole(_ project: LabProject) { open(.archive(project.id)) }

    /// Opens a list on the contact sheet: a whole Archive, a Folder with those under it, a Box, a Roll of a Box.
    func open(_ view: LabView) {
        switch view {
        case .archive(let id):
            guard let archive = projects.archive(id), !archive.rolls.isEmpty else { return show(.library) }
        case .folder(let path, let id):
            // A folder with nothing under it opens as itself. Before its tree is read (a Folder just added), the disk
            // is asked now: a folder whose photographs are all in folders under it opens as their list, never as an
            // empty folder.
            let tree = projects.node(path) ?? FolderTrees.read(URL(fileURLWithPath: path, isDirectory: true))
            if tree?.photosBelow != true {
                if let archive = projects.archive(id), let entry = archive.rolls.first(where: { $0.folder == path }) { return open(entry, in: archive) }
                return open(folder: URL(fileURLWithPath: path, isDirectory: true))
            }
        case .box, .roll:
            guard let holder = view.holder, let name = projects.name(of: holder) else { return }
            guard !projects.frames(of: holder).isEmpty else {
                model.error = projects.isSmart(holder)
                    ? (catalog.ready ? "No photographs meet the rules of “\(projects.shortName(holder) ?? name)” yet." : "The lab is still reading the catalog's photographs. Try again in a moment.")
                    : "“\(name)” is empty. Put photographs in it from a contact sheet: right-click › Add to Box."
                return
            }
        case .all:
            guard projects.projects.contains(where: { !$0.rolls.isEmpty }) else { return show(.library) }
        case .lastImport, .picks, .day, .found:
            guard !listedFrames(view).isEmpty else {
                model.error = !catalog.ready && view != .lastImport ? "The lab is still reading the catalog's photographs. Try again in a moment."
                    : view == .lastImport ? "Nothing has been imported into this catalog yet."
                    : view == .picks ? "No photographs are picked yet. Ring them with the pencil on the contact sheet."
                    : view == .found ? "No photograph matches “\(foundQuery)”."
                    : "No photographs were taken then."
                return
            }
        }
        let folder = projects.viewFolder(for: view)
        // Listed again, in case the Archive's folders or the Box's photographs changed since.
        if model.library.directory?.standardizedFileURL.path == folder.standardizedFileURL.path { model.library.refreshNow() }
        open(folder: folder)
    }

    /// Opens a Folder on its contact sheet.
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
            // A whole project or a selection is a list of photographs, not a folder on disk.
            if PhotoFolder.isList(folder) { model.openList(folder) } else { model.open(folder) }
        } else if model.mode != .grid {
            model.showGrid()
        }
        seenMode = model.mode
        workspace = .contactSheet
        notePlace(Place(workspace: .contactSheet, folder: folder.standardizedFileURL))
    }

    /// Folders dropped on the window or chosen in the panel: Folders of `project`, or of a new Archive that asks its name.
    func importFolders(_ urls: [URL], into project: UUID? = nil) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        // A photograph dropped alone opens, as in NEgs.
        guard !folders.isEmpty else {
            if let file = urls.first(where: \.isFileURL) { model.open(file); show(.develop) }
            return
        }
        guard folders.contains(where: ProjectStore.holdsPhotographs) else {
            model.error = "No readable photographs in “\(folders[0].lastPathComponent)”."
            return
        }
        // One counter: a single folder opens the Import room on it, Leave in Place chosen, the Archive already named, so
        // the recipe, the marks and the words are chosen as for a card. Several at once are added directly.
        let target = (project ?? workingArchive?.id).flatMap { projects.archive($0) }
        if folders.count == 1, importer.run == nil {
            importer.open(ImportVolumes.folder(folders[0]))
            importer.options.mode = .add
            importer.choose(project: target)
            show(.importer)
        } else if let target {
            add(folders, to: target.id)
        } else {
            naming = Naming(kind: .archive, name: projects.uniqueName(folders.count == 1 ? folders[0].lastPathComponent : "New Archive"), folders: folders)
        }
    }

    func add(_ folders: [URL], to project: UUID) {
        projects.sidecars = model.sidecarLookup?.store
        let added = projects.addRolls(folders, to: project)
        // Opened as the sidebar opens it: with the folders under it, read from the disk now if they aren't yet.
        if let first = added.first {
            if projects.node(first.folder) == nil { projects.folders.rescanNow(first.url) }
            open(.folder(first.folder, archive: project))
        }
    }

    func finishNaming(_ naming: Naming) {
        self.naming = nil
        switch naming.kind {
        case .archive:
            let project = projects.create(named: naming.name)
            if !naming.folders.isEmpty { add(naming.folders, to: project.id) }
        case .box(let parent):
            // One undo step, as every change to the Boxes.
            guard undoable(naming.frames.isEmpty ? "New Box" : "New Box from Selection", {
                projects.createBox(named: naming.name, in: parent, frames: naming.frames) != nil
            }) else { return }
            if let parent { sidebarFold.unfold(.box(parent)) }
        case .roll(let boxID):
            guard undoable("New Roll", { projects.createRoll(named: naming.name, in: boxID, frames: naming.frames) != nil }) else { return }
            sidebarFold.unfold(.box(boxID))
        case .renameArchive(let id): undoable("Rename Archive") { projects.rename(id, to: naming.name); return true }
        case .renameBox(let id): undoable("Rename Box") { projects.renameBox(id, to: naming.name); return true }
        case .renameRoll(let id, let boxID): undoable("Rename Roll") { projects.renameRoll(id, in: boxID, to: naming.name); return true }
        }
    }

    func newArchive() { naming = Naming(kind: .archive, name: projects.uniqueName("New Archive")) }

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
            guard filter.rating == .any, !filter.editedOnly, filter.labels.isEmpty, !filter.unlabelled, filter.keyword == nil else { return .other }
            switch filter.flags {
            case []: return .all
            case [.pick]: return .picks
            case [.reject]: return .rejects
            case [.unflagged]: return .unmarked
            default: return .other
            }
        }
        set {
            // The search, the period, film, camera and lens stay: they're not marks.
            let old = model.library.filter
            var filter = LibraryFilter(search: old.search, period: old.period, film: old.film, camera: old.camera, lens: old.lens)
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
