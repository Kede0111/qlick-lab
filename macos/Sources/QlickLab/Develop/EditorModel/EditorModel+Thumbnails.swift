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
    // MARK: Edited thumbnails

    /// How many thumbnails develop at once, each in a helper of its own
    /// (about 550 MB each): two on a Mac with the cores and memory.
    nonisolated static let thumbnailHelpers =
        ProcessInfo.processInfo.activeProcessorCount >= 8 && ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 2 : 1
    /// How many helpers develop thumbnails now.
    var thumbnailHelpersNow: Int { lowPowerMode ? 1 : Self.thumbnailHelpers }
    var thumbnailsHeld: Bool { thumbnailsHeldIn != nil && thumbnailsHeldIn == library.directory }

    /// The look that names `item`'s developed thumbnail: its stored edits',
    /// or `uneditedLook` for one without edits once its sidecar has been read
    /// (with sidecars off, every photograph opens with the defaults). Nil
    /// while that isn't known, or when its sidecar can't be read.
    func thumbnailLook(for item: URL) -> String? {
        // Read lazily, so a cell depends only on what decided its look.
        if let look = library.looks[item] { return look }
        guard let unedited = uneditedLook else { return nil }
        if library.store == nil { return unedited }
        guard let summary = library.summaries[item], summary.problem == nil else { return nil }
        return unedited
    }

    /// What `thumbnailLook(for:)` reads, copied, so the pump can scan a whole
    /// folder off the main actor. Decides as it does.
    struct ThumbnailLooks: Sendable {
        let looks: [URL: String], summaries: [URL: LibrarySummary], unedited: String?, sidecars: Bool

        func look(for item: URL) -> String? {
            if let look = looks[item] { return look }
            guard let unedited else { return nil }
            if !sidecars { return unedited }
            guard let summary = summaries[item], summary.problem == nil else { return nil }
            return unedited
        }
    }
    var thumbnailLooks: ThumbnailLooks {
        ThumbnailLooks(looks: library.looks, summaries: library.summaries, unedited: uneditedLook, sidecars: library.store != nil)
    }

    func editedThumbnail(for item: URL) -> EditedThumbnail? {
        guard let stamp = thumbnailStamp, let look = thumbnailLook(for: item) else { return nil }
        return EditedThumbnail(look: look, version: thumbnailVersions[item] ?? 0, stamp: stamp, store: editedThumbnails)
    }

    /// Where the pump develops out from once those on screen are done: the
    /// middle of the screen (indices in folder order, ascending), else the open photograph.
    nonisolated static func thumbnailCentre(onScreen: [Int], open: Int?) -> Int {
        onScreen.isEmpty ? open ?? 0 : onScreen[onScreen.count / 2]
    }

    /// `items` nearest `centre` first; of two as near, the one before.
    nonisolated static func outward<Item>(_ items: [(index: Int, item: Item)], from centre: Int) -> [Item] {
        items.sorted { (abs($0.index - centre), $0.index) < (abs($1.index - centre), $1.index) }.map(\.item)
    }

    /// A strip or grid cell came on screen or left it.
    func thumbnailShown(_ file: PhotoFile, _ visible: Bool) {
        prefetchThumbnails()
        guard visible else { thumbnailsOnScreen.remove(file.url); return }
        thumbnailsOnScreen.insert(file.url)
        if thumbnailLook(for: file.url) != nil { pumpThumbnails() }
    }

    /// How far either side of the middle of the screen thumbnails are read
    /// into memory ahead of scrolling: 25–45 MB in the grid, which the
    /// in-memory caches hold.
    nonisolated static let prefetchReach = 32

    /// Reads the thumbnails near the strip's or grid's view into memory, one
    /// at a time and nearest first, so they're there before they're scrolled
    /// to. Each change of the view starts again from its middle.
    func prefetchThumbnails() {
        #if SPEKTRAFILM_BENCHMARK
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_NO_PREFETCH"] != nil { return }
        #endif
        prefetchRound += 1
        guard prefetching == nil else { return }
        prefetching = Task { [weak self] in
            // After this turn of the main actor, once the cells that changed have.
            await Task.yield()
            while let self, !Task.isCancelled, !self.closing {
                let round = self.prefetchRound
                for (file, size, edited) in await self.prefetchTargets() {
                    guard self.prefetchRound == round, !Task.isCancelled else { break }
                    let image = await Task.detached(priority: .utility) {
                        await PhotoThumbnails.shared.image(for: file, size: size, look: edited?.look, edited: edited?.store, ahead: true)
                    }.value
                    // Its frame takes the shape of what will be shown.
                    if let image { self.aspects.note(file.url, image: image) }
                }
                guard self.prefetchRound != round else { break }
                // While scrolling, a round at most every 30 ms.
                try? await Task.sleep(for: .milliseconds(30))
            }
            self?.prefetching = nil
        }
    }

    /// Those within `prefetchReach` of the middle of the screen (else the
    /// current photograph), nearest first, but those on screen, which their
    /// cells read; nothing when neither the strip nor the grid shows. Found
    /// off the main actor: a folder can hold thousands.
    func prefetchTargets() async -> [(PhotoFile, PhotoThumbnails.Size, EditedThumbnail?)] {
        let grid = mode == .grid
        guard grid || (stripShown && source != nil), !library.filtering else { return [] }
        let size = grid ? gridThumbnailSize : .strip
        let shown = shownPhotos, onScreen = thumbnailsOnScreen, current = grid ? selection.current : sourceItem
        let near = await Task.detached(priority: .utility) { () -> [PhotoFile] in
            guard !shown.isEmpty else { return [] }
            var visible: [Int] = [], currentIndex: Int?
            for (index, file) in shown.enumerated() {
                if onScreen.contains(file.url) { visible.append(index) }
                if file.url == current { currentIndex = index }
            }
            let centre = Self.thumbnailCentre(onScreen: visible, open: currentIndex)
            let reach = max(0, centre - Self.prefetchReach)...min(shown.count - 1, centre + Self.prefetchReach)
            return Self.outward(reach.filter { !onScreen.contains(shown[$0].url) }.map { ($0, shown[$0]) }, from: centre)
        }.value
        return near.map { ($0, size, editedThumbnail(for: $0.url)) }
    }

    /// Reads the engine's identity once, off the main actor, after launch.
    func readThumbnailStamp() {
        guard thumbnailStamp == nil, !readingThumbnailStamp, let paths = engine?.paths else { return }
        readingThumbnailStamp = true
        let store = editedThumbnails, archive = renderArchive
        Task { [weak self] in
            let stamp = await Task.detached(priority: .utility) { () -> String? in
                let stamp = EditedThumbnailStore.stamp(paths)
                store.engineStamp = stamp
                archive.engineStamp = stamp
                // The oldest go once a session.
                store.prune()
                archive.prune()
                return stamp
            }.value
            guard let self, !self.closing else { return }
            self.thumbnailStamp = stamp
            // The stores may have been replaced while it was read.
            self.editedThumbnails.engineStamp = stamp
            self.renderArchive.engineStamp = stamp
            self.pumpThumbnails()
        }
    }

    /// The bytes the thumbnails take on disk, for Settings.
    /// Qlick Lab: the thumbnails alone; the previews have their own section (`PreviewStorageSection`).
    func thumbnailCacheSize() async -> Int {
        let store = editedThumbnails
        return await Task.detached(priority: .utility) { store.size() }.value
    }

    /// Removes every thumbnail; the open folder's are developed again.
    /// Those on screen stay until each is made again.
    func emptyThumbnailCache() async {
        let store = editedThumbnails
        await Task.detached(priority: .userInitiated) { store.removeAll() }.value
        thumbnailsEmptied += 1
        thumbnailsChecked = [:]
        pumpThumbnails()
    }

    func thumbnailMade(_ item: URL, look: String) {
        thumbnailsChecked[item] = (look, true)
        thumbnailVersions[item, default: 0] += 1
        prefetchThumbnails()
        settleWantedThumbnails()
    }


    /// Qlick Lab: Build Thumbnails. First each photograph's own picture (a RAW's embedded JPEG, a JPEG or PNG) is
    /// read and kept on this Mac, several at a time, so the whole selection shows at once even from another
    /// computer (`EmbeddedThumbnails`). Then their thumbnails are developed before the rest of the folder, whether
    /// they're on screen or not, their proxies first.
    func buildThumbnails(_ items: [URL]) {
        guard !items.isEmpty else { return }
        thumbnailsHeldIn = nil
        embeddedTask?.cancel()
        let asked = Set(items)
        let photos = library.items.filter { asked.contains($0.url) }
        embeddedRead = (0, photos.count)
        let progress: @Sendable (Int) async -> Void = { [weak self] done in await self?.noteEmbeddedRead(done) }
        embeddedTask = Task { [weak self] in
            await EmbeddedThumbnails.extract(photos, progress: progress)
            guard !Task.isCancelled, let self else { return }
            self.embeddedRead = (0, 0)
            self.embeddedTask = nil
            self.developThumbnails(items)
        }
    }

    func noteEmbeddedRead(_ done: Int) {
        if embeddedRead.total > 0 { embeddedRead.done = done }
    }

    /// Qlick Lab: stops reading the photographs' own pictures ahead (those read stay kept).
    func stopReadingThumbnails() {
        embeddedTask?.cancel()
        embeddedTask = nil
        embeddedRead = (0, 0)
    }

    /// Qlick Lab: these photographs' thumbnails developed before the rest of the folder, their proxies first.
    func developThumbnails(_ items: [URL]) {
        let asked = Set(items)
        if thumbnailsWanted.isEmpty { thumbnailsAsked = (0, 0) }
        thumbnailsWanted = items + thumbnailsWanted.filter { !asked.contains($0) }
        thumbnailsAsked.total = thumbnailsAsked.done + thumbnailsWanted.count
        lab.proxyMaker.make(items, first: true)
        settleWantedThumbnails()
        if thumbnailsWanted.isEmpty {
            libraryNote = LibraryNote(text: items.count == 1 ? "Its thumbnail is already there" : "All \(items.count) thumbnails are already there",
                                      detail: nil, count: items.count, serial: (libraryNote?.serial ?? 0) + 1)
        }
        pumpThumbnails()
    }

    /// Qlick Lab: those asked for that are there now, or can't be made, are done.
    func settleWantedThumbnails() {
        guard !thumbnailsWanted.isEmpty else { return }
        let open = mode == .grid ? nil : sourceItem
        let before = thumbnailsWanted.count, listed = Set(library.items.map(\.url))
        thumbnailsWanted.removeAll { item in
            if item == open || !listed.contains(item) { return true }
            guard let look = thumbnailLook(for: item) else { return library.summariesLoaded }
            if thumbnailFailures[item] == look { return true }
            return thumbnailsChecked[item].map { $0.look == look && $0.present } ?? false
        }
        guard thumbnailsWanted.count != before else { return }
        thumbnailsAsked.done += before - thumbnailsWanted.count
        if thumbnailsWanted.isEmpty { thumbnailsAsked = (0, 0) }
    }

    /// Qlick Lab: stops developing thumbnails in the background: those asked for, and the rest of the folder off
    /// screen. The ones developing off screen stop now (their helpers are quit); those on screen still develop.
    func stopThumbnails() {
        thumbnailsHeldIn = library.directory
        stopReadingThumbnails()
        thumbnailsWanted = []; thumbnailsAsked = (0, 0)
        let onScreen = thumbnailsOnScreen
        var stopped: [EngineClient] = []
        for (slot, job) in thumbnailsDeveloping where !onScreen.contains(job.item) {
            job.task.cancel()
            thumbnailsDeveloping[slot] = nil
            if let engine = thumbnailEngines.removeValue(forKey: slot) { stopped.append(engine) }
        }
        if !stopped.isEmpty { Task.detached(priority: .utility) { stopped.forEach { $0.stop() } } }
        pumpThumbnails()
    }

    /// The open photograph's developed thumbnail, made from the preview on
    /// screen, so it costs no render: on leaving it for another photograph
    /// or the grid. One without edits only while it shows what a new
    /// photograph opens with (it may predate a new default).
    func saveOpenThumbnail() {
        guard let item = sourceItem, let surface = image, !imageIsMask, previewCurrent, !showingInteractiveFrame, heldPreview == nil, cropSession == nil,
              !brightnessMatchPending, let look = thumbnailLook(for: item), thumbnailsChecked[item].map({ $0.look != look || !$0.present }) ?? true,
              library.looks[item] != nil || Self.uneditedLook(of: state) == look,
              let file = library.items.first(where: { $0.url == item }), let key = editedThumbnails.key(for: file, look: look) else { return }
        let size = imageSize, crop = crop, rotation = imageRotation, border = state.border, texture = filmTexture, strip = filmStrip
        let store = editedThumbnails, loose = store.looseKey(for: file, look: look)
        let shown = surface
        Task { [weak self] in
            guard let photo = await Task.detached(priority: .utility, operation: { ThumbnailComposer.image(of: shown) }).value,
                  let composed = ThumbnailComposer.compose(photo, size: size, crop: crop, cut: false, rotation: rotation, border: border, texture: texture,
                                                           strip: strip, space: photo.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
            let saved = await Task.detached(priority: .utility) { (try? store.save(composed, as: key, loose: loose)) != nil }.value
            if saved { self?.thumbnailMade(item, look: look) }
        }
    }

    /// The open photograph's develop, screen-sized and uncropped, kept as
    /// it's left so it stands in when the photograph next opens (`renderArchive`).
    /// Under the same conditions as its thumbnail, off the main actor.
    func saveOpenRender() {
        guard let item = sourceItem, let surface = image, !imageIsMask, previewCurrent, !showingInteractiveFrame, heldPreview == nil, cropSession == nil,
              !brightnessMatchPending, let look = thumbnailLook(for: item),
              library.looks[item] != nil || Self.uneditedLook(of: state) == look,
              let file = library.items.first(where: { $0.url == item }), let key = renderArchive.key(for: file, look: look) else { return }
        let archive = renderArchive, size = imageSize, shown = surface, loose = archive.looseKey(for: file, look: look), photo = archive.photoKey(for: file)
        Task.detached(priority: .utility) {
            guard !archive.contains(key),
                  let frame = ThumbnailComposer.image(of: shown, maxPixels: EditedThumbnailStore.renderLongSide) else { return }
            try? archive.save(frame, as: key, loose: loose, photo: photo, photoSize: size)
        }
    }

    /// The background renderer can use the machine: nothing is being edited,
    /// developed, exported or saved in the window.
    var thumbnailsMayRun: Bool {
        !closing && !interacting && !rendering && pendingRender == nil && !exporting && !batchRunning && !saving && !cropping && matchTask == nil
            && (mode == .grid || source == nil || previewCurrent || renderFailed)
    }

    /// Qlick Lab: the background preview builder may use the machine.
    var backgroundMayRun: Bool { thumbnailsMayRun }

    /// Develops the next items without a current thumbnail, edited or not,
    /// in helpers of their own, at utility priority: those on screen first,
    /// then the folder in order. `thumbnailHelpers` at a time, waiting while
    /// the open photograph is edited or developed. The helpers quit when
    /// there's nothing left.
    func pumpThumbnails() {
        guard !closing, hasCatalog, let paths = engine?.paths else { return }
        // Its scan reads what it was started with: once more after, for what changed.
        guard thumbnailTask == nil else { thumbnailsPumpAgain = true; return }
        // Each that finishes pumps again.
        let free = (0..<thumbnailHelpersNow).filter { thumbnailsDeveloping[$0] == nil }
        guard !free.isEmpty else { return }
        if thumbnailStamp == nil { return readThumbnailStamp() }
        thumbnailTask = Task { [weak self] in
            // None is developed before then, so the folder isn't scanned
            // while the open photograph loads or is edited.
            guard let self, await self.waitForThumbnailTurn() else { return }
            let store = self.editedThumbnails, lookup = self.sidecarLookup
            // Copies (the dictionaries copy on write): a folder of thousands
            // is scanned for every thumbnail, which must stay off the main actor.
            // Qlick Lab: on the contact sheet the open photograph isn't developed, so the pump makes its thumbnail too.
            let items = self.library.items, open = self.mode == .grid ? nil : self.sourceItem, onScreen = self.thumbnailsOnScreen, looks = self.thumbnailLooks
            let failures = self.thumbnailFailures, checked = self.thumbnailsChecked, emptied = self.thumbnailsEmptied
            let developing = Set(self.thumbnailsDeveloping.values.map(\.item)), onlyOnScreen = self.lowPowerMode || self.thumbnailsHeld
            let wanted = self.thumbnailsWanted, wantedSet = Set(wanted)
            // Qlick Lab: with proxies made ahead, a RAW's thumbnail waits for its proxy (the camera's JPEG shows
            // meanwhile): developed from it, it takes milliseconds instead of seconds.
            let pendingProxies = PreviewStorage.buildsProxiesAhead ? self.lab.proxyMaker.pending : []
            self.thumbnailsPumpAgain = false
            // Each item but the open one, whose thumbnail comes from its
            // preview, and those developing, on screen first, then outward
            // from the middle of the screen (or the open photograph), so the
            // next ones scrolled to or opened are ready: the first without a
            // thumbnail on disk, one for each free helper. Those with one are
            // noted. In Low Power Mode, those on screen only.
            let found = await Task.detached(priority: .utility) { () -> (present: [(URL, String)], next: [(file: PhotoFile, look: String)], missing: Int) in
                var shown: [(file: PhotoFile, look: String)] = [], rest: [(index: Int, file: PhotoFile, look: String)] = []
                var asked: [URL: (file: PhotoFile, look: String)] = [:]
                var onScreenIndices: [Int] = [], openIndex: Int?
                for (index, file) in items.enumerated() {
                    if file.url == open { openIndex = index; continue }
                    if onScreen.contains(file.url) { onScreenIndices.append(index) }
                    guard !developing.contains(file.url), let look = looks.look(for: file.url), failures[file.url] != look else { continue }
                    if pendingProxies.contains(file.url.photoFile) { continue }
                    if let checked = checked[file.url], checked.look == look, checked.present { continue }
                    if onScreen.contains(file.url) { shown.append((file, look)) }
                    else if wantedSet.contains(file.url) { asked[file.url] = (file, look) }
                    else if !onlyOnScreen { rest.append((index, file, look)) }
                }
                let centre = Self.thumbnailCentre(onScreen: onScreenIndices, open: openIndex)
                // Qlick Lab: on screen first, then those asked for, in the order asked, then outward.
                let ordered = shown + wanted.compactMap { asked[$0] } + Self.outward(rest.map { ($0.index, (file: $0.file, look: $0.look)) }, from: centre)
                var present: [(URL, String)] = [], next: [(file: PhotoFile, look: String)] = [], missing = 0
                // Every one is looked at, to count those still missing for the sidebar.
                for (file, look) in ordered {
                    guard let key = store.key(for: file, look: look) else { continue }
                    if store.contains(key) { present.append((file.url, look)) }
                    else {
                        missing += 1
                        if next.count < free.count { next.append((file, look)) }
                    }
                }
                return (present, next, missing + developing.count)
            }.value
            guard !self.closing else { return }
            guard emptied == self.thumbnailsEmptied else {
                self.thumbnailTask = nil
                return self.pumpThumbnails()
            }
            for (item, look) in found.present { self.thumbnailsChecked[item] = (look, true) }
            self.settleWantedThumbnails()
            if self.thumbnailsLeft != found.missing { self.thumbnailsLeft = found.missing }
            for (slot, (file, look)) in zip(free, found.next) {
                self.thumbnailIdle?.cancel(); self.thumbnailIdle = nil
                self.thumbnailsChecked[file.url] = (look, false)
                let task = Task { [weak self] in
                    guard let self else { return }
                    let made = await self.developThumbnail(file, look: look, lookup: lookup, paths: paths, slot: slot)
                    // Qlick Lab: stopped (`stopThumbnails`): not the photograph's failure, and its slot is free already.
                    guard !Task.isCancelled else { return }
                    if !made { self.thumbnailFailures[file.url] = look; self.settleWantedThumbnails() }
                    self.thumbnailsDeveloping[slot] = nil
                    if slot >= self.thumbnailHelpersNow { self.stopSpareThumbnailEngines() }
                    self.pumpThumbnails()
                }
                self.thumbnailsDeveloping[slot] = (file.url, task)
            }
            self.thumbnailTask = nil
            if self.thumbnailsPumpAgain {
                self.pumpThumbnails()
            } else if self.thumbnailsDeveloping.isEmpty {
                if self.thumbnailsLeft != 0, found.next.isEmpty { self.thumbnailsLeft = 0 }
                self.stopThumbnailEngineSoon()
            }
        }
    }

    /// Quits the idle helpers past `thumbnailHelpersNow`, so their memory
    /// goes; one still developing finishes first.
    func stopSpareThumbnailEngines() {
        let spare = thumbnailEngines.filter { $0.key >= thumbnailHelpersNow && thumbnailsDeveloping[$0.key] == nil }
        guard !spare.isEmpty else { return }
        spare.keys.forEach { thumbnailEngines[$0] = nil }
        let engines = Array(spare.values)
        Task.detached(priority: .utility) { engines.forEach { $0.stop() } }
    }

    /// Quits the background helpers after a while without work, so their memory goes.
    func stopThumbnailEngineSoon() {
        guard !thumbnailEngines.isEmpty, thumbnailIdle == nil else { return }
        thumbnailIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.thumbnailTask == nil, self.thumbnailsDeveloping.isEmpty else { return }
            let engines = Array(self.thumbnailEngines.values)
            self.thumbnailEngines = [:]; self.thumbnailIdle = nil
            await Task.detached(priority: .utility) { engines.forEach { $0.stop() } }.value
        }
    }

    /// Waits until the background renderer may use the machine.
    func waitForThumbnailTurn() async -> Bool {
        while !thumbnailsMayRun {
            guard !closing, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !closing
    }

    /// Develops `file`'s thumbnail as opening it would: with its stored
    /// edits, or, without edits (`uneditedLook`), as a new photograph. A
    /// match not yet solved for stored edits is solved on the whole decode
    /// and stored, unless its edits changed meanwhile; an unedited one's is
    /// solved on the reduced decode for the thumbnail only. Everything else
    /// reads only as much of a RAW as the thumbnail needs. False when it
    /// can't be made.
    func developThumbnail(_ file: PhotoFile, look: String, lookup: SidecarLookup?, paths: EnginePaths, slot: Int) async -> Bool {
        let item = file.url, photo = item.photoFile
        var state: EditState, matchSolved: Bool
        /// Stores a solved match with the stored edits: their new look, or nil.
        var storeMatch: ((EditState) -> String?)?
        if look == uneditedLook, library.looks[item] == nil {
            state = plainState; matchSolved = false
        } else {
            guard let lookup, let sidecar = try? lookup.store.read(photo: photo),
                  let variant = item.variantID.map({ id in sidecar.variants.first { $0.id == id } }) ?? sidecar.variants.first,
                  let stored = variant.edits, PhotoSidecar.look(of: stored, defaultsVersion: sidecar.defaultsVersion) == look,
                  let table = try? SidecarDefaults.load(version: sidecar.defaultsVersion, data: lookup.data),
                  let saved = try? PhotoSidecar.decodeEdits(stored, table: table) else { return false }
            state = restoredState(saved.state, legacy: false, matchSolved: saved.matchSolved); matchSolved = saved.matchSolved
            storeMatch = { [weak self] in self?.storeSolvedMatch($0, item: item, variant: variant.id, stored: stored, sidecar: sidecar, table: table) }
        }
        let raw = Self.rawExtensions.contains(photo.pathExtension.lowercased())
        let engine: EngineClient
        do {
            if let running = thumbnailEngines[slot] { engine = running } else {
                engine = try EngineClient(paths: paths, quality: .utility); engine.label = "thumbnails\(slot)"; thumbnailEngines[slot] = engine
            }
        } catch { return false }
        thumbnailGeneration += 1
        let generation = thumbnailGeneration, space = previewSpace
        let buffer = engine.directory.appendingPathComponent("library-thumbnail.rgba")
        defer { try? FileManager.default.removeItem(at: buffer) }
        let longSide = Int(EditedThumbnailStore.longSide)
        func command(_ state: EditState, longSide: Int) -> [String: JSONValue] {
            var params = state.params
            params["io.output_color_space"] = .string(space)
            var command: [String: JSONValue] = [
                "command": EngineCommand.thumbnail.json, "input": .string(photo.path), "source_generation": .number(Double(generation)),
                "film": .string(state.film), "paper": .string(state.paper), "params": params,
                "long_side": .number(Double(longSide)), "preview_path": .string(buffer.path),
                // A whole decode the helper already holds serves this too.
                "reduced_decode": .bool(true),
            ]
            if let crop = Self.cropJSON(state.crop) { command["crop"] = crop }
            return command
        }
        var finalLook = look
        do {
            let matchable = raw || state.params["io.input_interpretation.mode"].string == "auto"
            if state.brightnessMatch != nil, !matchSolved, matchable {
                // The decode first, which the match is solved on: the thumbnail's own reduced read (the proxy,
                // when there's one). Qlick Lab: never the whole photograph — reading a 60 MP RAW for each
                // thumbnail took seconds, for a match within 0.01 EV of the one Develop solves when it opens.
                // Not developed, and the camera preview's colour space read meanwhile.
                guard await waitForThumbnailTurn() else { return false }
                var decode = command(state, longSide: longSide)
                decode["decode_only"] = .bool(true)
                if raw { decode["preview_colour_space"] = .bool(true) }
                // The camera preview read meanwhile (~35 ms).
                let prepared = raw ? Task.detached(priority: .utility) { CameraBrightnessReference.Prepared(from: photo) } : nil
                // Solved on a reduced read: not kept for Develop, which solves on the whole photograph.
                let cacheKey: String? = nil
                let (_, decoded) = try await engine.request(decode)
                let size = CGSize(width: decoded["source_width"].double, height: decoded["source_height"].double)
                guard await waitForThumbnailTurn() else { return false }
                let reference = engine.directory.appendingPathComponent("library-brightness.png")
                defer { try? FileManager.default.removeItem(at: reference) }
                if let solved = try? await Self.solveBrightnessMatch(engine: engine, source: photo, generation: generation, size: size, raw: raw,
                                                                    request: matchSolveState(state), reference: reference,
                                                                    declared: raw ? decoded["preview_colour_space"] : nil, prepared: prepared),
                   let matched = Self.matching(state, ev: solved.exposure, limited: solved.limited, inputs: matchInputs(state)) {
                    // Solved on the whole decode (a stored match), so opening
                    // the photograph would solve the same: kept for it.
                    // The reduced decode's can differ by 0.01 EV and isn't.
                    if let cacheKey, cacheKey == matchCacheKey(photo, request: matchSolveState(state), paths: paths) {
                        matchCache.store(cacheKey, ev: solved.exposure, limited: solved.limited)
                    }
                    state = matched
                    if let storeMatch { finalLook = storeMatch(state) ?? look }
                }
            }
            guard await waitForThumbnailTurn() else { return false }
            let (_, result) = try await engine.request(command(state, longSide: longSide))
            let (width, height) = (Int(result["width"].double), Int(result["height"].double))
            let display = result["display_color_space"].string
            let size = CGSize(width: result["source_width"].double, height: result["source_height"].double)
            let developed = try await Task.detached(priority: .utility) {
                try Self.thumbnailImage(Data(contentsOf: buffer), width: width, height: height, displaySpace: display)
            }.value
            guard !closing else { return false }
            let strip = state.border.style == .film35 ? FilmFormat(state.crop.size(of: size)).flatMap { FilmStrip.load(data: paths.data, film: state.film, format: $0) } : nil
            guard let composed = ThumbnailComposer.compose(developed, size: size, crop: state.crop, cut: true, rotation: Int(state.params["io.rotate_cw"].double),
                                                           border: state.border, texture: filmTexture, strip: strip,
                                                           space: developed.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!),
                  let key = editedThumbnails.key(for: file, look: finalLook) else { return false }
            let store = editedThumbnails, loose = store.looseKey(for: file, look: finalLook)
            try await Task.detached(priority: .utility) { try store.save(composed, as: key, loose: loose) }.value
            thumbnailMade(item, look: finalLook)
            if finalLook != look { library.reload(photo) }
            return true
        } catch {
            FileHandle.standardError.write(Data("library thumbnail \(file.name): \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// Stores a match solved in the background, unless the item's edits
    /// changed since they were read. Its new look, or nil if not stored.
    func storeSolvedMatch(_ state: EditState, item: URL, variant: String, stored: JSONValue, sidecar: PhotoSidecar, table: SidecarDefaults) -> String? {
        let photo = item.photoFile
        guard sidecarsEnabled, let sidecars, sidecars.writes, PhotoLibrary.canWrite(beside: photo) else { return nil }
        let edits = PhotoSidecar.encodeEdits(state, matchSolved: true, table: table)
        sidecars.enqueue(SidecarPatch(variant: variant, edits: .some(edits), known: known(table), onlyIfEdits: .some(stored),
                                      defaultsVersion: sidecar.defaultsVersion, app: Self.appVersion), for: photo)
        writeSidecars()
        guard let now = try? sidecars.read(photo: photo), let written = now.variants.first(where: { $0.id == variant }),
              written.edits != stored else { return nil }
        return PhotoSidecar.look(of: written.edits, defaultsVersion: now.defaultsVersion)
    }
}
