import Accelerate
import AppKit
import CoreVideo
import CryptoKit
import ImageIO
import IOSurface
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Observation tracks each property separately, so a finished render only
/// updates the canvas and status bar, and an edit doesn't redraw the canvas.
@MainActor @Observable final class EditorModel {
    /// The whole edit, for rendering, undo, and export. Views read the
    /// per-parameter accessors below, so an edit only invalidates its own row.
    var state = EditState() {
        didSet { publish() }
    }
    var film = EditState().film
    var paper = EditState().paper
    /// Settings › Limit preview to 12 MP. A preference, not an edit, so Undo
    /// and Reset Adjustments leave it; the edit state carries a copy so the
    /// render and its cache follow it.
    /// Qlick Lab: never chosen, it's on for a Mac with 8 GB of memory: a 60 MP photograph developed whole takes
    /// about 7 GB (measured), which such a Mac hasn't to give.
    var limitsPreview = UserDefaults.standard.object(forKey: "limitPreview") as? Bool ?? EditorModel.limitsPreviewByDefault {
        didSet {
            UserDefaults.standard.set(limitsPreview, forKey: "limitPreview")
            if !adoptingPreference { replaceState(state) }
        }
    }
    @ObservationIgnored var adoptingPreference = false
    nonisolated static func previewLimited(forMemory memory: UInt64) -> Bool { memory <= 8 << 30 }
    nonisolated static let limitsPreviewByDefault = NSClassFromString("XCTestCase") == nil
        && previewLimited(forMemory: ProcessInfo.processInfo.physicalMemory)
    /// Settings › Use less memory for export: grain channels one at a time.
    /// Only exports read it; previews always develop the channels together.
    var lowMemoryExport = UserDefaults.standard.bool(forKey: "lowMemoryExport") {
        didSet { UserDefaults.standard.set(lowMemoryExport, forKey: "lowMemoryExport") }
    }
    var border = BorderSettings()
    var crop = CropSettings()
    /// The crop being drawn; nil unless cropping.
    var cropSession: CropSession?
    /// The film border's frame, loaded from the engine's data folder.
    private(set) var filmTexture: CGImage?
    /// The 35mm strip for the film and the photograph's format, loaded while
    /// that border is chosen.
    private(set) var filmStrip: FilmStrip?
    private(set) var stocks: [Stock] = [] { didSet { shelf.adopt(stocks: stocks) } }
    var source: URL?
    /// The camera's facts for the caption over the photograph, read off the main actor.
    var photoFacts: PhotoFacts?
    /// The duplicate of `source` open (its sidecar variant); nil for the
    /// photograph itself.
    var sourceVariant: String?
    /// The open library item: `source`, or its duplicate (`URL.variant`).
    var sourceItem: URL? { source.map { file in sourceVariant.map(file.variant) ?? file } }
    /// The developed preview. Nil until the first render of `source` completes.
    var image: IOSurface?
    /// The unprocessed photograph, shown while the first render develops.
    var placeholder: CGImage?
    /// Its developed thumbnail, shown in the placeholder's place: the
    /// photograph as it will look, finished (cropped, turned, in its
    /// border), rather than the camera's own preview. From ctruett's fork.
    var standIn: CGImage?
    /// The film or paper tray, while it's open (IMPLEMENTATION.md §4.5, §5.1).
    var tray: TrayVisit?
    /// The tried stock's tile, enlarged on the canvas at once, until the
    /// develop of that edit is in (§5.1).
    var trialImage: CGImage?
    /// The tray and the names that open it: a click anywhere else keeps the
    /// stock being tried and closes the tray.
    @ObservationIgnored let trayHitAreas = NSHashTable<NSView>.weakObjects()
    /// The undeveloped photograph, shown in place of `image` while the
    /// Original button is held.
    var original: IOSurface?
    /// The tones of `image` within the crop; nil until it develops.
    var histogram: Histogram?
    /// The tone graph's curve for the current film, paper and settings
    /// (or the last ones, until the next arrives); nil while hidden.
    var toneCurve: ToneCurveData?
    /// The photograph's film exposure, from the last render.
    var filmHistogram: FilmHistogram?
    var waveform: Waveform?
    /// The developed preview's frame, uncropped, which the canvas lays out:
    /// the working frame, or less with the 12 MP limit.
    var imageSize = CGSize.zero
    /// The decoded source and the uncapped frame an export develops, from the
    /// last render; zero before one finishes.
    var sourceSize = CGSize.zero
    var workingSize = CGSize.zero
    /// The settled preview's linear fraction of the working frame, below 1
    /// when limited or larger than the display proxy. Temporary drag frames
    /// leave this unchanged so the Image Size notice doesn't resize the form.
    var previewScale = 1.0
    var placeholderSize = CGSize.zero
    var imageRotation = 0
    var isRaw = false
    /// The colour space the preview develops in: the one Save and Export
    /// last used, so editing shows the export's gamut and Fast export and
    /// Save Preview can keep the preview's own values.
    var previewSpace = SaveSettings.colorSpaces[SaveSettings.chosenSpace]
    /// Qlick Lab: Print › Proof. On (the default), the preview develops in the output colour space, so it shows only
    /// what a print in it holds; off, in ProPhoto RGB, the widest, as far as the screen shows.
    var proofing = UserDefaults.standard.object(forKey: "qlick.proofing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proofing, forKey: "qlick.proofing"); if proofing != oldValue { changed() } }
    }
    /// The space the preview develops in: the output's while proofing.
    var renderSpace: String { proofing ? previewSpace : SaveSettings.colorSpaces[SaveSettings.prophoto] }
    /// How the engine read the photograph's colours: the last render's
    /// `input_colour` (summary, automatic reading, warning).
    var inputColour: JSONValue = .null
    /// Whether the last render's RAW decoder can apply the camera's lens
    /// corrections to this photograph (`io.lens_correction`).
    var lensCorrectionSupported = false
    private(set) var ready = false
    var rendering = false
    var previewCurrent = false
    /// The shown preview is out of date, and the update is slow enough to mention.
    var showsActivity = false
    /// Why the latest edit couldn't be developed, said on the canvas over
    /// the last good preview (§4.14); nil when it could.
    var developFailure: String?
    var renderFailed: Bool { developFailure != nil }
    var saving = false
    var exporting = false
    var exportStarted = Date()
    /// A brightness solve is with the helper.
    var matchingBrightness = false
    /// A failed solve that trying again can't change: for the photograph
    /// (`inputs` nil, e.g. no camera preview) or for these match inputs.
    var brightnessMatchFailure: (generation: Int, inputs: JSONValue?, message: String)?
    /// Settings › Match new photographs to camera brightness: whether a new
    /// photograph starts with Prep › Match camera brightness on.
    var autoPlaceNewImages = UserDefaults.standard.object(forKey: "autoPlaceNewImages") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoPlaceNewImages, forKey: "autoPlaceNewImages")
            refreshUneditedLook()
        }
    }
    /// Enlarger › Shifts move.
    var filterLink = FilterLink(rawValue: UserDefaults.standard.string(forKey: FilterLink.key) ?? "") ?? .separate {
        didSet { UserDefaults.standard.set(filterLink.rawValue, forKey: FilterLink.key) }
    }
    static let newPhotoFilmKey = "newPhotoFilm"
    static let newPhotoPaperKey = "newPhotoPaper"
    /// Settings › New photographs, as chosen: nil until a choice is made.
    var chosenNewPhotoFilm = UserDefaults.standard.string(forKey: EditorModel.newPhotoFilmKey)
    var chosenNewPhotoPaper = UserDefaults.standard.string(forKey: EditorModel.newPhotoPaperKey)
    /// Settings › Save ratings and edits next to photos: each photograph's
    /// edits in its sidecar (`Sidecar.swift`). Off, nothing is remembered per
    /// photograph; sidecars already there stay untouched until it's on again.
    var sidecarsEnabled = UserDefaults.standard.object(forKey: "sidecars") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sidecarsEnabled, forKey: "sidecars")
            sidecarWrite?.cancel(); sidecarWrite = nil
            library.store = sidecarsEnabled ? sidecars : nil
            // Off, every photograph develops as new; on, once read.
            pumpThumbnails()
            // The photograph shown is saved from its next edit on.
            if sidecarsEnabled, let source, let restore = readSidecar(source, variant: sourceVariant) {
                photoSidecar = sidecarContext(for: source, restore: restore)
            } else if !sidecarsEnabled { photoSidecar = nil }
        }
    }
    /// Lab › Film format › Custom picked while the value is still a format's,
    /// so the slider stays. Opening a photograph and Reset Adjustments clear it.
    var customFilmFormat = false
    /// Shown in the alert sheet until it's answered (`AlertSheet`).
    var error: String? {
        didSet { if error != oldValue { errorAlert = error.map { AlertRequest(alert: .error($0)) { _ in } } } }
    }
    /// `error` as the alert sheet shows it.
    private(set) var errorAlert: AlertRequest?
    /// The questions waiting for the alert sheet.
    @ObservationIgnored let alerts = AlertQueue()
    var status = "Starting…"
    var filmstripVisible = UserDefaults.standard.object(forKey: "filmstripVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filmstripVisible, forKey: "filmstripVisible") }
    }
    /// View › Image Only (F): the photograph with its caption and label,
    /// and the strip, status line and inspector hidden (§11). Their own
    /// settings stay as they were, so leaving it brings back what showed.
    /// Only in the photograph view, and not remembered across launches.
    var imageOnly = false
    /// The strip and the inspector as shown now: as set, unless Image Only hides them.
    var stripShown: Bool { filmstripVisible && !imageOnly }
    var inspectorShown: Bool { inspectorVisible && !imageOnly }
    /// T is held: the photograph on the canvas is turned upside down, to
    /// judge its composition alone, as Cartier-Bresson read his contact
    /// sheets. Display only: nothing renders, saves or exports differently.
    var upsideDown = false
    /// Photo › Auto Advance: a rating, flag or label key moves on to the next photograph. Off until chosen.
    var advanceAfterRating = UserDefaults.standard.bool(forKey: "advanceAfterRating") {
        didSet { UserDefaults.standard.set(advanceAfterRating, forKey: "advanceAfterRating") }
    }
    /// Qlick Lab: the next mark moves on once, Auto Advance or not: ⇧ with a mark key.
    @ObservationIgnored var advanceOnce = false
    /// The brief note over the canvas after a rating or flag key.
    var libraryNote: LibraryNote?
    /// The edit view or the grid. Every launch starts in the edit view.
    var mode = LibraryMode.photo {
        // The sheet stays drawn while it folds back into the strip; the
        // window clears this once it has (`SheetFlight`).
        didSet { if oldValue == .grid, mode == .photo { sheetFolding = true } }
    }
    /// The grid is folding back into the strip (§4.6).
    var sheetFolding = false
    /// Grid thumbnails waiting while the grid opens or folds: a flyer is
    /// carrying them, or they fade in after.
    var sheetWaiting: Set<URL> = []
    /// Where the strip's frames and the grid's thumbnails are drawn, for
    /// the flight between them.
    @ObservationIgnored let places = ThumbnailPlaces()
    /// Each photograph's shape, for the strip's frames and the grid's rows.
    @ObservationIgnored let aspects = PhotoAspects()
    /// The selected photographs and the current one, which in the edit view
    /// is `source`. In the grid it moves without developing anything.
    var selection = LibrarySelection()
    /// The height of the grid's rows, in points (the sheet's Size).
    var gridCellSize = UserDefaults.standard.object(forKey: "gridThumbnailSize") as? Double ?? SheetLayout.defaultSize {
        didSet {
            let clamped = min(max(gridCellSize, SheetLayout.sizes.lowerBound), SheetLayout.sizes.upperBound)
            if clamped != gridCellSize { gridCellSize = clamped; return }
            UserDefaults.standard.set(gridCellSize, forKey: "gridThumbnailSize")
        }
    }
    /// The grid as laid out now, for moving up and down a row. Set by the sheet.
    @ObservationIgnored var gridLayout: SheetLayout?
    var inspectorVisible = true
    /// Which panel the inspector column shows, remembered across launches.
    var inspectorPane = InspectorPane(rawValue: UserDefaults.standard.string(forKey: "inspectorPane") ?? "") ?? .adjustments {
        didSet { UserDefaults.standard.set(inspectorPane.rawValue, forKey: "inspectorPane") }
    }
    var presets: [PresetFile] = []
    /// What the engine made of each listed file, by the file's identity.
    var presetStatus: [PresetFile: PresetStatus] = [:]
    /// Each readable preset file's text, for its thumbnail.
    @ObservationIgnored var presetTexts: [PresetFile: String] = [:]
    /// Each valid preset's RAW white balance, to make thumbnails that need
    /// their own RAW decode last.
    @ObservationIgnored var presetWhiteBalances: [PresetFile: JSONValue] = [:]
    /// While the engine checks preset files: their thumbnails wait, so the
    /// order (quick ones first) covers every preset.
    @ObservationIgnored var checkingPresets = 0
    /// The preset whose name is being edited in the list.
    var renamingPreset: URL?
    /// The preset applied last to each photograph this session, which the
    /// Presets pane rings (§4.12). By the photograph's item, so a duplicate
    /// has its own.
    var appliedPresets: [URL: URL] = [:]
    /// The preset applied last to the photograph on screen.
    var appliedPreset: URL? { sourceItem.flatMap { appliedPresets[$0] } }
    /// A preset New Preset just made: Escape while naming it removes it.
    @ObservationIgnored var unnamedPreset: URL?
    var zoomCommand = UUID()
    var fitImage = true
    /// Qlick Lab: the canvas's zoom, in screen pixels per photograph pixel, for the toolbar.
    var zoomShown: CGFloat = 0
    var recentFiles: [URL] = []
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored var defaults: JSONValue = .object([:])
    @ObservationIgnored var catalog: JSONValue = .null
    @ObservationIgnored var catalogRequest: Task<(Int, JSONValue), Error>?
    @ObservationIgnored var engine: EngineClient?
    @ObservationIgnored private(set) lazy var filmCacheRelease = FilmCacheRelease { [weak self] in self?.engine }
    @ObservationIgnored var exportJob: ExportJob?
    @ObservationIgnored var revision = 0
    @ObservationIgnored var sourceGeneration = 0
    /// The one brightness solve in flight; its completion looks again.
    @ObservationIgnored var matchTask: Task<Void, Never>?
    @ObservationIgnored var matchRequest: UUID?
    /// A settled preview rendered while the brightness match was pending:
    /// shown only if the match leaves the render as it is, so the canvas
    /// goes from the previous frame straight to the matched one.
    @ObservationIgnored var heldPreview: (revision: Int, generation: Int, show: () -> Void)?
    /// The open photograph's camera preview for its brightness match, read
    /// once while the helper first decodes it: the colour space the RAW
    /// declares for it (nil until asked; null when it declares none) and the
    /// preview itself. The file is the same for the whole generation.
    @ObservationIgnored var matchReference: (generation: Int, declared: JSONValue?, prepared: Task<CameraBrightnessReference.Prepared, Never>?)?
    /// Solved matches across photographs and launches (ticket 39).
    @ObservationIgnored var matchCache = BrightnessMatchCache.shared
    /// `BrightnessMatchCache.engineStamp` of the engine's paths, read once.
    @ObservationIgnored var matchEngine: (helper: URL, data: URL, stamp: String)?
    /// The photograph the helper decoded alone (for a match, or before the
    /// first frame), and its size from that decode.
    @ObservationIgnored var decodedFor: (generation: Int, size: CGSize)?
    /// What the canvas shows before the first frame: this generation's
    /// placeholder, at the photograph's size; `kept` when it's the
    /// photograph's kept last develop.
    @ObservationIgnored var placeholderFor: (generation: Int, kept: Bool)?
    /// The edit whose decode for a brightness match failed: it renders
    /// without the match, which then reports the error as a render would.
    @ObservationIgnored var matchDecodeFailed: FrameID?
    /// A discrete edit renders a canvas-size frame first, then the export-size
    /// one (`RenderStep.quick`). This is the edit whose quick frame is done
    /// (shown, held for the brightness match, or failed): its next render
    /// settles.
    @ObservationIgnored var quickStep: FrameID?
    /// The shown frame is the quick frame of this edit.
    @ObservationIgnored var quickFrame: FrameID?
    /// The helper's last output, when it's a settled render: the request
    /// without its post adjustments, which the helper applies to the kept
    /// output instead of rendering again. A quick frame would replace it,
    /// and a relaunched helper (`launch`) keeps none.
    @ObservationIgnored var helperOutput: (key: [String: JSONValue], launch: Int)?
    struct FrameID: Equatable { var revision: Int, generation: Int }
    #if DEBUG
    /// Each render sent to the helper, for tests.
    @ObservationIgnored var renderLog: [RenderStep] = []
    /// Runs as each render starts, before it looks at anything, for tests.
    @ObservationIgnored var willRender: (() -> Void)?
    func killHelperForTesting() { engine?.killHelperForTesting() }
    var holdingFrameForMatch: Bool { heldPreview != nil }
    /// Brightness matches solved by the helper (not found in `matchCache`), for tests.
    @ObservationIgnored var matchSolves = 0
    #endif
    @ObservationIgnored var renderID = 0
    /// The last render is at export size: saving it gives the same file as
    /// a Fast export, byte for byte.
    @ObservationIgnored var renderAtExportSize = false
    @ObservationIgnored var renderOnGPU = false
    /// The shown frame was rendered at canvas size while a slider moved;
    /// letting go renders the photograph at export size.
    @ObservationIgnored var showingInteractiveFrame = false
    @ObservationIgnored var showingCachedPreview = false
    /// Qlick Lab: the settled frame shown was developed at this many screen pixels to a photograph pixel
    /// (`RenderStep.screen`); nil when it's the whole photograph.
    @ObservationIgnored var screenFrameScale: CGFloat?
    @ObservationIgnored var zoomRender: Task<Void, Never>?
    /// Qlick Lab: zoomed in on a large photograph, only the part on screen is developed at its own pixels, and
    /// drawn over the screen's frame (`image`): a fraction of the whole photograph's time and memory. `rect` is
    /// where it lies in the photograph, in `imageSize`'s pixels from the top left.
    struct DetailFrame { let image: IOSurface; let rect: CGRect; let frame: FrameID }
    var detail: DetailFrame?
    /// The detail to draw: this photograph's. An edit's keeps showing over that edit's image until the next shows.
    var shownDetail: DetailFrame? { detail.flatMap { $0.frame.generation == sourceGeneration && original == nil ? $0 : nil } }
    /// The edit `image` is the settled frame of, and the edit whose detail came as the whole photograph (its
    /// params read the whole frame: a diffusion filter, the highlight boost).
    @ObservationIgnored var baseFor: FrameID?
    @ObservationIgnored var noDetailFor: FrameID?
    @ObservationIgnored var panRender: Task<Void, Never>?
    /// Photographs under this many pixels are developed whole when zoomed in, as before.
    nonisolated static let detailMinimumPixels = 16_000_000.0
    /// The part asked for: what's on screen (fractions of the photograph) and a tenth of it more on every side,
    /// so a small pan stays inside it.
    nonisolated static func detailRegion(visible: CGRect) -> CGRect {
        visible.insetBy(dx: -visible.width * 0.1, dy: -visible.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    /// Whether a detail at `rect` (the photograph's pixels) has all of `visible` (fractions of it), to a pixel.
    nonisolated static func detailCovers(_ rect: CGRect, visible: CGRect, photo: CGSize) -> Bool {
        let wanted = CGRect(x: visible.minX * photo.width, y: visible.minY * photo.height,
                            width: visible.width * photo.width, height: visible.height * photo.height)
        return rect.insetBy(dx: -1, dy: -1).contains(wanted)
    }
    /// What's on screen now is in the detail shown for the current edit.
    var detailCurrent: Bool {
        guard let detail, detail.frame == FrameID(revision: revision, generation: sourceGeneration),
              let visible = canvasScale.visiblePhotoRect else { return false }
        return Self.detailCovers(detail.rect, visible: visible, photo: imageSize)
    }
    /// Qlick Lab › Réglages: edits develop as many pixels as the canvas shows, and the whole photograph only
    /// when it's zoomed in. Off in the older tests, which expect its export-size frames.
    var fastPreview = NSClassFromString("XCTestCase") == nil && (UserDefaults.standard.object(forKey: "qlick.fastPreview") as? Bool ?? true) {
        didSet {
            UserDefaults.standard.set(fastPreview, forKey: "qlick.fastPreview")
            if oldValue != fastPreview, ready, source != nil, !closing { previewCurrent = false; scheduleRender() }
        }
    }
    @ObservationIgnored let previewCache: RenderedPreviewCache
    @ObservationIgnored let canvasScale = CanvasScale()
    @ObservationIgnored var pendingRender: Task<Void, Never>?
    @ObservationIgnored var activityTimer: Task<Void, Never>?
    @ObservationIgnored var interactionStart: EditState?
    /// The last border colour change, which the next one to the same colour
    /// joins if nothing else changed in between.
    @ObservationIgnored var lastColorEdit: (setting: WritableKeyPath<BorderSettings, BorderColor>, state: EditState, at: Date)?
    @ObservationIgnored var closing = false
    @ObservationIgnored var explicitOpenRequested = false
    /// The session restored at launch and what restoring it replaced, until
    /// the helper's catalog confirms it. `discardLaunchRestore()` goes back.
    @ObservationIgnored var launchRestore: (session: EditorSession, before: LaunchRestoreBaseline)?
    struct LaunchRestoreBaseline {
        var state: EditState, inspectorVisible: Bool, fitImage: Bool, status: String, recentFiles: [URL]
    }
    /// True until `finishLaunching`: Finder's open arrives after the restore
    /// at launch, and the photograph it opens must not take the previous
    /// session's edits, as before restoring early.
    @ObservationIgnored var launching = true
    @ObservationIgnored var restoringAtLaunch = false
    /// The saved frame being read for the session restored at launch.
    @ObservationIgnored var launchFrame: (frame: LaunchFrame, generation: Int, rendered: EditState)?
    @ObservationIgnored var parameters: [String: ObservedParameter] = [:]
    @ObservationIgnored var stripRequest: (film: String, format: FilmFormat)?
    @ObservationIgnored var histogramRequest = 0
    @ObservationIgnored var toneGraphsShown = 0
    @ObservationIgnored var toneCurveTask: Task<Void, Never>?
    @ObservationIgnored var toneCurveStale = false
    /// The source's original, decoded on first use and kept until another
    /// photograph opens. Volatile while hidden.
    @ObservationIgnored var originalCache: IOSurface?
    @ObservationIgnored var originalLoad: Task<Void, Never>?
    /// The Original button is held; `original` is nil until its decode finishes.
    var holdingOriginal = false
    /// Qlick Lab: zoomed in on the original, the part on screen at the photograph's own pixels, drawn over it as
    /// `detail` is over the developed image. `rect` is in `imageSize`'s pixels from the top left.
    struct OriginalDetail { let image: IOSurface; let rect: CGRect; let generation: Int }
    var originalDetail: OriginalDetail?
    @ObservationIgnored var originalDetailLoad: Task<Void, Never>?
    /// The original's detail to draw: this photograph's, while the original shows.
    var shownOriginalDetail: OriginalDetail? { original != nil ? originalDetail.flatMap { $0.generation == sourceGeneration ? $0 : nil } : nil }

    /// The stocks and defaults are known, from the helper or the last launch's
    /// catalog. Edits are possible; rendering waits for `ready`.
    var hasCatalog: Bool { !stocks.isEmpty }
    var films: [Stock] { stocks.filter { !$0.paper } }
    var papers: [Stock] { stocks.filter(\.paper) }
    /// The films the menus and the tray list: those not hidden on the Lab's shelf (`LabShelf`).
    /// A hidden film in use stays listed, so a menu always shows its choice:
    /// the photograph's, and while the tray is open the one it opened on.
    var listedFilms: [Stock] { listedFilms(keeping: [film, tray?.before.film].compactMap { $0 }) }
    func listedFilms(keeping kept: [String]) -> [Stock] {
        films.filter { !shelf.isHidden(.film, $0.id) || kept.contains($0.id) }
    }
    /// The papers the menus and the tray list, as `listedFilms`.
    var listedPapers: [Stock] { listedPapers(keeping: [paper, tray?.before.paper].compactMap { $0 }) }
    func listedPapers(keeping kept: [String]) -> [Stock] {
        papers.filter { !shelf.isHidden(.paper, $0.id) || kept.contains($0.id) }
    }
    /// The recipes the menus, the panels, Compare and Import list: those not hidden on the shelf.
    var listedPresets: [PresetFile] { presets.filter { !shelf.isHidden(.recipe, $0.shelfID) } }
    var filmGroups: [StockGroup] { StockGroup.films(listedFilms, papers: papers) }
    var paperGroups: [StockGroup] { StockGroup.papers(listedPapers) }
    var filmName: String { films.first { $0.id == film }?.name ?? film }
    var paperName: String { papers.first { $0.id == paper }?.name ?? paper }
    var canSave: Bool { previewCurrent && image != nil && !rendering && !saving && !cropping && !showsHalationMask && !imageIsMask }
    /// The frame shown was developed as Halation's mask: never kept as a thumbnail, a kept develop or a file.
    @ObservationIgnored var imageIsMask = false
    /// Qlick Lab: Halation › Show mask: the open photograph shows the halation alone, on black. Only shown: never
    /// in its edits, its thumbnail, a saved preview or an export.
    var halationMask = false {
        didSet { if halationMask != oldValue { changed(invalidateCache: false) } }
    }
    /// The mask shows while the halation is on: not on a scanned negative printed with no film, which has none.
    var showsHalationMask: Bool {
        halationMask && state.params["film_render.halation.active"].bool && !(state.params["io.no_film"].bool && !state.params["io.scan_film"].bool)
    }
    var cropping: Bool { cropSession != nil }
    var canShowOriginal: Bool { image != nil && !cropping }
    /// The shown photograph's size after cropping, before rotation; zero
    /// before one opens. Borders fit this size.
    var photoSize: CGSize { crop.size(of: image != nil ? imageSize : placeholderSize) }
    var imageSizeMode: ImageSize.Mode { ImageSize.mode(of: state.params) }
    /// The frame the current edit develops at, uncapped, projected from the
    /// source like the helper resolves it; zero until the source's size is known.
    var projectedWorkingSize: CGSize {
        sourceSize == .zero ? .zero : ImageSize.working(source: sourceSize, params: state.params, crop: crop)
    }
    /// The exported photograph, cropped, before rotation, borders and export
    /// reductions; zero until the source's size is known.
    var photographSize: CGSize { crop.size(of: projectedWorkingSize) }
    /// The current edit asks for more working pixels than the helper develops.
    var imageSizeError: String? {
        let working = projectedWorkingSize
        return ImageSize.exceedsLimit(working: working, source: sourceSize) ? ImageSize.limitMessage(working: working) : nil
    }
    /// The developed photograph as shown, uncropped, after rotation.
    var shownImageSize: CGSize { imageRotation % 2 != 0 ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize }
    /// A slider is being dragged; its edits share one undo step.
    var interacting: Bool { interactionStart != nil }

    @ObservationIgnored let presetLibrary: PresetLibrary
    /// Qlick Lab: applying a recipe also applies its Develop part, where it has one. Remembered.
    var recipesApplyDevelop = UserDefaults.standard.bool(forKey: "recipeAppliesDevelop") {
        didSet { UserDefaults.standard.set(recipesApplyDevelop, forKey: "recipeAppliesDevelop") }
    }
    /// The Develop part to apply with a recipe's text: nil when the box is off or the recipe has none.
    func recipeDevelop(_ text: String) -> RecipeDevelop? { recipesApplyDevelop ? RecipeDevelop.read(text) : nil }
    /// The Lab's shelf: favourite and hidden films, papers and recipes.
    @ObservationIgnored let shelf: LabShelf
    /// Film and paper preview grids (`Previews.swift`).
    @ObservationIgnored let previews: Previews
    /// Where photographs' sidecars are read and written; nil, none are.
    @ObservationIgnored let sidecars: SidecarStore?
    /// The open photograph's folder, with its photographs' ratings.
    @ObservationIgnored let library: PhotoLibrary
    /// The open photograph's sidecar; nil when it has none and gets none
    /// (sidecars off, no store).
    @ObservationIgnored var photoSidecar: PhotoSidecarContext?
    /// The write 1 s after the last edit.
    @ObservationIgnored var sidecarWrite: Task<Void, Never>?
    /// Folders whose sidecars couldn't be written, said once each.
    @ObservationIgnored var unwritableFolders: Set<URL> = []
    /// The edits of the last photograph left with edits, for Paste from Previous.
    @ObservationIgnored var previousEdits: EditState?
    /// What Copy Edits took, for Paste Edits.
    var copiedEdits: CopiedEdits?
    /// The undo target of changes to several photographs' sidecars, so that
    /// opening another photograph, which clears the per-photograph undo,
    /// keeps them.
    @ObservationIgnored let libraryUndo = LibraryUndoTarget()

    struct PhotoSidecarContext {
        var photo: URL
        var variant: String
        var defaultsVersion: Int
        /// `variant` was made up when it opened: the file's first variant
        /// is written, should another app have made one since.
        var variantIsNew: Bool
        /// The user's edits as the photograph opened (`userEdits`). One without
        /// saved edits gets them only once they change.
        var opened: EditState
        var editedAtOpen: Bool
        var exists: Bool
        /// The stored edits last read or sent; the same edits aren't written again.
        var written: JSONValue?
        /// Why it isn't written: unreadable, from a newer version, unwritable.
        var blocked: String?
        /// Its edits are read again once the catalog arrives; until then
        /// they aren't written. Ratings and flags are.
        var awaitingCatalog = false
        /// The film and paper it names that this version lacks, with what is
        /// shown instead; written back while that stays chosen.
        var missingFilm: (saved: String, shown: String)?
        var missingPaper: (saved: String, shown: String)?
        /// A schema 2 session's edits, written once launch has settled.
        var migrating = false
    }

    init(previewCache: RenderedPreviewCache = RenderedPreviewCache(), presetLibrary: PresetLibrary = PresetLibrary(),
         sidecars: SidecarStore? = SidecarStore.forApp) {
        self.previewCache = previewCache
        self.presetLibrary = presetLibrary
        let shelf = LabShelf.forApp()
        self.shelf = shelf
        previews = Previews(shelf: shelf)
        self.sidecars = sidecars
        let enabled = UserDefaults.standard.object(forKey: "sidecars") as? Bool ?? true
        library = PhotoLibrary(store: enabled ? sidecars : nil)
        recentFiles = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
        library.sidecarChanged = { [weak self] photo in self?.sidecarChangedOnDisk(photo) }
        canvasScale.changed = { [weak self] in
            guard let self else { return }
            self.canvasScaleChanged()
            // Qlick Lab: the zoom the toolbar shows, in whole hundredths.
            let shown = ((self.canvasScale.ratio ?? 0) * 100).rounded() / 100
            if shown != self.zoomShown { self.zoomShown = shown }
        }
        canvasScale.moved = { [weak self] in self?.canvasMoved() }
        canvasScale.loupeZoomed = { [weak self] fit in if let self, self.fitImage != fit { self.fitImage = fit } }
        canvasScale.picked = { [weak self] point in self?.pickWhiteBalance(at: point) }
        library.filterChanged = { [weak self] in self?.filterChanged() }
        library.looksChanged = { [weak self] in
            guard let self else { return }
            self.lab.previewBuilder.folderChanged()
            self.pumpThumbnails()
            self.aspects.read(self.library.items, around: self.sourceItem)
        }
        // Posted on any thread; delivered on the main queue. Qlick Lab: running hot counts as saving energy.
        powerStateObservers = MachineState.observe { [weak self] in self?.lowPowerMode = MachineState.shared.saving }
    }

    /// Starts the helper and asks for its catalog at once, so both load while
    /// AppKit builds the window. Call it before building the inspector: the
    /// last launch's catalog, if the helper is unchanged, fills in the stocks
    /// and defaults so the inspector's first frame is complete.
    func launch(paths: EnginePaths? = nil) {
        guard !closing, engine == nil else { return }
        do {
            let engine = try EngineClient(paths: paths ?? EnginePaths.locate())
            engine.label = "editor"
            self.engine = engine
            filmCacheRelease.watchMemoryPressure()
            catalogRequest = Task.detached { try await engine.request(["command": EngineCommand.catalog.json]) }
            let data = engine.paths.data
            Task.detached(priority: .utility) { [weak self] in
                let texture = BorderStyle.loadFilmTexture(data: data)
                await self?.setFilmTexture(texture)
            }
            if let cached = CatalogCache.load(for: engine.paths) { apply(catalog: cached) }
        } catch { report(error) }
    }

    /// Restores the previous session with the last launch's catalog, before
    /// the helper answers. False without a cached catalog or if the session
    /// doesn't fit it; `start` then restores it as before.
    func restoreAtLaunch(_ session: EditorSession) -> Bool {
        guard hasCatalog, launching, !ready, !explicitOpenRequested, !closing, source == nil else { return false }
        let before = LaunchRestoreBaseline(state: state, inspectorVisible: inspectorVisible, fitImage: fitImage, status: status, recentFiles: recentFiles)
        restoringAtLaunch = true
        defer { restoringAtLaunch = false }
        guard (try? restore(session)) != nil else { return false }
        launchRestore = (session, before)
        return true
    }

    /// Goes back to no photograph and the defaults, as before the restore at
    /// launch, so the caller continues as if it had never happened.
    func discardLaunchRestore() {
        guard let (_, before) = launchRestore else { return }
        launchRestore = nil; launchFrame = nil
        // Nothing of the undone restore is written to its sidecar.
        // A different catalog can arrive once the window is shown and the
        // restored photograph is being cropped, compared or edited.
        forgetPhotograph()
        state = withPreferences(before.state); inspectorVisible = before.inspectorVisible; fitImage = before.fitImage; status = before.status
        if recentFiles != before.recentFiles { recentFiles = before.recentFiles; saveRecents() }
        updateHistogram()
    }

    /// Qlick Lab: closes the open photograph and its folder, as when the lab has nothing open. Its edits are
    /// written to its sidecar first.
    func closeFolder() {
        guard !cropping else { return }
        flushSidecar()
        forgetPhotograph()
        libraryRoot = nil
        selection = LibrarySelection()
        library.close()
        mode = .grid
    }

    /// No photograph open, and nothing of the last one written to its sidecar.
    func forgetPhotograph() {
        endTray(keep: true)
        trialImage = nil
        photoSidecar = nil; sidecarWrite?.cancel(); sidecarWrite = nil
        sourceGeneration += 1
        imageIsMask = false
        photoFacts = nil
        source = nil; sourceVariant = nil; image = nil; placeholder = nil; standIn = nil; previewCurrent = false; developFailure = nil; screenFrameScale = nil; detail = nil
        imageSize = .zero; placeholderSize = .zero; sourceSize = .zero; workingSize = .zero; previewScale = 1
        showingCachedPreview = false; isRaw = false; inputColour = .null; lensCorrectionSupported = false
        interactionStart = nil; cropSession = nil
        original = nil; originalCache = nil; originalLoad?.cancel(); originalLoad = nil; holdingOriginal = false
        originalDetail = nil; originalDetailLoad?.cancel(); originalDetailLoad = nil
        imageOnly = false; upsideDown = false
        undoManager?.removeAllActions(withTarget: self)
    }

    func start(paths: EnginePaths? = nil, restoration: Task<EditorSession?, Error>? = nil) async {
        launch(paths: paths)
        let matches = matchCache
        Task.detached(priority: .utility) { matches.preload() }
        guard let request = catalogRequest, let engine else { return }
        catalogRequest = nil
        var restoration = restoration
        do {
            let (_, catalog) = try await request.value
            guard !closing else { return }
            guard catalog["protocol"].double == 1 else { throw EngineError(message: "The image engine version doesn't match this app. Rebuild the app bundle.") }
            // An unchanged catalog keeps edits made while the helper started.
            if catalog != self.catalog {
                // Applying a catalog resets the parameters, so a session
                // restored with the cached one is undone and restored under
                // this catalog, as without a cached one.
                if let (session, _) = launchRestore, source == session.source {
                    discardLaunchRestore()
                    restoration = Task { session }
                }
                apply(catalog: catalog)
                CatalogCache.save(catalog, for: engine.paths)
                // A photograph opened before this catalog: its edits under it.
                readoptSidecarEdits()
            }
            // The restore at launch stands: its open skipped the system's
            // recent documents while it could still be undone.
            if let (session, _) = launchRestore, source == session.source {
                NSDocumentController.shared.noteNewRecentDocumentURL(session.source)
            }
            launchRestore = nil
            // The engine and session file load concurrently. Apply the restored
            // parameters before ready/changed so no default render is wasted.
            if let restoration, !explicitOpenRequested {
                do {
                    if let session = try await restoration.value, !explicitOpenRequested, !closing {
                        try restore(session)
                    }
                } catch {
                    if !explicitOpenRequested { status = error.localizedDescription }
                }
            }
            guard !closing else { return }
            ready = true
            if source == nil, status == "Starting…" { status = "" }
            if source != nil { changed(invalidateCache: false) }
            // A schema 2 session's edits move to the photograph's sidecar now,
            // off the launch path.
            if photoSidecar?.migrating == true { flushSidecar() }
        } catch { if !closing { report(error) } }
    }

    func apply(catalog: JSONValue) {
        // The reset below is no edit: a write still waiting must not save it.
        sidecarWrite?.cancel(); sidecarWrite = nil
        self.catalog = catalog
        stocks = catalog["profiles"].array.map(Stock.init)
        defaults = catalog["defaults"]
        // The engine leaves lens correction off for params from before it, so
        // their crops keep their place; the app corrects every new edit.
        defaults[Self.lensCorrectionPath] = .bool(true)
        // Keep anything already applied to the photograph, such as its rotation.
        let rotation = state.params["io.rotate_cw"]
        var next = state
        next.params = defaults
        if rotation != .null { next.params["io.rotate_cw"] = rotation }
        if !films.contains(where: { $0.id == next.film }), let first = films.first { next.film = first.id }
        if !papers.contains(where: { $0.id == next.paper }), let first = papers.first { next.paper = first.id }
        PreviewRules.pairFilm(in: &next, stocks: stocks)
        state = next
        previews.update(stocks: stocks)
        scheduleToneCurve()
        refreshUneditedLook()
        // Qlick Lab: the presets from the start, for the right-click menus' Apply Preset wherever you are.
        Task { await refreshPresets() }
    }

    /// The look of every item without edits: what a new photograph opens
    /// with, so a new default film or paper, match setting or engine defaults
    /// make their thumbnails stale. Nil before the catalog.
    private(set) var uneditedLook: String?

    func refreshUneditedLook() {
        let look = hasCatalog ? Self.uneditedLook(of: plainState) : nil
        guard look != uneditedLook else { return }
        uneditedLook = look
        pumpThumbnails()
    }

    /// A hash of `state` as an unedited photograph's thumbnail develops it.
    /// Image Size and the output colour, which follow the previous
    /// photograph, don't change a thumbnail and are left out.
    nonisolated static func uneditedLook(of state: EditState) -> String? {
        var plain = userEdits(state)
        for path in [ImageSize.targetPath, "io.output_color_space", "io.output_cctf_encoding"] { plain.params[path] = .null }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(["unedited": plain]) else { return nil }
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func setFilmTexture(_ texture: CGImage?) { filmTexture = texture }

    /// Loads the 35mm strip when that border is chosen and the film or the
    /// photograph's format changes.
    func updateFilmStrip() {
        guard border.enabled, border.style == .film35, let format = FilmFormat(photoSize), let data = engine?.paths.data else { return }
        if let filmStrip, filmStrip.film == film, filmStrip.format == format { return }
        if let stripRequest, stripRequest == (film, format) { return }
        stripRequest = (film, format)
        let film = film
        Task.detached(priority: .userInitiated) { [weak self] in
            let strip = FilmStrip.load(data: data, film: film, format: format)
            await self?.setFilmStrip(strip, film: film, format: format)
        }
    }
    func setFilmStrip(_ strip: FilmStrip?, film: String, format: FilmFormat) {
        guard let stripRequest, stripRequest == (film, format) else { return }
        self.stripRequest = nil
        filmStrip = strip
        if strip == nil { error = "The 35mm border for \(filmName) couldn’t be loaded." }
    }

    /// The last drag or click that changed the edit: before and after.
    @ObservationIgnored var lastInteraction: (start: EditState, end: EditState)?
    /// Qlick Lab: the folder listed as the library instead of the open photograph's own (a whole project, its rolls
    /// together). Opening anything else lets it go.
    var libraryRoot: URL?
    /// The batch exporting now, or the last one until its failures are seen.
    var batch: BatchRun?
    @ObservationIgnored var batchJournalURL = BatchJournal.url
    /// The batch's helper, for Match camera brightness; quit when it ends.
    @ObservationIgnored var batchEngine: EngineClient?
    @ObservationIgnored var batchGeneration = 0
    /// Where edited thumbnails are kept; tests use their own.
    @ObservationIgnored var editedThumbnails = EditedThumbnailStore.shared {
        // Read already: the new store names its thumbnails with it too.
        didSet { if let thumbnailStamp { editedThumbnails.engineStamp = thumbnailStamp } }
    }
    /// Where photographs' last develops are kept, screen-sized; tests use their own.
    @ObservationIgnored var renderArchive = EditedThumbnailStore.renders {
        didSet { if let thumbnailStamp { renderArchive.engineStamp = thumbnailStamp } }
    }
    /// Qlick Lab: the kept develops of the next photographs in the direction of travel, read into memory ahead.
    @ObservationIgnored let renderAhead = RenderAhead()
    /// Qlick Lab: the way the photographs are being walked through, 1 forward or -1 back (`noteWalk`).
    @ObservationIgnored var walkDirection = 1
    /// The engine's identity, once read: until then only embedded previews show.
    var thumbnailStamp: String?
    /// Moves when an item's edited thumbnail is made, so its cells read it.
    var thumbnailVersions: [URL: Int] = [:]
    /// Items in the strip or grid now: developed first.
    @ObservationIgnored var thumbnailsOnScreen: Set<URL> = []
    /// Each item's look last checked for a thumbnail, and whether it had one.
    @ObservationIgnored var thumbnailsChecked: [URL: (look: String, present: Bool)] = [:]
    /// Looks that failed to develop this session, not tried again.
    @ObservationIgnored var thumbnailFailures: [URL: String] = [:]
    /// Low Power Mode is on: only the thumbnails on screen are developed, in
    /// one helper; the rest of the folder waits until it's off. Follows the
    /// Mac's setting (tests set it).
    @ObservationIgnored var lowPowerMode = MachineState.shared.saving {
        didSet {
            guard lowPowerMode != oldValue else { return }
            if lowPowerMode { stopSpareThumbnailEngines() } else { pumpThumbnails() }
        }
    }
    @ObservationIgnored var powerStateObservers: [NSObjectProtocol] = []
    /// The background helpers, started while there's work, by slot.
    @ObservationIgnored var thumbnailEngines: [Int: EngineClient] = [:]
    /// Each slot's thumbnail developing now, and its job.
    @ObservationIgnored var thumbnailsDeveloping: [Int: (item: URL, task: Task<Void, Never>)] = [:]
    /// Qlick Lab: the folder's thumbnails still to develop, as the pump last counted them (those developing too).
    var thumbnailsLeft = 0
    /// Qlick Lab: the thumbnails asked for (Build Thumbnails), in the order asked: developed before the rest of the
    /// folder, on screen or not, in Low Power Mode too.
    @ObservationIgnored var thumbnailsWanted: [URL] = []
    /// How many of those asked for are done, of how many.
    var thumbnailsAsked = (done: 0, total: 0)
    /// Qlick Lab: the folder whose thumbnails off screen were stopped: only those on screen are developed there
    /// until another folder opens or thumbnails are asked for.
    @ObservationIgnored var thumbnailsHeldIn: URL?
    /// Qlick Lab: work the lab does in the background that the sidebar shows, with how far it got.
    var backgroundWork: (title: String, done: Int, total: Int)?
    /// Qlick Lab: the recipe being applied to many photographs; a new one, Stop or an undo cancels it.
    @ObservationIgnored var applyTask: Task<Void, Never>?
    /// The scan for the next thumbnails to develop.
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailsPumpAgain = false
    @ObservationIgnored var thumbnailIdle: Task<Void, Never>?
    @ObservationIgnored var thumbnailGeneration = 0
    @ObservationIgnored var readingThumbnailStamp = false
    /// Moves when the cache is emptied: a scan from before finds nothing.
    @ObservationIgnored var thumbnailsEmptied = 0
    /// The grid cells' size, for reading ahead at it.
    @ObservationIgnored var gridThumbnailSize = PhotoThumbnails.Size.medium
    @ObservationIgnored var prefetchRound = 0
    @ObservationIgnored var prefetching: Task<Void, Never>?
    /// Qlick Lab: the photographs' own pictures being read ahead by Build Thumbnails, how many of how many.
    var embeddedRead = (done: 0, total: 0)
    @ObservationIgnored var embeddedTask: Task<Void, Never>?
    /// Where deleted photographs go.
    @ObservationIgnored var trash = PhotoTrash.system
    /// The open photograph was deleted while the grid showed. Leaving the
    /// grid opens its current photograph again, even if Undo put it back.
    var sourceDeleted = false
    /// The original is framed like the developed image only with the same lens correction.
    @ObservationIgnored var originalLensCorrection = false
    /// Seconds a pixel of a slider's frame takes on this Mac, kept for the next launch.
    @ObservationIgnored var dragSecondsPerPixel: Double? = {
        let kept = UserDefaults.standard.double(forKey: EditorModel.dragRateKey)
        return kept > 0 && NSClassFromString("XCTestCase") == nil ? kept : nil
    }()
    @ObservationIgnored lazy var dragLevel = Self.dragLevel(0, secondsPerPixel: dragSecondsPerPixel)
    @ObservationIgnored var balancePrepared = -1
    @ObservationIgnored var balanceTask: Task<Void, Never>?
    @ObservationIgnored var refineRender: Task<Void, Never>?
    var balancingPrint = false
    /// Whether the popover is open: it clears a finished batch when it closes.
    @ObservationIgnored var batchPopoverShown = false
    /// Shows the batch's popover under a view; set by the window controller.
    @ObservationIgnored var presentBatch: (NSView) -> Void = { _ in }
    /// The lab round the editor: rooms, projects, the contact sheet.
    @ObservationIgnored private(set) lazy var lab = LabState(model: self)
    @ObservationIgnored var labGenerations: [String: Int] = [:]
    @ObservationIgnored var labGeneration = 1_000_000
    /// Qlick Lab: how many photographs' edits are still being written (into DNGs, a fraction of a second each).
    var savingLeft = 0
    @ObservationIgnored var savingWatch: Task<Void, Never>?
}

/// One parameter's value, observed on its own.
@Observable final class ObservedParameter {
    var value: JSONValue
    init(_ value: JSONValue) { self.value = value }
}


/// The undo target of changes to several photographs (`EditorModel.libraryUndo`).
final class LibraryUndoTarget: NSObject {}
