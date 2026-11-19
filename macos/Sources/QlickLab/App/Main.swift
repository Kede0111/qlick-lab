import AppKit
import SwiftUI

/// AppKit runs the application, menus, window, and title bar; the canvas and
/// inspector inside the window are SwiftUI. A SwiftUI scene with the old
/// toolbar and inspector took about twice as long to show the window
/// (the upstream note native-macos-ui.md (docs/README.md), Startup).
@main enum QlickLabMain {
    static func main() {
        // Qlick Lab: `--qlick-icon <folder>` draws the app's icon set and quits (scripts/make_icon.sh).
        if let flag = CommandLine.arguments.firstIndex(of: "--qlick-icon"), CommandLine.arguments.indices.contains(flag + 1) {
            let artwork = CommandLine.arguments.indices.contains(flag + 2) ? URL(fileURLWithPath: CommandLine.arguments[flag + 2]) : nil
            do { try LabIcon.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), artwork: artwork) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            exit(0)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = ApplicationDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()
    let updates = UpdateController()
    private let sessions = SessionStore()
    private var menu: MainMenu?
    private var editor: EditorWindowController?
    private var terminating = false
    /// The quit questions are open in the alert sheet.
    private var askingToQuit = false
    /// Qlick Lab: the questions are answered and the last writes made (or given up): the next quit goes through.
    private var quitApproved = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The helper starts while AppKit builds the window, and the cached
        // catalog fills in the inspector's first frame. With that catalog the
        // session restores before the window is built, so its saved frame and
        // adjustments are in the window's first frames; the main actor's tasks
        // only run after AppKit's launch passes. Without a cached catalog, or
        // if the session isn't read within 0.1 s, it restores once the helper
        // answers and reports any error then. Benchmarks and explicit
        // launches must not reopen a previous photograph.
        #if DEBUG || SPEKTRAFILM_BENCHMARK
        LaunchBenchmark.begin(model)
        #endif
        // Newsreader is read on another thread while AppKit starts.
        Theme.Fonts.prepare()
        model.launch()
        let benchmark = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] != nil
        var store: SessionStore? = benchmark ? nil : sessions
        #if DEBUG || SPEKTRAFILM_BENCHMARK
        if let path = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_SESSION"] {
            store = SessionStore(file: URL(fileURLWithPath: path))
        }
        #endif
        var restoration: Task<EditorSession?, Error>?
        // The last photograph's sidecar is read with the session, a few kilobytes more.
        let sidecars = model.sidecarLookup
        if let store, Self.pathArgument != nil || !(Self.readSession(store, sidecars: sidecars, timeout: 0.1).map(model.restoreAtLaunch) ?? false) {
            restoration = Task { try await store.load(sidecars: sidecars) }
        }
        Task { await model.start(restoration: restoration) }
        menu = MainMenu(model: model, updates: updates)
        NSApp.mainMenu = menu?.menu
        editor = EditorWindowController(model: model)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Qlick Lab's automation runs without a Dock icon and never comes forward.
        NSApp.setActivationPolicy(LabAutomation.offscreen ? .accessory : .regular)
        // The saved frame has usually been read while AppKit built the
        // window; waiting briefly puts it in the window's first frame. A
        // Finder open may have undone the restore that titled the window.
        model.finishLaunching(waitingUpTo: 0.15)
        editor?.refresh()
        if LabAutomation.offscreen, let window = editor?.window {
            // All but a corner of two points is past the screen's lower right: the window
            // server still draws the whole window, which `screencapture -l` reads.
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            window.setFrame(NSRect(x: screen.maxX - 2, y: screen.minY + 2 - 920, width: 1480, height: 920), display: false)
            window.orderBack(nil)
        } else {
            editor?.showWindow(nil)
        }
        LabAutomation.start(model: model, window: editor?.window)
        #if DEBUG || SPEKTRAFILM_BENCHMARK
        LaunchBenchmark.windowShown()
        #endif
        if !LabAutomation.offscreen { NSApp.activate(ignoringOtherApps: true) }
        // Finder opens arrive through application(_:open:); a path argument is for `swift run`.
        if let path = Self.pathArgument { model.open(URL(fileURLWithPath: path)) }
        #if DEBUG || SPEKTRAFILM_BENCHMARK
        InteractionBenchmark.start(model)
        GridBenchmark.start(model)
        #endif
        updates.schedule(afterStartupOf: model)
        offerBatchResume()
    }

    /// An export the last session didn't finish is offered once launch has
    /// settled, as updates are: never on the launch path.
    private func offerBatchResume() {
        guard ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while let self, !Task.isCancelled {
                let model = self.model
                if model.ready && (model.source == nil || model.previewCurrent || model.renderFailed) || model.error != nil {
                    return model.offerBatchResume()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    /// The session, read on another thread and waited for at most `timeout`,
    /// so a photograph on an unresponsive volume never holds up launch. Nil
    /// if there's none, it can't be read, or it takes longer.
    private static func readSession(_ store: SessionStore, sidecars: SidecarLookup?, timeout: TimeInterval) -> EditorSession? {
        final class Result: @unchecked Sendable { var session: EditorSession? }
        let result = Result(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.session = try? store.read(sidecars: sidecars)
            done.signal()
        }
        // The semaphore orders the write before this read.
        return done.wait(timeout: .now() + timeout) == .success ? result.session : nil
    }
    private static var pathArgument: String? {
        CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Qlick Lab: a catalog opens as one.
        if let catalog = urls.first(where: { $0.pathExtension.lowercased() == CatalogList.fileExtension }) { return model.lab.openCatalog(catalog) }
        if let url = urls.first(where: \.isFileURL) { model.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Qlick Lab: what had to be asked and saved is done; this is the quit that follows.
        if quitApproved { return .terminateNow }
        // Saving already: Quit again shows what it waits for.
        if terminating { showSavingWait(now: true); return .terminateCancel }
        if model.saving || (updates.installing && model.exporting) || askingToQuit { return .terminateCancel }
        // A question already open is answered first.
        if model.alerts.shown != nil { NSSound.beep(); return .terminateCancel }
        let questions = quitQuestions()
        if questions.isEmpty, !needsSaving { return .terminateNow }
        // Qlick Lab: the questions and the last writes happen with the lab running as usual, and the lab quits by
        // itself once they're done. Never `.terminateLater`: AppKit then waits in a loop of its own, and when the
        // quit began on the main queue the work it waits for could never run (Quit greyed, the lab frozen).
        askingToQuit = true
        Task {
            for (alert, quit) in questions where await model.ask(alert).button != quit {
                askingToQuit = false
                return
            }
            askingToQuit = false
            await saveThenQuit()
        }
        return .terminateCancel
    }

    /// The editing session to keep at quit.
    private var needsSaving: Bool {
        model.session != nil && ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] == nil
    }

    /// What quitting now would stop, as questions in the alert sheet, each
    /// with the button that quits.
    private func quitQuestions() -> [(AppAlert, quit: Int)] {
        var questions: [(AppAlert, quit: Int)] = []
        if model.batchRunning, let remaining = model.batch?.journal.remaining, !updates.installing {
            // Kept in the journal: the next launch offers to resume.
            questions.append((AppAlert(
                title: "Export \(remaining == 1 ? "the remaining photograph" : "\(remaining) remaining photographs") next time?",
                detail: "Quitting stops the export. Files already exported stay; Qlick Lab offers to export the rest when it opens again.",
                buttons: [.init(title: "Quit"), .init(title: "Cancel", role: .cancel)]), 0))
        }
        // Qlick Lab: an import under way is kept in its journal.
        if let run = model.lab.importer.run, !run.finished, run.adding {
            let left = run.total - run.done
            questions.append((AppAlert(
                title: "Stop adding \(left == 1 ? "the last photograph" : "the \(left) remaining photographs")?",
                detail: "Those already added stay in the project with their marks. The others can be added again next time.",
                buttons: [.init(title: "Quit"), .init(title: "Cancel", role: .cancel)]), 0))
        } else if let run = model.lab.importer.run, !run.finished {
            let left = run.total - run.done
            questions.append((AppAlert(
                title: "Finish importing \(left == 1 ? "the last photograph" : "the \(left) remaining photographs") next time?",
                detail: "Quitting stops the import after the file being copied. Everything already copied stays, nothing on the source is touched, and Qlick Lab offers to import the rest when it opens again.",
                buttons: [.init(title: "Quit"), .init(title: "Cancel", role: .cancel)]), 0))
        }
        if model.exporting {
            questions.append((AppAlert(
                title: "An export is still in progress.",
                detail: "Quitting cancels it. Any existing file at the destination is left unchanged.",
                buttons: [.init(title: "Continue Exporting", role: .cancel), .init(title: "Quit")]), 1))
        }
        return questions
    }

    /// Save once at quit/relaunch, not on slider changes or the rendering path.
    /// A failed write cancels the quit instead of silently losing the
    /// session. The photograph's edits go to its sidecar first; one that
    /// can't be written was already reported and doesn't keep the lab open.
    private func saveThenQuit() async {
        guard let session = model.session, needsSaving else { return quit() }
        terminating = true
        // Qlick Lab: what works in the background stops first, so the last writes have the disks to themselves.
        model.lab.previewBuilder.cancel()
        model.lab.proxyMaker.cancel()
        model.lab.importer.stop()
        // Never a quit that waits without a word: after a moment it says what it waits for, and offers to quit now.
        let watch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.showSavingWait(now: false)
        }
        do {
            await model.flushSidecars()
            try await sessions.save(session)
            await model.flushPreviewCache()
            watch.cancel()
            model.alerts.withdraw(titled: Self.savingTitle, answering: 0)
            quit()
        } catch {
            watch.cancel()
            model.alerts.withdraw(titled: Self.savingTitle, answering: 0)
            guard !quitApproved else { return }
            terminating = false
            model.error = "Could not save the editing session. Qlick Lab stayed open. \(error.localizedDescription)"
        }
    }

    private static let savingTitle = "Qlick Lab is still saving."

    /// What a quit waits for, with Quit Now. `now`: asked again (a second Quit), not after the wait.
    private func showSavingWait(now: Bool) {
        guard terminating, !quitApproved, model.alerts.shown?.alert.title != Self.savingTitle else { return }
        let left = model.sidecars?.pendingCount ?? 0
        let detail = left > 0
            ? "The marks and edits of \(left == 1 ? "one photograph are" : "\(left) photographs are") still being written beside \(left == 1 ? "it" : "them"). On a network disk this can take a while.\n\nQuit Now leaves what isn’t written yet unsaved."
            : "The editing session is still being saved.\n\nQuit Now leaves it as it was saved last."
        Task {
            let answer = await model.ask(AppAlert(title: Self.savingTitle, detail: detail,
                                                  buttons: [.init(title: "Keep Waiting", role: .cancel), .init(title: "Quit Now", role: .destructive)]))
            if answer.button == 1 { quit() }
        }
    }

    private func quit() {
        guard !quitApproved else { return }
        quitApproved = true
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { updates.stop(); model.shutdown() }
}

/// The window's main column: the photograph, the drop target, and the status bar.
struct EditorCanvas: View {
    let model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        let grid = model.mode == .grid
        VStack(spacing: 0) {
            // Qlick Lab: Develop's tools (View › Show Toolbar).
            if model.lab.toolbarVisible, !grid, !model.imageOnly { DevelopToolbar(model: model) }
            // The grid's sheet covers it (`GridSheet`), so coming back to
            // the same photograph is instant and keeps its zoom.
            CanvasArea(model: model, dropping: dropTargeted)
                // Qlick Lab: the adjustments floating over the photograph on Liquid Glass (View › Floating Panel).
                .overlay(alignment: .topTrailing) { FloatingInspector(model: model, grid: grid) }
                // Qlick Lab: the photograph's metadata, on glass at the other corner (View › Photograph Information).
                .overlay(alignment: .topLeading) { PhotoInfoPanel(model: model, grid: grid) }
            // The tray takes the strip's and the status line's place (§4.5),
            // in Image Only too, which comes back when it closes.
            if let tray = model.tray, !grid {
                StockTray(model: model, visit: tray)
            } else if !dropTargeted, !model.imageOnly {
                VStack(spacing: 0) {
                    // It stays under the grid's sheet, which folds back into it.
                    if model.stripShown, model.source != nil {
                        PhotoBrowser(model: model)
                    }
                    // None in the empty window (§4.14).
                    if model.source != nil || model.exporting || model.batch != nil {
                        // No rule: strip and status line are 186 pt, the
                        // tray's height, so the photograph doesn't move (§2.3).
                        StatusBar(model: model)
                    }
                }
                // The leader rises from the strip's right end, or from the
                // status line's top edge with the strip hidden (§11). It
                // stands on that edge, over the canvas: an `alignmentGuide`
                // to its bottom was ignored and left it covering the frame.
                .overlay(alignment: .topTrailing) {
                    if model.source != nil, !grid, !model.cropping {
                        StripLeader(model: model).offset(y: -StripLeader.raised)
                    }
                }
            }
        }
        // Where the strip's frames report their places (`SheetFlight`).
        .coordinateSpace(.named(ThumbnailPlaces.space))
        // A photograph or a folder dropped anywhere on the column opens.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.open(url); return true
        } isTargeted: { dropTargeted = $0 }
        // Under the grid's sheet, hidden from VoiceOver too.
        .accessibilityHidden(grid)
        .modifier(LibraryNoteTimer(model: model))
        // The open photograph's folder is the library, listed once the
        // window is up and kept current while it stays open.
        .task(id: model.libraryFolder) {
            guard let folder = model.libraryFolder else { return }
            await model.library.watch(folder)
        }
    }
}

/// The inspector column: the adjustments, or the crop panel while cropping.
struct InspectorPanel: View {
    let model: EditorModel
    /// False until the window is on screen; see EditorWindowController.
    var built = true
    /// Qlick Lab: floating over the canvas, on glass.
    var floating = false

    var body: some View {
        ZStack(alignment: .top) {
            if floating { Color.black.opacity(0.28) } else { Theme.panel }
            if !built { Color.clear }
            else if let session = model.cropSession { CropInspector(model: model, session: session) }
            else {
                VStack(spacing: 0) {
                    // Qlick Lab: no Adjustments · Presets header: the presets open from the film card, and come
                    // back to Develop from their own header.
                    if model.inspectorPane == .presets { PresetsHeader(model: model); PresetInspector(model: model) }
                    // The sections aren't built until a photograph opens.
                    else if model.source == nil { InspectorEmptyLine() }
                    else { AdjustmentInspector(model: model) }
                }
            }
        }
        // With the divider's rule (`EdgeSplitView`), outlines the column
        // where it meets the title band (round 25 A).
        .overlay(alignment: .top) { if !floating { Theme.line.frame(height: 1).allowsHitTesting(false) } }
        .tint(Theme.paper)
        // Under the grid's sheet (§4.6).
        .accessibilityHidden(model.mode == .grid)
    }
}

/// The panel with no photograph: one line instead of its tabs (§4.14).
struct InspectorEmptyLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InkRule()
            Text("The film, the paper and every setting appear here once a photograph is open.")
                .font(Theme.serif(14, italic: true)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Size.gutter)
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

/// Reads only the preview state, so edits don't re-evaluate the canvas.
struct CanvasArea: View {
    let model: EditorModel
    /// While a file is dragged over the window, the photograph, caption and
    /// label step aside for a line round the print's place (§4.14).
    var dropping = false
    @State private var geometry = CanvasGeometry()
    /// The pointer is over the photograph, which brightens the trim marks.
    @State private var overPrint = false
    /// Settings › Photographs › Viewer.
    @AppStorage(ViewerSheet.key) private var sheet = ViewerSheet.darkroom

    /// Above the photograph, for the caption; below it, for the label's two rows (§2.3).
    nonisolated static let captionBand: CGFloat = 54
    nonisolated static let labelBand = PrintLabelLayout.band

    var body: some View {
        ZStack {
            sheet.color
            if let session = model.cropSession, let image = model.image {
                CropEditor(model: model, session: session, image: image)
            } else if model.source == nil, model.image == nil, model.standIn == nil, model.placeholder == nil {
                EmptyCanvas(model: model, dropping: dropping)
            } else {
                let failure = model.developFailure
                if failure == nil, !dropping { lightTable }
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.captionBand)
                    // Couldn't develop: the last develop, faded and greyed.
                    photograph
                        .grayscale(failure == nil ? 0 : 1)
                        .opacity(dropping ? 0 : failure == nil ? 1 : 0.12)
                    Color.clear.frame(height: Self.labelBand)
                }
                .overlay(alignment: .topLeading) {
                    if !dropping, model.image != nil || model.standIn != nil || model.placeholder != nil {
                        GeometryReader { proxy in marks(in: proxy.size) }
                    }
                }
                if dropping {
                    EmptyCanvas(model: model, dropping: true, print: shownPrint)
                } else if let failure {
                    DevelopFailure(name: model.sourceItem.map { model.library.name(of: $0) } ?? "The photograph",
                                   reason: failure, retry: model.retryDevelop)
                        .padding(.top, Self.captionBand).padding(.bottom, Self.labelBand)
                }
            }
        }
        .environment(\.sheetInk, sheet.ink)
        // On its own dark plate, so it reads on any sheet.
        .overlay(alignment: .topLeading) { developTag }
        .onContinuousHover { phase in
            let over: Bool
            if case .active(let point) = phase, let print = shownPrint { over = print.contains(point) } else { over = false }
            if over != overPrint { overPrint = over }
        }
    }

    /// The print's place on the canvas, once it's laid out.
    private var shownPrint: CGRect? {
        geometry.print.width > 0 ? geometry.print.offsetBy(dx: 0, dy: Self.captionBand) : nil
    }

    /// The border on screen, as `photograph` passes it to the preview.
    private var shownBorder: BorderSettings? {
        if model.original == nil, let trial = model.trialImage {
            return model.border.shown(for: Self.standInSize(trial, photo: model.photoSize))
        } else if model.image != nil {
            return model.border.shown(for: model.crop.size(of: model.imageSize))
        } else if model.standIn != nil {
            return nil
        } else if model.placeholder != nil {
            return model.border.shown(for: model.crop.size(of: model.placeholderSize))
        }
        return nil
    }

    /// A light under the print when its border's edge sinks into the sheet
    /// (`LightTable`). Fitted only: zoomed in, the print has no edges on screen.
    @ViewBuilder private var lightTable: some View {
        if !geometry.zoomed, let print = shownPrint,
           let light = LightTable.light(sheet: sheet.hex, edge: LightTable.edge(of: shownBorder)) {
            LightTableGlow(print: print, color: light)
        }
    }

    /// Developing or Updating, at the top centre of the photograph's visible part.
    @ViewBuilder private var developTag: some View {
        // Qlick Lab: a photograph's kept develop is a developed picture already: no big tag over it.
        let title = DevelopTagTitle.title(source: model.source != nil, failed: model.renderFailed,
                                          developed: model.image != nil || model.showsKeptRender, slow: model.showsActivity)
        ZStack {
            if let title, !dropping, !model.cropping {
                GeometryReader { proxy in
                    let canvas = CGRect(origin: .zero, size: proxy.size)
                    let visible = shownPrint.map { $0.intersection(canvas) } ?? CGRect(x: 0, y: Self.captionBand, width: proxy.size.width, height: 0)
                    if title == "Updating" {
                        // Qlick Lab: an edit's develop is said small, at the photograph's corner, not across it.
                        UpdatingMark()
                            .frame(width: max(visible.width - 20, 1), alignment: .trailing)
                            .offset(x: visible.minX + 10, y: visible.minY + 10)
                    } else {
                        DevelopTag(title: title)
                            .frame(width: max(visible.width, 1))
                            .offset(x: visible.minX, y: visible.minY + 16)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: title)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var photograph: some View {
        if model.original == nil, let trial = model.trialImage {
            // A tried stock's tile, enlarged at once until its develop is in (§5.1).
            let size = Self.standInSize(trial, photo: model.photoSize)
            PreviewCanvas(image: trial, size: size, rotation: 0, crop: CropSettings(), border: model.border.shown(for: size),
                          filmTexture: model.filmTexture, filmStrip: model.filmStrip, zoomCommand: model.zoomCommand, fit: model.fitImage,
                          scale: model.canvasScale, geometry: geometry, upsideDown: model.upsideDown,
                          doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) })
        } else if let image = model.image {
            canvas(model.original ?? image, size: model.imageSize, rotation: model.imageRotation)
        } else if let standIn = model.standIn {
            // Finished already: drawn as it is, the size the photograph will be.
            PreviewCanvas(image: standIn, size: Self.standInSize(standIn, photo: model.placeholderSize), rotation: 0, crop: CropSettings(),
                          border: nil, filmTexture: nil, filmStrip: nil, zoomCommand: model.zoomCommand, fit: model.fitImage,
                          scale: model.canvasScale, geometry: geometry, upsideDown: model.upsideDown,
                          doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) })
        } else if let placeholder = model.placeholder {
            canvas(placeholder, size: model.placeholderSize, rotation: model.imageRotation)
        } else {
            Color.clear
        }
    }

    /// The caption 10 pt over the print and the label under it, kept within
    /// the canvas's margins; zoomed in, they stay in their bands.
    @ViewBuilder private func marks(in size: CGSize) -> some View {
        let print = geometry.print.offsetBy(dx: 0, dy: Self.captionBand)
        if print.width > 0 {
            let margin = ImageScrollView.fitInset
            let left = max(print.minX, margin)
            let right = min(print.maxX, size.width - margin)
            let width = max(right - left, 1)
            let portrait = !geometry.zoomed && print.height > print.width
            PhotoCaption(facts: model.photoFacts, fileName: model.sourceItem.map { model.library.name(of: $0) } ?? "", portrait: portrait,
                         options: model.lab.caption)
                .frame(width: width, height: 40, alignment: .bottom)
                .offset(x: left, y: print.minY - 10 - 40)
            // Qlick Lab: the film and the paper are chosen in the panel (`StockPicker`), not under the photograph.
            // Not zoomed in: the corners are off the canvas then (§4.3).
            // Nor in Image Only, which crops nothing.
            if !geometry.zoomed, !model.imageOnly, model.image != nil, model.developFailure == nil {
                CropTrimMarks(print: print, lit: overPrint, crop: model.beginCrop)
            }
        }
    }

    /// The stand-in's layout size: its own shape (fitted, only that shows),
    /// with the long side of the photograph's placeholder once that's read,
    /// else 2048, as a RAW's.
    static func standInSize(_ image: CGImage, photo: CGSize) -> CGSize {
        let long = max(photo.width, photo.height) > 0 ? max(photo.width, photo.height) : 2048
        let scale = long / CGFloat(max(image.width, image.height, 1))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func canvas(_ image: AnyObject, size: CGSize, rotation: Int) -> some View {
        PreviewCanvas(image: image, size: size, rotation: rotation, crop: model.crop, border: model.border.shown(for: model.crop.size(of: size)), filmTexture: model.filmTexture,
                      filmStrip: model.filmStrip, zoomCommand: model.zoomCommand, fit: model.fitImage, scale: model.canvasScale, geometry: geometry,
                      upsideDown: model.upsideDown, settled: model.original != nil || model.showsSettledFrame,
                      detail: image === model.image ? model.shownDetail.map { ($0.image, $0.rect) }
                          : image === model.original ? model.shownOriginalDetail.map { ($0.image, $0.rect) } : nil,
                      doubleClick: { [model] in model.doubleClickPhotograph(zoomed: $0) })
    }
}

/// Qlick Lab: the adjustments as a pane of Liquid Glass over the canvas, as Pixelmator Pro's, so a zoomed photograph
/// runs on under it. The canvas fits the photograph in the space the pane leaves (`CanvasScale.trailingObstruction`).
struct FloatingInspector: View {
    let model: EditorModel
    let grid: Bool
    static let width: CGFloat = 352, margin: CGFloat = 10

    var body: some View {
        let shown = model.lab.floatingPanel && model.inspectorShown && !grid
        ZStack {
            if shown {
                InspectorPanel(model: model, floating: true)
                    .frame(width: Self.width)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .padding(Self.margin)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .onAppear { model.canvasScale.trailingObstruction = shown ? Self.width + 2 * Self.margin : 0 }
        .onChange(of: shown) { _, shown in model.canvasScale.trailingObstruction = shown ? Self.width + 2 * Self.margin : 0 }
    }
}
