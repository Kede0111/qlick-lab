// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// The lab's rooms. `develop` is the editor underneath; the others are laid over it.
enum Workspace: String, CaseIterable, Identifiable, Sendable {
    case library, contactSheet, develop, compare, recipes, films, papers, importer, print
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
        case .print: "Print"
        }
    }

    var symbol: String {
        switch self {
        // The lab's own glyphs (`LabGlyph`), drawn by `LabSymbol`; Papers keeps a system symbol, it's never listed.
        case .library: LabGlyph.prints.symbol
        case .contactSheet: LabGlyph.strip.symbol
        case .develop: LabGlyph.tank.symbol
        case .compare: LabGlyph.loupe.symbol
        case .recipes: LabGlyph.flask.symbol
        case .films: LabGlyph.stocks.symbol
        case .papers: "doc.plaintext"
        case .importer: LabGlyph.card.symbol
        case .print: LabGlyph.enlarger.symbol
        }
    }

    /// ⌥⌘1…⌥⌘7 in the Lab menu; Import ⌥⌘0, Print ⌥⌘8.
    var key: String {
        switch self {
        case .importer: "0"
        case .print: "8"
        default: String((Workspace.allCases.firstIndex(of: self) ?? 0) + 1)
        }
    }

    /// As the sidebar and the menu list them: Import first, where a session starts; the others keep their keys.
    /// Films and papers are one room, Stocks, with a switch inside (`StockLibrary`): only `films` is listed.
    static let ordered: [Workspace] = [.importer] + allCases.filter { $0 != .importer && $0 != .papers }

    /// The room a sidebar row or menu item stands for: Stocks is lit for its films and its papers.
    func listed(as room: Workspace) -> Bool { self == room || (room == .films && self == .papers) }
}

/// The lab's three parts, chosen in the title band's selector (⌘1, ⌘2, ⌘3): the Library (import, the contact
/// sheet, Archives, Boxes), the Lab (development, recipes, stocks) and Print (export). The contact sheet belongs to
/// the Library and to the Lab alike: from Develop one key (G) or a click on Lab shows it without leaving the Lab.
enum LabPart: String, CaseIterable, Identifiable, Sendable {
    case library, lab, print
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .lab: "Lab"
        case .print: "Print"
        }
    }

    /// The part's pictogram in the selector: the prints, the developing tank, the enlarger.
    var glyph: LabGlyph {
        switch self {
        case .library: .prints
        case .lab: .tank
        case .print: .enlarger
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    var key: String { String((LabPart.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// The part's rooms, as the sidebar lists them on top.
    var rooms: [Workspace] {
        switch self {
        case .library: [.importer, .contactSheet]
        case .lab: [.develop, .compare, .recipes, .films]
        case .print: [.print]
        }
    }

    /// The room a part opens on the first time.
    var firstRoom: Workspace {
        switch self {
        case .library: .contactSheet
        case .lab: .develop
        case .print: .print
        }
    }

    /// The part a room belongs to; nil for the contact sheet, which is the Library's and the Lab's.
    static func of(_ room: Workspace) -> LabPart? {
        switch room {
        case .library, .importer: .library
        case .develop, .compare, .recipes, .films, .papers: .lab
        case .print: .print
        case .contactSheet: nil
        }
    }

    var help: String {
        switch self {
        case .library: "Library: import, the contact sheet, Archives and Boxes (⌘1)"
        case .lab: "Lab: develop, recipes and stocks (⌘2). G, or a click here, switches between Develop and the contact sheet"
        case .print: "Print: export the photographs (⌘3)"
        }
    }
}

/// How the contact sheet is laid out and worked on. Kept between launches.
struct SheetOptions: Codable, Equatable, Sendable {
    /// `grid` is the editor's own sheet: the photographs side by side at their proportions, no film.
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
    /// Qlick Lab: the red pencil's rings and crosses hidden from view (View › Pencil Marks); the marks stay on the
    /// photographs, and the Picks and Rejects filters keep finding them. Optional so options saved before read as shown.
    var hideMarks: Bool? = nil
    var showMarks: Bool {
        get { hideMarks != true }
        set { hideMarks = newValue ? nil : true }
    }

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

/// What Qlick Lab keeps round the editor: which room is open, the projects, and the contact sheet's state.
/// The photographs, their marks, their developments and the selection stay the editor's (`EditorModel`), so every
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
    /// The part chosen in the title band's selector; the sidebar lists its rooms on top.
    private(set) var part = LabPart.lab
    /// The room each part was last in, to come back to it.
    @ObservationIgnored private var lastRoom: [LabPart: Workspace] = [:]
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
    /// Qlick Lab: one card of information on the sheet (`KeywordsPanel`: label, title, caption, keywords, the frame's
    /// facts), as Develop's (⌘I): the words are kept with the facts, not in a panel of their own.
    var wordsVisible: Bool {
        get { sheet.showInfo }
        set { sheet.showInfo = newValue }
    }
    /// Moves when ⌘K asks for the Add Keyword field, which then takes the keys (`keywordFocusPending` until it has).
    var keywordFocus = 0
    @ObservationIgnored var keywordFocusPending = false
    /// The photographs laid side by side in Comparaison.
    var compare = CompareSetup()
    /// The print dialog of the contact sheet.
    var printing = false
    /// Qlick Lab: what the Library's overview (`LibraryHome`) shows first: the Archives, or the Boxes.
    enum Overview: Sendable { case archives, boxes }
    var overview: Overview?
    /// Moves each time the overview is asked for, so it scrolls even to the part it shows already.
    var overviewStamp = 0

    /// The Archives' or the Boxes' entry: the overview of everything they hold, grouped into Rolls and Boxes.
    func showOverview(_ part: Overview) {
        overview = part
        overviewStamp += 1
        show(.library)
    }
    /// Print › Show out-of-gamut: the photograph's colours the output space can't hold, marked in cyan (`Gamut`).
    var showGamut = UserDefaults.standard.bool(forKey: "qlick.showGamut") {
        didSet { UserDefaults.standard.set(showGamut, forKey: "qlick.showGamut") }
    }
    /// The last colour check of the open photograph (marks, share out, its colours on the xy diagram).
    var gamutCheck: Gamut.Check?
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
        if NSClassFromString("XCTestCase") == nil { projects.folders.start(); followReach() }
        model.canvasScale.contextMenu = { [weak self] point in self?.developCommands.menu(at: point) }
        projects.removedChanged = { [weak self] in self?.followRemoved($0) }
        setUpFinding()
    }

    // MARK: Disks that don't answer

    /// Qlick Lab: a disk that stops answering (a NAS gone away) is said once, and the lab carries on without it;
    /// when it answers again its Folders are counted again. A catalogue that couldn't open at launch is said too.
    private func followReach() {
        VolumeReach.stoppedAnswering = { [weak self] volume in
            self?.tellOnWindow(AppAlert(
                title: "“\(volume.lastPathComponent)” isn’t answering",
                detail: "The Mac says it has stopped answering: its server or the network is gone. Qlick Lab carries on without it, and its Folders and photographs show as away until it answers again. Nothing on it is changed.",
                buttons: [.init(title: "OK")]))
        }
        reach = NotificationCenter.default.addObserver(forName: VolumeReach.changed, object: nil, queue: .main) { [weak self] note in
            guard let volume = note.userInfo?["volume"] as? String, !VolumeReach.isSilent(volume) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for roll in self.projects.projects.flatMap(\.rolls) where roll.folder.hasPrefix(volume + "/") { self.projects.count(roll) }
            }
        }
        if let missed = CatalogList.missed {
            CatalogList.missed = nil
            if missed.silent { VolumeReach.said(missed.url.path) }
            let name = CatalogList.name(of: missed.url), disk = VolumeReach.volumeName(of: missed.url.path)
            tellOnWindow(AppAlert(
                title: "The catalog “\(name)” couldn’t be opened",
                detail: (missed.silent ? "Its disk, “\(disk)”, isn’t answering." : "It isn’t there: its disk, “\(disk)”, may not be connected.")
                    + " The Default Catalog is open meanwhile: File › Open Recent Catalog opens “\(name)” once its disk is back, and the next launch tries it first.",
                buttons: [.init(title: "OK")]))
        }
    }

    /// Says it on the lab's window once the window is shown (at launch it isn't yet), within five seconds.
    private func tellOnWindow(_ alert: AppAlert) {
        Task { [model] in
            for _ in 0..<50 {
                if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.tell(alert)
        }
    }
    @ObservationIgnored private var reach: NSObjectProtocol?

    // MARK: Rooms

    /// Opens a room, bringing the editor to the state it needs: the sheet works on the folder as the editor's grid
    /// does (rating and edit commands act on the selection), developing on one photograph.
    /// `part` says which part the contact sheet opens in (the Library's or the Lab's); by default the one chosen.
    func show(_ next: Workspace, in chosen: LabPart? = nil) {
        guard !model.cropping || next == .develop else { NSSound.beep(); return }
        loupe = nil
        switch next {
        case .contactSheet:
            if model.source != nil, model.mode != .grid { model.showGrid() }
        case .develop, .print:
            if model.mode == .grid { model.editCurrent() }
            // Qlick Lab: Print with nothing open opens the frame in hand on the contact sheet (or the first), so it
            // always shows a photograph to print.
            else if next == .print, model.source == nil, let frame = model.selection.current ?? model.shownPhotos.first?.url { model.open(frame) }
        default: break
        }
        seenMode = model.mode
        if next == .library { projects.sidecars = model.sidecarLookup?.store; projects.countAll() }
        if next == .importer { importer.refreshVolumes() }
        // Qlick Lab: Compare opened from anywhere (its sidebar row, the menu, a key) takes the photographs selected,
        // as the sheet's Compare does; with one or none selected, what it compared before stays.
        if next == .compare, workspace != .compare, compare.kind == .photographs {
            let selected = comparedSelection()
            if selected.count >= 2 && (model.selection.selected.count >= 2 || compare.items.isEmpty) { compare.items = selected }
        }
        if workspace != next { workspace = next }
        // The contact sheet stays in the part it was opened from (the Library's or the Lab's); from Print, the Library's.
        let nextPart = LabPart.of(next) ?? chosen ?? (part == .print ? .library : part)
        if part != nextPart { part = nextPart }
        lastRoom[nextPart] = next
        notePlace(Place(workspace: next, folder: model.library.directory?.labStandardized))
    }

    /// The selector's segments (and ⌘1, ⌘2, ⌘3): the part's room as it was left. Lab again, when it's already
    /// chosen, switches between Develop and the contact sheet.
    func choose(_ next: LabPart) {
        guard !model.cropping else { NSSound.beep(); return }
        if next == part {
            if next == .lab { toggleSheet() }
            return
        }
        if next == .library, workspace == .contactSheet {
            part = .library
            lastRoom[.library] = .contactSheet
            return
        }
        // Qlick Lab: from the Lab or Print, the Library opens on the photograph in hand: the contact sheet of the
        // Folder, Box or Archive it was opened from, the photograph lit and scrolled into view (the sheet reveals
        // the current frame), wherever the Library was left (its overview, Import).
        if next == .library, model.source != nil, !model.sourceDeleted, workspace == .develop || workspace == .print {
            show(.contactSheet, in: .library)
            return
        }
        show(lastRoom[next] ?? next.firstRoom, in: next)
    }

    /// One key (G) between Develop and the contact sheet, in the part chosen.
    func toggleSheet() {
        show(workspace == .contactSheet ? .develop : .contactSheet)
    }

    /// Follows the editor when it changes between one photograph and the folder by itself (G, Esc, a double-click).
    func follow(mode: LibraryMode) {
        guard mode != seenMode else { return }
        seenMode = mode
        if mode == .grid, workspace == .develop { workspace = .contactSheet; lastRoom[part] = .contactSheet }
        // From Print, the contact sheet is the Library's.
        if mode == .grid, workspace == .print { workspace = .contactSheet; part = .library; lastRoom[.library] = .contactSheet }
        if mode == .photo, workspace == .contactSheet {
            workspace = .develop
            if part != .lab { part = .lab }
            lastRoom[.lab] = .develop
        }
        notePlace(place)
    }

    // MARK: Where the lab is

    /// The list open on the sheet, if one is: a whole Archive, a Folder with those under it, a Box, a Roll.
    var openView: LabView? { projects.view(of: model.library.directory) }
    /// Qlick Lab: the place the sidebar lights: the one open, unless the Library's overview of the Archives or the
    /// Boxes is in front (then its entry is the one lit). One entry lit at a time.
    var litView: LabView? { workspace == .library ? nil : openView }

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
        else if let directory = model.library.directory, !PhotoFolder.isList(directory) { path = directory.labStandardized.path }
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

    var place: Place { Place(workspace: workspace, folder: model.library.directory?.labStandardized) }
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

    /// Back and Forward start again: another catalogue's places lead nowhere in this one.
    func forgetPlaces() {
        places = []; placeIndex = -1
        placesChanged += 1
    }

    func goBack() { if canGoBack { walk(to: placeIndex - 1) } }
    func goForward() { if canGoForward { walk(to: placeIndex + 1) } }

    private func walk(to index: Int) {
        guard !model.cropping else { NSSound.beep(); return }
        let target = places[index]
        walking = true
        defer { walking = false }
        if let folder = target.folder, folder != model.library.directory?.labStandardized {
            // A list is listed again (its Box may have changed since); a list whose Box went is skipped.
            if let view = projects.view(of: folder) { projects.viewFolder(for: view) }
            let gone = folder.path.hasPrefix(projects.directory.appendingPathComponent("Views").path + "/") && projects.view(of: folder) == nil
            guard !gone, PhotoFolder.isList(folder) || VolumeReach.exists(folder.path) else {
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
            let folders = projects.photoFolders(of: project).filter { !others.contains($0.labStandardized.path) }
            // What's open of it closes: its contact sheet, its photograph, and a list (All Photographs, a day…) left
            // with nothing of the catalogue's in it.
            let showing = workingArchive?.id == project.id
            if showing { model.closeFolder() }
            previewBuilder.cancel(); proxyMaker.cancel()
            projects.remove(project.id)
            closeWhatLeftTheCatalog(gone: project.rolls.map { URL(fileURLWithPath: $0.folder, isDirectory: true) })
            if showing || workspace == .contactSheet || workspace == .develop { show(.library) }
            // The cache and the import's memory, off the main thread: a disk on the network answers slowly.
            importer.ledger.forget(folders: Set(folders.map { $0.labStandardized.path }))
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

    /// What's open that the catalogue no longer holds closes: a list of its own left empty or naming what's gone,
    /// another catalogue's list, a folder (or a photograph open alone) of the Archive just removed (`gone`, its
    /// folders) that no other Archive holds. A folder opened by hand from the disk stays.
    func closeWhatLeftTheCatalog(gone: [URL] = []) {
        let gonePaths = gone.map { $0.labStandardized.path }
        func wasGone(_ folder: URL) -> Bool {
            let path = folder.labStandardized.path
            guard projects.place(of: path) == nil else { return false }
            return !projects.isOpen || gonePaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        if let directory = (model.libraryRoot ?? model.library.directory)?.labStandardized {
            let views = projects.directory.appendingPathComponent("Views", isDirectory: true).labStandardized.path
            if PhotoFolder.isList(directory) || directory.path.hasPrefix(views + "/") {
                guard projects.isOpen, directory.path.hasPrefix(views + "/"), let view = projects.view(of: directory) else {
                    model.closeFolder(); return
                }
                if view.holder != nil { return libraryChanged() }
                let sources = PhotoFolder.sources(ofList: projects.viewFolder(for: view)) ?? []
                if sources.isEmpty { model.closeFolder() } else { model.library.refreshNow() }
            } else if wasGone(directory) {
                model.closeFolder()
            }
        } else if let source = model.source, wasGone(source.deletingLastPathComponent()) {
            model.forgetPhotograph()
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
        case .box(let id):
            // A Box always opens: its shelf of Boxes and Rolls, its own photographs, or what to put in it.
            guard projects.box(id) != nil else { return }
        case .roll:
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
        if model.library.directory?.labStandardized.path == folder.labStandardized.path { model.library.refreshNow() }
        open(folder: folder)
    }

    /// Opens a Folder on its contact sheet.
    func open(_ roll: LabRoll, in project: LabProject) {
        guard let folder = projects.resolve(roll, in: project.id) else {
            // Qlick Lab: offered at once, where it can be put right: Locate Folder.
            let offline = VolumeReach.offline(roll.folder)
            let why = offline ? "Its disk, “\(VolumeReach.volumeName(of: roll.folder))”, \(VolumeReach.isSilent(roll.folder) ? "isn’t answering" : "isn’t connected")."
                : "It may have been moved or renamed."
            Task { [weak self] in
                guard let self else { return }
                let answer = await self.model.ask(AppAlert(
                    title: "The folder “\(roll.name)” is \(offline ? "offline" : "not found")",
                    detail: why + " If a copy of it is elsewhere, Locate Folder points the Archive there; its Boxes and Rolls follow.",
                    buttons: [.init(title: "Locate Folder…"), .init(title: "Cancel", role: .cancel)]))
                if answer.button == 0 { self.locateFolderPanel(roll.folder, archive: project.id) }
            }
            return
        }
        open(folder: folder)
    }

    func open(folder: URL) {
        guard !model.cropping else { NSSound.beep(); return }
        loupe = nil
        if model.library.directory?.labStandardized.path != folder.labStandardized.path || model.source == nil {
            // A whole project or a selection is a list of photographs, not a folder on disk.
            if PhotoFolder.isList(folder) {
                // A Box opens even with no photographs of its own: its shelf shows what it holds.
                let box: Bool = { if case .box? = projects.view(of: folder) { return true }; return false }()
                model.openList(folder, allowEmpty: box)
            } else {
                model.open(folder)
            }
        } else if model.mode != .grid {
            model.showGrid()
        }
        seenMode = model.mode
        workspace = .contactSheet
        notePlace(Place(workspace: .contactSheet, folder: folder.labStandardized))
    }

    /// Folders dropped on the window or chosen in the panel: Folders of `project`, or of a new Archive that asks its name.
    func importFolders(_ urls: [URL], into project: UUID? = nil) {
        // No catalogue open: nothing can join one (the window asks for one first).
        guard projects.isOpen else { return NSSound.beep() }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        // A photograph dropped alone opens.
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

    func newArchive() {
        guard projects.isOpen else { return NSSound.beep() }
        naming = Naming(kind: .archive, name: projects.uniqueName("New Archive"))
    }

    func importPanel(into project: UUID? = nil) {
        guard projects.isOpen else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.title = "Import a Folder"
        panel.message = "Choose a folder of photographs. Import opens on it: copy it, move it, or leave it where it is."
        panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        LabPanel.begin(panel) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.importFolders(panel.urls, into: project) }
        }
    }

    // MARK: The sheet's marks

    /// The photographs the sheet shows, as the editor's grid would.
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
        compare = CompareSetup(kind: .photographs, items: comparedSelection())
        show(.compare)
    }

    /// The photographs Compare lays side by side: those selected, or the one in hand and the next.
    func comparedSelection() -> [URL] {
        let order = model.shownPhotos.map(\.url)
        var items = model.selection.ordered(order)
        if items.count < 2, let current = model.selection.current ?? model.sourceItem, let index = order.firstIndex(of: current) {
            items = [current] + (order.indices.contains(index + 1) ? [order[index + 1]] : [])
        }
        return Array(items.prefix(CompareSetup.most))
    }

    // MARK: The Lab's shelf

    /// Favourite and hidden films, papers and recipes: one system (`LabShelf`), seen in every view.
    var shelf: LabShelf { model.shelf }

    /// A stock's kind on the shelf: a paper if the catalogue has a paper by that id, else a film.
    func shelfKind(stock id: String) -> LabShelf.Kind { model.papers.contains { $0.id == id } && !model.films.contains { $0.id == id } ? .paper : .film }

    func isFavourite(stock id: String) -> Bool { shelf.isFavourite(shelfKind(stock: id), id) }
    func toggleFavourite(_ stock: String) { shelf.toggleFavourite(shelfKind(stock: stock), stock) }
    func isHidden(stock id: String) -> Bool { shelf.isHidden(shelfKind(stock: id), id) }

    /// Hides a stock from the trays, menus and Compare, or shows it again; the tray's tiles follow.
    func setHidden(stock id: String, _ hide: Bool) {
        shelf.setHidden(shelfKind(stock: id), id, hide)
        model.pumpPreviews()
    }

    func isFavourite(recipe: PresetFile) -> Bool { shelf.isFavourite(.recipe, recipe.shelfID) }
    func toggleFavourite(recipe: PresetFile) { shelf.toggleFavourite(.recipe, recipe.shelfID) }
    func isHidden(recipe: PresetFile) -> Bool { shelf.isHidden(.recipe, recipe.shelfID) }
    func setHidden(recipe: PresetFile, _ hide: Bool) { shelf.setHidden(.recipe, recipe.shelfID, hide) }
}
