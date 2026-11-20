// Qlick Lab — GPL-3.0-only. Part of EditorModel (Develop/EditorModel.swift holds its stored state).
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

extension EditorModel {
    // MARK: Edits per photograph

    /// Settings › New photographs › Film: what a photograph without edits
    /// opens with. Until one is chosen, or if this version lacks the one
    /// chosen, the newest defaults table's.
    var newPhotoFilm: String { newPhotoStock(chosenNewPhotoFilm, table: \.film, in: films, fallback: EditState().film) }
    /// Settings › New photographs › Paper, as `newPhotoFilm`.
    var newPhotoPaper: String { newPhotoStock(chosenNewPhotoPaper, table: \.paper, in: papers, fallback: EditState().paper) }

    func newPhotoStock(_ chosen: String?, table: KeyPath<SidecarDefaults, String>, in stocks: [Stock], fallback: String) -> String {
        let tabled = engine.flatMap { try? SidecarDefaults.load(version: SidecarDefaults.latest, data: $0.paths.data)[keyPath: table] }
        let candidates = [chosen, tabled].compactMap { $0 }
        // Before the catalog, nothing can be checked.
        guard !stocks.isEmpty else { return candidates.first ?? fallback }
        return candidates.first { id in stocks.contains { $0.id == id } } ?? stocks.first?.id ?? fallback
    }

    /// Chooses the film new photographs open with. Its own paper comes with
    /// it unless Settings › Keep paper when changing film, as in the inspector.
    func setNewPhotoFilm(_ film: String) {
        var choice = EditState(); choice.film = newPhotoFilm; choice.paper = newPhotoPaper
        let chosen = PreviewRules.choosing(film, paper: false, keepPaper: previews.keepPaper, in: choice, stocks: stocks)
        setNewPhotoStocks(film: chosen.film, paper: chosen.paper)
    }
    func setNewPhotoPaper(_ paper: String) { setNewPhotoStocks(film: newPhotoFilm, paper: paper) }

    func setNewPhotoStocks(film: String, paper: String) {
        let before = (newPhotoFilm, newPhotoPaper)
        chosenNewPhotoFilm = film; chosenNewPhotoPaper = paper
        UserDefaults.standard.set(film, forKey: Self.newPhotoFilmKey)
        UserDefaults.standard.set(paper, forKey: Self.newPhotoPaperKey)
        if before != (newPhotoFilm, newPhotoPaper) { followNewPhotoStocks() }
        refreshUneditedLook()
    }

    /// The open photograph takes a new default film and paper while it has no
    /// edits of its own, so it shows what its thumbnail does. Not an edit: no
    /// undo step, and nothing is written beside it.
    func followNewPhotoStocks() {
        guard source != nil, !closing, !cropping, !interacting, var context = photoSidecar, context.photo == source,
              !context.editedAtOpen, context.blocked == nil, Self.userEdits(state) == context.opened else { return }
        var next = state
        next.film = newPhotoFilm; next.paper = newPhotoPaper
        next.params["io.scan_film"] = .bool(films.first(where: { $0.id == next.film })?.positive ?? false)
        guard next != state else { return }
        replaceState(next)
        context.opened = Self.userEdits(state)
        photoSidecar = context
    }

    /// The state a photograph without saved edits opens with: the defaults,
    /// with the film and paper of Settings › New photographs. Image Size and
    /// the output colour follow the previous photograph, as a workflow's
    /// choices; its Prep, Lab, border, crop, rotation and how its file was
    /// read do not.
    func newPhotoState(after previous: EditState) -> EditState {
        var next = previous
        let retainedPaths = [ImageSize.targetPath, "io.output_color_space", "io.output_cctf_encoding"]
        let retained = retainedPaths.map { ($0, previous.params[$0]) }
        next.film = newPhotoFilm; next.paper = newPhotoPaper
        next.params = defaults
        for (path, value) in retained where value != .null { next.params[path] = value }
        next.params["io.scan_film"] = .bool(films.first(where: { $0.id == next.film })?.positive ?? false)
        next.border = BorderSettings()
        next.params["io.rotate_cw"] = .number(0)
        let interpretation = defaults["io.input_interpretation"]
        if interpretation != .null { next.params["io.input_interpretation"] = interpretation }
        next.params[Self.lensCorrectionPath] = defaults[Self.lensCorrectionPath]
        next.crop = CropSettings()
        next.brightnessMatch = autoPlaceNewImages ? BrightnessMatch() : nil
        return withPreferences(next)
    }

    /// Saved edits under the engine's current defaults. `legacy`: a schema 2
    /// session's, which may predate lens correction and the preview limit.
    func restoredState(_ saved: EditState, legacy: Bool, matchSolved: Bool = false) -> EditState {
        var restored = saved
        let lensCorrection = restored.params[Self.lensCorrectionPath]
        restored.params = defaults.restoring(restored.params, nullable: Set(catalog["nullable_paths"].array.map(\.string)))
        // A session from before lens correction was developed without it.
        if legacy, lensCorrection == .null { restored.params[Self.lensCorrectionPath] = .bool(false) }
        // Sessions from before Image Size may carry the old working-resolution factor.
        let factor = defaults[ImageSize.factorPath]
        if factor != .null { restored.params[ImageSize.factorPath] = factor }
        // The inspector no longer edits Post tone or colour; an older session's
        // Post edits would otherwise stay applied with no control to undo them.
        if defaults["post"] != .null { restored.params["post"] = defaults["post"] }
        // Sessions from before it was a preference carried it per photograph.
        if legacy, UserDefaults.standard.object(forKey: "limitPreview") == nil, restored.limitPreview {
            adoptingPreference = true; limitsPreview = true; adoptingPreference = false
        }
        restored = withPreferences(restored)
        // A match stored as solved was solved for these very edits.
        if matchSolved, restored.brightnessMatch != nil {
            let inputs = matchInputs(restored)
            restored.brightnessMatch?.inputs = inputs
        }
        return restored
    }

    /// The user's own edits in `state`: without the brightness match's solved
    /// exposure, which isn't one, and the preview limit, a preference.
    nonisolated static func userEdits(_ state: EditState) -> EditState {
        var edits = state
        edits.limitPreview = false
        if let match = edits.brightnessMatch {
            let offset = edits.params["prep.exposure_ev"].double - (match.ev ?? 0)
            edits.params["prep.exposure_ev"] = .number((offset * 1e9).rounded() / 1e9)
            edits.brightnessMatch = BrightnessMatch()
        }
        return edits
    }

    /// `photo`'s sidecar, or nil when sidecars aren't used.
    func readSidecar(_ photo: URL, variant: String?) -> SidecarRestore? {
        guard let sidecarLookup else { return nil }
        return SidecarRestore.read(photo: photo, variant: variant, store: sidecarLookup.store, data: sidecarLookup.data)
    }
    /// Where the launch reads the last photograph's sidecar; nil with sidecars off.
    var sidecarLookup: SidecarLookup? {
        guard sidecarsEnabled, let sidecars, let data = engine?.paths.data else { return nil }
        return SidecarLookup(store: sidecars, data: data)
    }

    /// Sets the state of the photograph being opened: its saved edits, a
    /// schema 2 session's, or a new photograph's, with the session's `match`
    /// if it was solved on this file for these settings. Then remembers its
    /// sidecar.
    func adoptEdits(for url: URL, restore: SidecarRestore?, legacy: EditState?, previous: EditState, match: SessionMatch? = nil) {
        var missingFilm: (saved: String, shown: String)?, missingPaper: (saved: String, shown: String)?
        if let legacy {
            state = restoredState(legacy, legacy: true)
        } else if let saved = restore?.edits, restore?.problem == nil, hasCatalog {
            var restored = restoredState(saved.state, legacy: false, matchSolved: saved.matchSolved)
            // A film or paper this version lacks (another fork's, a newer
            // release's) falls back to the defaults table's; the photograph opens.
            let table = sidecarLookup.flatMap { try? SidecarDefaults.load(version: restore?.defaultsVersion ?? 1, data: $0.data) }
            if !films.contains(where: { $0.id == restored.film }), let shown = films.first(where: { $0.id == table?.film })?.id ?? films.first?.id {
                missingFilm = (restored.film, shown)
                restored.film = shown
                restored.params["io.scan_film"] = .bool(films.first { $0.id == shown }?.positive ?? false)
            }
            if !papers.contains(where: { $0.id == restored.paper }), let shown = papers.first(where: { $0.id == table?.paper })?.id ?? papers.first?.id {
                missingPaper = (restored.paper, shown)
                restored.paper = shown
            }
            if missingFilm != nil || missingPaper != nil {
                let names = [missingFilm.map { "the film “\($0.saved)”" }, missingPaper.map { "the paper “\($0.saved)”" }].compactMap { $0 }
                error = "\(url.lastPathComponent) was edited with \(names.joined(separator: " and ")), which this version of Qlick Lab doesn’t have. It shows \([missingFilm.map { _ in filmName(restored.film) }, missingPaper.map { _ in paperName(restored.paper) }].compactMap { $0 }.joined(separator: " and ")) instead, and keeps the saved choice unless you pick another."
            }
            state = restored
        } else {
            state = newPhotoState(after: previous)
            if let match, state.brightnessMatch != nil, matchInputs(state) == match.inputs, match.solved(on: url),
               let solved = Self.matching(state, ev: match.ev, limited: match.highlightLimited, inputs: match.inputs) {
                state = solved
            }
        }
        guard let restore else { photoSidecar = nil; return }
        library.opened(sourceItem ?? url, summary: LibrarySummary(rating: restore.rating, flag: restore.flag, edited: restore.edits != nil, problem: restore.problem,
                                                                  words: restore.words))
        var context = sidecarContext(for: url, restore: restore)
        context.missingFilm = missingFilm; context.missingPaper = missingPaper
        if legacy != nil {
            // Written once launch settles, if it holds anything a new
            // photograph wouldn't have; it wins over a sidecar already there.
            context.opened = Self.userEdits(newPhotoState(after: state))
            context.written = nil
            context.migrating = true
        }
        // Before the catalog the edits can't be shown; `readoptSidecarEdits` reads them again.
        if !hasCatalog { context.awaitingCatalog = true }
        photoSidecar = context
        if let problem = restore.problem { error = problem }
    }

    func filmName(_ id: String) -> String { films.first { $0.id == id }?.name ?? id }
    func paperName(_ id: String) -> String { papers.first { $0.id == id }?.name ?? id }

    /// The open photograph's sidecar as it stands, with its current state as
    /// the one it opened with.
    func sidecarContext(for url: URL, restore: SidecarRestore) -> PhotoSidecarContext {
        var context = PhotoSidecarContext(photo: url, variant: restore.variant, defaultsVersion: restore.defaultsVersion,
                                          variantIsNew: restore.newVariant, opened: Self.userEdits(state),
                                          editedAtOpen: restore.edits != nil, exists: restore.exists, blocked: restore.problem)
        if restore.edits != nil, context.blocked == nil { context.written = storedEdits(state, context) }
        return context
    }

    /// The catalog changed under an open photograph: shows its saved edits
    /// under the new defaults, or the new photograph state, as opening it does.
    func readoptSidecarEdits() {
        guard let source, let context = photoSidecar, context.photo == source else { return }
        adoptEdits(for: source, restore: readSidecar(source, variant: sourceVariant), legacy: nil, previous: state)
    }

    /// `state` as its sidecar stores it.
    func storedEdits(_ current: EditState, _ context: PhotoSidecarContext) -> JSONValue? {
        guard let data = sidecarLookup?.data, let table = try? SidecarDefaults.load(version: context.defaultsVersion, data: data) else { return nil }
        var saved = current
        if let missing = context.missingFilm, saved.film == missing.shown { saved.film = missing.saved }
        if let missing = context.missingPaper, saved.paper == missing.shown { saved.paper = missing.saved }
        let solved = current.brightnessMatch.map { $0.ev != nil && $0.inputs == matchInputs(current) } ?? false
        return PhotoSidecar.encodeEdits(saved, matchSolved: solved, table: table)
    }

    /// Writes the open photograph's sidecar 1 s after the last edit.
    func scheduleSidecarWrite() {
        guard photoSidecar != nil, !closing else { return }
        sidecarWrite?.cancel()
        sidecarWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushSidecar()
        }
    }

    /// The edits the open photograph's sidecar would be sent now: once the
    /// user has edited it, or always if it had edits (nil inside removes
    /// them). Nil when nothing changed.
    func sidecarEditsToSend(_ context: PhotoSidecarContext) -> JSONValue?? {
        var current = state
        // Include a crop being drawn, without forcing the user to press Done.
        if let cropSession { current.crop = cropSession.settings }
        let edited = Self.userEdits(current) != context.opened
        let edits: JSONValue?
        if edited || context.editedAtOpen {
            guard let stored = storedEdits(current, context) else { return nil }
            edits = stored
        } else {
            edits = nil
        }
        return edits == context.written ? nil : .some(edits)
    }

    /// Sends the open photograph's edits to its sidecar now, if they changed.
    /// Back where it started, edits this visit saved are removed again.
    @discardableResult func flushSidecar() -> Task<Void, Never>? {
        sidecarWrite?.cancel(); sidecarWrite = nil
        guard sidecarsEnabled, let sidecars, sidecars.writes, var context = photoSidecar, context.blocked == nil, !context.awaitingCatalog,
              context.photo == source, hasCatalog, !closing, let edits = sidecarEditsToSend(context) else { return nil }
        let photo = context.photo
        let known: [String: [JSONValue]]
        if let data = sidecarLookup?.data, let table = try? SidecarDefaults.load(version: context.defaultsVersion, data: data) {
            known = ["params": [table.params, defaults], "crop": [table.crop], "border": [table.border]]
        } else { return nil }
        sidecars.enqueue(SidecarPatch(variant: context.variant, primary: context.variantIsNew, edits: edits, known: known,
                                      defaultsVersion: context.defaultsVersion, app: Self.appVersion), for: photo)
        var summary = library.summary(for: photo)
        summary.edited = edits != nil
        library.set(summary, for: photo)
        // Its look too, which names its edited thumbnail.
        library.reload(photo)
        context.written = edits; context.migrating = false
        context.exists = edits != nil || summary.rating > 0 || summary.flag != nil || !summary.words.isEmpty
        photoSidecar = context
        return Task { [weak self] in
            let failures = await sidecars.flush()
            for (failed, reason) in failures { self?.sidecarFailed(failed, reason) }
        }
    }

    /// Writes the open photograph's last edits and everything still waiting,
    /// at quit.
    func flushSidecars() async {
        flushSidecar()
        if let failures = await sidecars?.flush() {
            for (failed, reason) in failures { sidecarFailed(failed, reason) }
        }
    }

    func sidecarFailed(_ photo: URL, _ reason: String) {
        if photoSidecar?.photo.standardizedFileURL == photo.standardizedFileURL { photoSidecar?.blocked = reason }
        let folder = photo.deletingLastPathComponent().standardizedFileURL
        guard !closing, unwritableFolders.insert(folder).inserted else { return }
        error = "Edits to photographs in “\(folder.lastPathComponent)” can’t be saved beside them: \(reason)"
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Another app or Mac changed `photo`'s sidecar. For the open photograph
    /// a newer rating or flag shows at once (the library read it); newer
    /// edits replace these only if they're all saved, and otherwise these
    /// are written over them.
    func sidecarChangedOnDisk(_ photo: URL) {
        guard photo == source, !closing, var context = photoSidecar, context.photo == photo, context.blocked == nil,
              let lookup = sidecarLookup else { return }
        let restore = SidecarRestore.read(photo: photo, variant: sourceVariant, store: lookup.store, data: lookup.data)
        if let problem = restore.problem {
            // Never written over now; it opens with its edits shown as they are.
            photoSidecar?.blocked = problem
            return
        }
        context.exists = restore.exists
        if !restore.newVariant, context.variantIsNew { context.variant = restore.variant; context.variantIsNew = false }
        let table = try? SidecarDefaults.load(version: context.defaultsVersion, data: lookup.data)
        let ours = context.written.flatMap { written in table.flatMap { try? PhotoSidecar.decodeEdits(written, table: $0) } }
        guard restore.edits != ours || restore.defaultsVersion != context.defaultsVersion, !context.awaitingCatalog, hasCatalog,
              sidecarWrite == nil, !interacting, !cropping, sidecarEditsToSend(context) == nil else {
            photoSidecar = context
            return
        }
        cancelBrightnessMatch(); brightnessMatchFailure = nil
        customFilmFormat = false
        adoptEdits(for: photo, restore: restore, legacy: nil, previous: state)
        undoManager?.removeAllActions(withTarget: self)
        changed()
    }

    // MARK: Edits per photograph

    struct CopiedEdits: Equatable {
        /// The user's edits (`userEdits`), without a solved brightness match.
        var state: EditState
        var groups: Set<EditGroup>
        /// The photograph had edits of its own. One without them pastes
        /// none: what it lands on is left without edits in `groups`.
        var edited = true
    }

    /// Copy Edits…'s choice, remembered for the next time.
    var copyGroups: Set<EditGroup> {
        get {
            let names = UserDefaults.standard.stringArray(forKey: "copyEditGroups")
            return names.map { Set($0.compactMap(EditGroup.init(rawValue:))) } ?? EditGroup.standard
        }
        set { UserDefaults.standard.set(EditGroup.allCases.filter(newValue.contains).map(\.rawValue), forKey: "copyEditGroups") }
    }

    /// Edits can be copied, pasted and reset: the catalog has arrived and no
    /// crop is being drawn.
    var canChangeEdits: Bool { source != nil && hasCatalog && !cropping && !closing }

    /// What Copy Edits copies: the grid's current photograph, or the open one.
    var copySource: URL? { mode == .grid ? selection.current : sourceItem }
    var canCopyEdits: Bool { canChangeEdits && copySource != nil }
    var canPasteEdits: Bool { copiedEdits != nil && canChangeEdits && !editTargets.isEmpty }

    /// What Paste Edits, Reset Edits and Duplicate act on: the selection in
    /// the grid, or in the film strip while it shows; else the open photograph.
    var editTargets: [URL] {
        guard mode == .grid || stripShown else { return sourceItem.map { [$0] } ?? [] }
        return selection.ordered(shownPhotos.map(\.url))
    }

    /// A context menu's: the selection if `item` is in it, else `item`
    /// alone, as in Finder.
    func contextTargets(_ item: URL) -> [URL] {
        selection.selected.contains(item) ? selection.ordered(shownPhotos.map(\.url)) : [item]
    }

    /// Photo › Copy Edits…: the groups to copy as tick boxes in the alert
    /// sheet, the last choice ticked. Copy remembers the choice and copies.
    func copyEditsChoosing() {
        let chosen = copyGroups
        Task {
            let answer = await ask(AppAlert(
                title: "Copy Edits", detail: "Choose the edits Paste Edits applies.",
                buttons: [.init(title: "Copy"), .init(title: "Cancel", role: .cancel)],
                choices: EditGroup.allCases.map { AppAlert.Choice(title: $0.title, on: chosen.contains($0)) }))
            guard answer.button == 0 else { return }
            let groups = Set(zip(EditGroup.allCases, answer.choices).filter(\.1).map(\.0))
            copyGroups = groups
            copyEdits(groups: groups)
        }
    }

    func copyEdits(from item: URL? = nil, groups: Set<EditGroup> = EditGroup.standard) {
        guard canChangeEdits, let item = item ?? copySource else { return }
        guard let (edits, edited) = userEdits(of: item) else {
            libraryNote = LibraryNote(text: "Edits Not Copied", detail: "Its .qlick file can’t be read", serial: (libraryNote?.serial ?? 0) + 1)
            return
        }
        copiedEdits = CopiedEdits(state: edits, groups: groups, edited: edited)
        libraryNote = LibraryNote(text: "Edits Copied", serial: (libraryNote?.serial ?? 0) + 1)
    }

    func pasteEdits(onto items: [URL]? = nil) {
        guard let copied = copiedEdits else { return }
        changeEdits(items ?? editTargets, action: "Paste Edits", note: "Edits Pasted", fromUnedited: copied.edited ? nil : copied.groups) {
            EditGroup.merge(copied.groups, from: copied.state, into: $0)
        }
    }

    /// Applies the last photograph left with edits, no copy step.
    func pasteFromPrevious(onto items: [URL]? = nil) {
        guard let previous = previousEdits else { return }
        changeEdits(items ?? editTargets, action: "Paste from Previous", note: "Edits Pasted") {
            EditGroup.merge(EditGroup.standard, from: previous, into: $0)
        }
    }

    /// Removes the photographs' edits, crop and rotation included: they are
    /// as if never edited. The open one shows what a new photograph would
    /// get after it: the default film and paper, keeping its Image Size and
    /// output colour. Ratings and flags stay.
    func resetEdits(of items: [URL]? = nil) {
        changeEdits(items ?? editTargets, action: "Reset Edits", note: "Edits Reset", reset: true) { $0 }
    }

    /// `item`'s edits as `userEdits` gives them, and whether it has any of
    /// its own; nil if its sidecar can't be read.
    func userEdits(of item: URL) -> (state: EditState, edited: Bool)? {
        if item == sourceItem { return (Self.userEdits(state), openPhotographEdited) }
        guard let lookup = sidecarLookup else { return (Self.userEdits(plainState), false) }
        let restore = SidecarRestore.read(photo: item.photoFile, variant: item.variantID, store: lookup.store, data: lookup.data)
        guard restore.problem == nil else { return nil }
        guard let saved = restore.edits else { return (Self.userEdits(plainState), false) }
        return (Self.userEdits(restoredState(saved.state, legacy: false)), true)
    }

    /// The open photograph has edits its sidecar keeps: saved before, or
    /// made since it opened. Without a sidecar there's no telling, and its
    /// settings count as edits.
    var openPhotographEdited: Bool {
        guard let context = photoSidecar, context.photo == source else { return true }
        return context.editedAtOpen || Self.userEdits(state) != context.opened
    }

    /// A photograph without edits, not following any other.
    var plainState: EditState { newPhotoState(after: EditState()) }

    /// After pasting `groups` from a photograph without edits: `pasted` has
    /// none either when everything else is as a photograph without edits
    /// has it. The film and paper must be among `groups`, since a film kept
    /// in a sidecar is an edit, whichever it is. What the pasted groups hold
    /// doesn't count, such as the film the copied photograph showed by
    /// following the one before it.
    func holdsNoEdits(_ pasted: EditState, pasting groups: Set<EditGroup>) -> Bool {
        guard groups.contains(.filmAndPaper) else { return false }
        return Self.userEdits(pasted) == Self.userEdits(EditGroup.merge(groups, from: pasted, into: plainState))
    }

    /// What a photograph's edits are stored against: `params` with the
    /// engine's defaults too, so values from a newer version stay.
    func known(_ table: SidecarDefaults) -> [String: [JSONValue]] {
        ["params": [table.params, defaults], "crop": [table.crop], "border": [table.border]]
    }

    /// Changes the edits of `items` as one undo step: the open one in place,
    /// the others in their sidecars. Each sidecar is kept as it was first, so
    /// undo can put it back. `fromUnedited`: the groups pasted from a
    /// photograph without edits, which leave one without edits as it is,
    /// and one whose edits were all in them without any.
    func changeEdits(_ items: [URL], action: String, note: String, reset: Bool = false, fromUnedited: Set<EditGroup>? = nil,
                             _ transform: (EditState) -> EditState) {
        changeEdits(items, action: action, note: note, reset: reset, fromUnedited: fromUnedited, each: { _, state in transform(state) })
    }

    /// Qlick Lab: as above, the change made photograph by photograph (a preset with each one's own balance).
    func changeEdits(_ items: [URL], action: String, note: String, reset: Bool = false, fromUnedited: Set<EditGroup>? = nil,
                             each transformItem: (URL, EditState) -> EditState) {
        guard canChangeEdits, !items.isEmpty else { return }
        let open = sourceItem
        guard sidecarsEnabled, let sidecars, sidecars.writes, let lookup = sidecarLookup else {
            // Nothing is saved per photograph: only the open one changes, as any edit would.
            if let open, items.contains(open) { apply(reset ? newPhotoState(after: state) : transformItem(open, state), action: action) }
            let unsaved = items.contains { $0 != open } ? (sidecarsEnabled ? "Not saved" : "Not saved: Settings › Save ratings and edits is off") : nil
            libraryNote = LibraryNote(text: note, detail: unsaved, count: items.count, serial: (libraryNote?.serial ?? 0) + 1)
            return
        }
        // The open photograph's own edits are in its sidecar before it's kept.
        flushSidecar()
        var before: [URL: JSONValue?] = [:], unsaved: String?, openChanged = false
        for item in items {
            let photo = item.photoFile
            guard PhotoLibrary.canWrite(beside: photo) else { unsaved = unsaved ?? "Not saved: the folder is read-only"; continue }
            do {
                let raw = try sidecars.readPending(photo: photo)
                if item == open {
                    guard var context = photoSidecar, context.photo == photo, context.blocked == nil, !context.awaitingCatalog else {
                        unsaved = unsaved ?? "Not saved: its .qlick file can’t be changed"; continue
                    }
                    // Nothing pasted onto nothing.
                    if fromUnedited != nil, !openPhotographEdited { continue }
                    let pasted = transformItem(item, state)
                    let cleared = fromUnedited.map { holdsNoEdits(pasted, pasting: $0) } ?? false
                    if before[photo] == nil { before[photo] = .some(raw) }
                    openChanged = true
                    if reset || cleared {
                        replaceState(reset ? newPhotoState(after: state) : pasted)
                        // Unedited from here on: a later edit is measured from this.
                        sidecarWrite?.cancel(); sidecarWrite = nil
                        sidecars.enqueue(SidecarPatch(variant: context.variant, primary: context.variantIsNew, edits: .some(nil),
                                                      defaultsVersion: context.defaultsVersion, app: Self.appVersion), for: photo)
                        context.written = nil; context.editedAtOpen = false; context.opened = Self.userEdits(state)
                        photoSidecar = context
                    } else {
                        replaceState(pasted)
                        flushSidecar()
                    }
                    continue
                }
                let sidecar = try raw.map(PhotoSidecar.init(raw:))
                let variant = item.variantID.map { id in sidecar?.variants.first { $0.id == id } } ?? sidecar?.variants.first
                // A duplicate removed meanwhile.
                if item.variantID != nil, variant == nil { continue }
                // Nothing pasted onto nothing.
                if fromUnedited != nil, variant?.edits == nil { continue }
                if before[photo] == nil { before[photo] = .some(raw) }
                let version = sidecar?.defaultsVersion ?? SidecarDefaults.latest
                let table = try SidecarDefaults.load(version: version, data: lookup.data)
                var edits: JSONValue?
                if !reset {
                    let saved = try variant?.edits.map { try PhotoSidecar.decodeEdits($0, table: table) }
                    let base = saved.map { restoredState($0.state, legacy: false) } ?? plainState
                    let pasted = transformItem(item, base)
                    // Its match, if on, is solved again when it opens: the edits it was solved for changed.
                    if !(fromUnedited.map { holdsNoEdits(pasted, pasting: $0) } ?? false) {
                        edits = PhotoSidecar.encodeEdits(pasted, matchSolved: false, table: table)
                    }
                }
                sidecars.enqueue(SidecarPatch(variant: variant?.id ?? SidecarRestore.newVariantID(), primary: item.variantID == nil,
                                              edits: .some(edits), known: known(table), defaultsVersion: version, app: Self.appVersion), for: photo)
            } catch {
                unsaved = unsaved ?? "Not saved: its .qlick file can’t be changed"
            }
        }
        finishSidecarChange(before, action: action, openChanged: openChanged)
        libraryNote = LibraryNote(text: note, detail: unsaved, count: items.count, serial: (libraryNote?.serial ?? 0) + 1)
    }

    /// Duplicate: a virtual copy of each item, a new variant in its sidecar
    /// with the same edits, rating and flag, listed after the others.
    /// The grid selects the copies; the edit view opens the first.
    func duplicate(_ items: [URL]? = nil) {
        let items = items ?? editTargets
        guard canChangeEdits, !items.isEmpty else { return }
        guard sidecarsEnabled, let sidecars, sidecars.writes else {
            libraryNote = LibraryNote(text: "Not Duplicated", detail: "Duplicates are kept in .qlick files, which Settings › Save ratings and edits turns off",
                                      serial: (libraryNote?.serial ?? 0) + 1)
            return
        }
        flushSidecar()
        var before: [URL: JSONValue?] = [:], made: [URL] = [], unsaved: String?
        for item in items {
            let photo = item.photoFile
            guard PhotoLibrary.canWrite(beside: photo) else { unsaved = unsaved ?? "Not saved: the folder is read-only"; continue }
            do {
                let raw = try sidecars.readPending(photo: photo)
                // Checks the schema: a newer file is never written over.
                if let raw { _ = try PhotoSidecar(raw: raw) }
                if before[photo] == nil { before[photo] = .some(raw) }
                var top = raw?.object ?? ["qlick": .number(Double(PhotoSidecar.schema)), "defaultsVersion": .number(Double(SidecarDefaults.latest))]
                var variants = top["variants"]?.array ?? []
                if variants.isEmpty {
                    // The photograph's own variant first, with the id the open one already uses.
                    let id = item == sourceItem ? photoSidecar?.variant ?? SidecarRestore.newVariantID() : SidecarRestore.newVariantID()
                    variants.append(.object(["id": .string(id)]))
                }
                let original = item.variantID.flatMap { id in variants.firstIndex { $0["id"] == .string(id) } } ?? 0
                let id = SidecarRestore.newVariantID()
                var copy: [String: JSONValue] = ["id": .string(id)]
                // Edits, rating and flag, as a print from the same negative; from here on its own.
                for key in ["edits", "rating", "flag"] { if let value = variants[original].object?[key] { copy[key] = value } }
                variants.append(.object(copy))
                top["variants"] = .array(variants)
                top["app"] = .string(Self.appVersion)
                sidecars.enqueue(SidecarPatch(variant: id, replacement: .some(.object(top)), defaultsVersion: SidecarDefaults.latest,
                                              app: Self.appVersion), for: photo)
                made.append(photo.variant(id))
            } catch {
                unsaved = unsaved ?? "Not saved: its .qlick file can’t be changed"
            }
        }
        finishSidecarChange(before, action: made.count > 1 ? "Duplicate Photographs" : "Duplicate", openChanged: false)
        if let first = made.first {
            if mode == .grid { selection.select(made) } else { open(first) }
        }
        libraryNote = LibraryNote(text: made.isEmpty ? "Not Duplicated" : "Duplicated", detail: unsaved, count: max(made.count, 1),
                                  serial: (libraryNote?.serial ?? 0) + 1)
    }
}
