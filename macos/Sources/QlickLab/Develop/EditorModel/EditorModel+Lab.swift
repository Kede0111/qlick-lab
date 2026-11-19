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
    // MARK: Qlick Lab (macos/Sources/QlickLab/Lab)
    //
    // Everything Qlick Lab adds to the editor's model is in this section: the
    // lab's own state, and developing any photograph of the folder at a given
    // size in a helper of the lab's own (the loupe, Comparaison), with the
    // same engine and the same settings as its thumbnail and its export.


    var labEnginePaths: EnginePaths? { engine?.paths }

    /// The edits `item` develops with, as opening it would show it, and
    /// whether its brightness match is already solved in them.
    func labEdits(for item: URL) -> (state: EditState, matchSolved: Bool) {
        if item == sourceItem { return (renderState, !brightnessMatchPending) }
        let photo = item.photoFile
        if let lookup = sidecarLookup, let sidecar = try? lookup.store.read(photo: photo),
           let variant = item.variantID.map({ id in sidecar.variants.first { $0.id == id } }) ?? sidecar.variants.first,
           let stored = variant.edits, let table = try? SidecarDefaults.load(version: sidecar.defaultsVersion, data: lookup.data),
           let saved = try? PhotoSidecar.decodeEdits(stored, table: table) {
            return (restoredState(saved.state, legacy: false, matchSolved: saved.matchSolved), saved.matchSolved)
        }
        return (plainState, false)
    }

    /// Develops `item` at `longSide` pixels in `engine`: with its own edits,
    /// or with `film` chosen as a click on it would, or under `preset` (a
    /// recipe's text). Cropped, turned and straightened as its thumbnail is;
    /// without its border, which Comparaison doesn't judge. Nil if it fails.
    func labDevelop(_ item: URL, film: String? = nil, paper: String? = nil, preset: String? = nil, longSide: Int, engine: EngineClient,
                    whole: Bool = false, sized: ((CGSize) -> Void)? = nil) async -> CGImage? {
        guard !closing, hasCatalog else { return nil }
        let photo = item.photoFile
        var (state, matchSolved) = labEdits(for: item)
        if let film { state = PreviewRules.choosing(film, paper: false, keepPaper: previews.keepPaper, in: state, stocks: stocks) }
        if let paper { state = PreviewRules.choosing(paper, paper: true, keepPaper: true, in: state, stocks: stocks) }
        let raw = Self.rawExtensions.contains(photo.pathExtension.lowercased())
        // Qlick Lab: a recipe on a photograph whose exposure is still to be matched to the camera's is made its
        // edits first, as applying it does, so the match is solved for the recipe: what is seen here (the import's
        // loupe) is what the photograph develops to once the recipe is written into its edits. The engine can't
        // decode alone under a preset.
        // A recipe applied with its Develop part is made the edits too: the engine applies only spektrafilm's settings.
        var preset = preset
        let develop = preset.flatMap(recipeDevelop)
        if let text = preset, (state.brightnessMatch != nil && !matchSolved) || develop != nil,
           let (_, applied) = try? await engine.request(["command": EngineCommand.presetImport.json, "text": .string(text), "params": state.params]),
           films.contains(where: { $0.id == applied["film"].string }), papers.contains(where: { $0.id == applied["paper"].string }) {
            let photo = state
            state.film = applied["film"].string; state.paper = applied["paper"].string; state.params = applied["params"]
            if let develop {
                state = develop.applied(to: state, photo: photo)
                if develop.groups.contains(.brightness) { matchSolved = false }
            }
            preset = nil
        }
        let generation: Int
        if let known = labGenerations[photo.path] { generation = known } else {
            labGeneration += 1; generation = labGeneration; labGenerations[photo.path] = generation
        }
        let space = previewSpace, id = UUID().uuidString
        let buffer = engine.directory.appendingPathComponent("lab-\(id).rgba")
        defer { try? FileManager.default.removeItem(at: buffer) }
        func command(_ state: EditState) -> [String: JSONValue] {
            var params = state.params
            params["io.output_color_space"] = .string(space)
            var command: [String: JSONValue] = [
                "command": EngineCommand.thumbnail.json, "input": .string(photo.path), "source_generation": .number(Double(generation)),
                "film": .string(state.film), "paper": .string(state.paper), "params": params,
                "long_side": .number(Double(min(max(longSide, 16), 4096))), "preview_path": .string(buffer.path),
                // A small picture reads only as much of a RAW as it needs; one to judge at 100 % reads it whole.
                // Qlick Lab: up to a proxy's size, the proxy or a reduced read; larger reads the RAW whole.
                "reduced_decode": .bool(longSide <= 2560),
            ]
            if !whole, let crop = Self.cropJSON(state.crop) { command["crop"] = crop }
            if let preset { command["preset"] = .string(preset) }
            return command
        }
        do {
            let matchable = raw || state.params["io.input_interpretation.mode"].string == "auto"
            if state.brightnessMatch != nil, !matchSolved, matchable {
                var decode = command(state)
                decode["decode_only"] = .bool(true)
                if raw { decode["preview_colour_space"] = .bool(true) }
                let (_, decoded) = try await engine.request(decode)
                let size = ThumbnailReply(decoded).sourceSize
                let reference = engine.directory.appendingPathComponent("lab-brightness-\(id).png")
                defer { try? FileManager.default.removeItem(at: reference) }
                if let solved = try? await Self.solveBrightnessMatch(engine: engine, source: photo, generation: generation, size: size, raw: raw,
                                                                    request: matchSolveState(state), reference: reference,
                                                                    declared: raw ? ThumbnailReply(decoded).previewColourSpace : nil),
                   let matched = Self.matching(state, ev: solved.exposure, limited: solved.limited, inputs: matchInputs(state)) {
                    state = matched
                }
            }
            let (_, result) = try await engine.request(command(state))
            let reply = ThumbnailReply(result)
            let (width, height) = (Int(reply.width), Int(reply.height))
            let display = reply.displayColorSpace
            let size = reply.sourceSize
            let developed = try await Task.detached(priority: .userInitiated) {
                try Self.thumbnailImage(Data(contentsOf: buffer), width: width, height: height, displaySpace: display)
            }.value
            guard !closing else { return nil }
            sized?(size)
            // Qlick Lab: the whole frame, uncropped and unturned, as the open photograph's develop is kept.
            if whole { return developed }
            return ThumbnailComposer.compose(developed, size: size, crop: state.crop, cut: true, rotation: Int(state.params["io.rotate_cw"].double),
                                             border: nil, texture: nil, strip: nil, longSide: CGFloat(max(width, height)),
                                             space: developed.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? developed
        } catch {
            FileHandle.standardError.write(Data("lab develop \(photo.lastPathComponent): \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// A recipe's text, for developing a photograph under it.
    func labPresetText(_ preset: PresetFile) -> String? { presetTexts[preset] }

    /// Applies a recipe to several photographs as one undo step, as Paste
    /// Edits changes several: the open one in place, the others in their
    /// sidecars. Each keeps what a recipe never carries (the catalog's
    /// `preset_kept`: its white balance, crop, lens correction…).
    /// With `adapting`, each photograph also gets its own Auto white balance (RAW files) and its exposure matched
    /// to the camera's, Exposure at 0: the recipe's look on photographs taken in any light.
    func labApply(_ preset: PresetFile, to items: [URL], adapting: Bool = false) {
        guard canChangePresets, canChangeEdits, !items.isEmpty, let engine else { return }
        // A new recipe replaces the one still being applied: it stops after its batch, and this one starts.
        applyTask?.cancel()
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { self.backgroundWork = nil }
            do {
                let text = try Self.presetText(try await self.presetLibrary.read(preset))
                let (_, result) = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(text), "params": self.plainState.params])
                let (film, paper) = (result["film"].string, result["paper"].string)
                guard self.films.contains(where: { $0.id == film }), self.papers.contains(where: { $0.id == paper }) else {
                    throw EngineError(message: "This version of Qlick Lab doesn’t have the preset’s film or paper.")
                }
                guard !Task.isCancelled else { return }
                let kept = self.catalog["preset_kept"].array.map(\.string), params = result["params"]
                // Qlick Lab: its Develop part, with the box ticked; adapting's own balance and match still win.
                let develop = self.recipeDevelop(text)
                // Those on screen first: the change shows where you look.
                let onScreen = self.thumbnailsOnScreen
                let ordered = items.filter { onScreen.contains($0) } + items.filter { !onScreen.contains($0) }
                let action = adapting ? "Apply Preset “\(preset.name)” with Auto Balance" : "Apply Preset “\(preset.name)”"
                // The recipe, on every photograph at once.
                let before = await self.changeEditsInBatches(ordered, title: "Applying “\(preset.name)”") { _, base in
                    var next = base
                    next.film = film; next.paper = paper; next.params = params
                    for path in kept { next.params[path] = base.params[path] }
                    if let develop { next = develop.applied(to: next, photo: base) }
                    if adapting {
                        next.brightnessMatch = BrightnessMatch()
                        next.params["prep.exposure_ev"] = .number(0)
                    }
                    return next
                }
                if !before.isEmpty { self.registerSidecarUndo(before, action: action) }
                self.libraryNote = LibraryNote(text: "Applied “\(preset.name)”" + (adapting ? ", balancing photograph by photograph" : ""), detail: nil,
                                               count: items.count, serial: (self.libraryNote?.serial ?? 0) + 1)
                for item in items { self.notePresetApplied(preset.url, to: item) }
                // Then each RAW's own white balance, a few at a time, those on screen first. Each change shows as
                // it's made; undo takes back the recipe and the balances together.
                if adapting { await self.balanceInBatches(ordered) }
                // Their large previews after, each replacing the one before.
                guard !Task.isCancelled else { return }
                self.backgroundWork = nil
                let stale = items.filter(self.lab.previewBuilder.needs)
                if !stale.isEmpty { self.lab.previewBuilder.build(stale) }
            } catch {
                self.report(error)
            }
        }
    }

    /// Qlick Lab: a Grain or Halation preset (`SectionPreset`) on the photographs given: only that section's settings
    /// change. The open photograph alone is an ordinary edit; several change together, as a recipe does, in one undo
    /// step, those on screen first.
    func labApplySection(_ preset: SectionPreset, _ section: PresetSection, to items: [URL]) {
        let settings = preset.settings(section)
        guard canChangeEdits, !items.isEmpty, !settings.isEmpty else { return }
        if items == [sourceItem] {
            setParams(settings)
            return
        }
        applyTask?.cancel()
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { self.backgroundWork = nil }
            let onScreen = self.thumbnailsOnScreen
            let ordered = items.filter { onScreen.contains($0) } + items.filter { !onScreen.contains($0) }
            let before = await self.changeEditsInBatches(ordered, title: "Applying “\(preset.name)”") { _, base in
                var next = base
                for (path, value) in settings { next.params[path] = value }
                return next
            }
            if !before.isEmpty { self.registerSidecarUndo(before, action: "Apply \(section.title) “\(preset.name)”") }
            self.libraryNote = LibraryNote(text: "Applied “\(preset.name)”", detail: nil, count: items.count,
                                           serial: (self.libraryNote?.serial ?? 0) + 1)
            guard !Task.isCancelled else { return }
            self.backgroundWork = nil
            let stale = items.filter(self.lab.previewBuilder.needs)
            if !stale.isEmpty { self.lab.previewBuilder.build(stale) }
        }
    }

    /// Stops the recipe being applied (and its balancing): what's done stays, and can be undone.
    func stopApplying() { applyTask?.cancel(); lab.proxyMaker.stopBalancing() }

    /// Qlick Lab: each RAW's own Auto white balance, a few at a time, written as it's found. Stops between batches.
    func balanceInBatches(_ items: [URL]) async {
        let raws = items.filter { Self.rawExtensions.contains($0.photoFile.pathExtension.lowercased()) }
        var done = 0
        for start in stride(from: 0, to: raws.count, by: 8) {
            guard !Task.isCancelled else { break }
            let batch = Array(raws[start..<min(start + 8, raws.count)])
            let offset = done, total = raws.count
            let balances = await autoBalances(batch) { [weak self] index in self?.backgroundWork = ("Balancing", offset + index, total) }
            guard !Task.isCancelled else { break }
            done += batch.count
            await writeBalances(balances, to: batch)
        }
    }

    func writeBalances(_ balances: [URL: (temperature: Double, tint: Double)], to items: [URL]) async {
        let items = items.filter { balances[$0.photoFile] != nil }
        guard !items.isEmpty else { return }
        _ = await changeEditsInBatches(items, title: nil) { item, base in
            guard let found = balances[item.photoFile] else { return base }
            var next = base
            next.params["io.raw_white_balance.mode"] = .string("custom")
            next.params["io.raw_white_balance.temperature"] = .number((found.temperature / 10).rounded() * 10)
            next.params["io.raw_white_balance.tint"] = .number(found.tint)
            return next
        }
    }

    /// Qlick Lab: an import's photographs, given their recipe at once, get their own Auto white balance afterwards,
    /// in the background: from each one's proxy as soon as it's made (no RAW read again), or, without proxies made
    /// ahead, a few at a time. A recipe applied meanwhile, or Stop, ends it.
    func labBalanceImported(_ photos: [URL]) {
        let raws = photos.filter { Self.rawExtensions.contains($0.photoFile.pathExtension.lowercased()) }
        guard !raws.isEmpty else { return }
        if PreviewStorage.buildsProxiesAhead {
            lab.proxyMaker.balanceAfter(raws)
            return
        }
        let onScreen = thumbnailsOnScreen
        let ordered = raws.filter { onScreen.contains($0) } + raws.filter { !onScreen.contains($0) }
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { self.backgroundWork = nil }
            await self.balanceInBatches(ordered)
        }
    }

    /// Qlick Lab: one photograph's Auto white balance, through a helper already running (its proxy answers at once),
    /// written to its edits.
    func labBalance(_ photo: URL, with helper: EngineClient) async {
        let balances = await autoBalances([photo], helper: helper)
        // Open in front of you: an edit of its own, which undo takes back, rather than a sidecar changed under it.
        if let open = sourceItem, open.photoFile == photo.photoFile, let found = balances[photo.photoFile] {
            var next = state
            next.params["io.raw_white_balance.mode"] = .string("custom")
            next.params["io.raw_white_balance.temperature"] = .number((found.temperature / 10).rounded() * 10)
            next.params["io.raw_white_balance.tint"] = .number(found.tint)
            apply(next, action: "Auto White Balance")
            return
        }
        await writeBalances(balances, to: [photo])
    }

    /// Qlick Lab: `changeEdits` for many photographs without holding up the lab. Their sidecars are read off the
    /// main thread a batch at a time, changed here, queued and written, and the contact sheet learns each batch's
    /// looks at once. Returns the sidecars as they were, for one undo; registers none itself. Stops between batches
    /// when cancelled. The open photograph changes as `changeEdits` changes it.
    func changeEditsInBatches(_ items: [URL], title: String?, each transform: @escaping (URL, EditState) -> EditState) async -> [URL: JSONValue?] {
        guard canChangeEdits, sidecarsEnabled, let sidecars, sidecars.writes, let lookup = sidecarLookup else {
            if let open = sourceItem, items.contains(open) { apply(transform(open, state), action: title ?? "Change Edits") }
            return [:]
        }
        flushSidecar()
        var before: [URL: JSONValue?] = [:]
        let open = sourceItem
        if let open, items.contains(open), let context = photoSidecar, context.photo == open.photoFile, context.blocked == nil, !context.awaitingCatalog,
           PhotoLibrary.canWrite(beside: open.photoFile) {
            before[open.photoFile] = .some(try? sidecars.readPending(photo: open.photoFile))
            replaceState(transform(open, state))
            flushSidecar()
            // Its own history is of edits that are gone.
            undoManager?.removeAllActions(withTarget: self)
            library.reload(open.photoFile)
        }
        let others = items.filter { $0 != open }
        var current: [URL: JSONValue?] = [:]
        for start in stride(from: 0, to: others.count, by: 64) {
            if Task.isCancelled { break }
            if let title { backgroundWork = (title, start, others.count) }
            let batch = Array(others[start..<min(start + 64, others.count)])
            let read = await Task.detached(priority: .userInitiated) { () -> [(item: URL, raw: JSONValue?)?] in
                var writable: [URL: Bool] = [:]
                return batch.map { item in
                    let folder = item.photoFile.deletingLastPathComponent()
                    let canWrite = writable[folder] ?? PhotoLibrary.canWrite(in: folder)
                    writable[folder] = canWrite
                    guard canWrite else { return nil }
                    // No sidecar yet is nil here, and fine; only one that can't be read is left out.
                    do { return (item, try sidecars.readPending(photo: item.photoFile)) } catch { return nil }
                }
            }.value
            var reads: [URL: [LibraryItemRead]] = [:]
            for entry in read {
                guard let (item, read) = entry else { continue }
                let photo = item.photoFile
                // A photograph's duplicates in the same batch build on each other.
                let raw = current[photo] ?? read
                do {
                    let sidecar = try raw.map(PhotoSidecar.init(raw:))
                    let variant = item.variantID.map { id in sidecar?.variants.first { $0.id == id } } ?? sidecar?.variants.first
                    if item.variantID != nil, variant == nil { continue }
                    if before[photo] == nil { before[photo] = .some(read) }
                    let version = sidecar?.defaultsVersion ?? SidecarDefaults.latest
                    let table = try SidecarDefaults.load(version: version, data: lookup.data)
                    let saved = try variant?.edits.map { try PhotoSidecar.decodeEdits($0, table: table) }
                    let base = saved.map { restoredState($0.state, legacy: false) } ?? plainState
                    let edits = PhotoSidecar.encodeEdits(transform(item, base), matchSolved: false, table: table)
                    let patch = SidecarPatch(variant: variant?.id ?? SidecarRestore.newVariantID(), primary: item.variantID == nil,
                                             edits: .some(edits), known: known(table), defaultsVersion: version, app: Self.appVersion)
                    sidecars.enqueue(patch, for: photo)
                    let next = try patch.applied(to: raw)
                    current[photo] = .some(next)
                    reads[photo] = try next.map { try PhotoSidecar(raw: $0).items(of: photo) } ?? [LibraryItemRead(item: photo)]
                } catch {
                    continue
                }
            }
            library.update(reads)
            writeSidecars()
            await Task.yield()
        }
        return before
    }

    /// Qlick Lab: each RAW photograph's Auto white balance, as the engine finds it (its preview's proxy answers at
    /// once; otherwise it reads the photograph), in a helper of its own. Photographs it can't balance are left out.
    func autoBalances(_ items: [URL], helper given: EngineClient? = nil, progress: ((Int) -> Void)? = nil) async -> [URL: (temperature: Double, tint: Double)] {
        let photos = Array(Set(items.map(\.photoFile))).filter { Self.rawExtensions.contains($0.pathExtension.lowercased()) }
        guard !photos.isEmpty, let paths = labEnginePaths, let helper = given ?? (try? EngineClient(paths: paths, quality: .utility)) else { return [:] }
        if given == nil {
            helper.label = "balance"
        }
        defer { if given == nil { Task.detached(priority: .utility) { helper.stop() } } }
        // A helper shared with other work takes a generation of its own, so it doesn't mistake its source for this one.
        let generationBase = given == nil ? 0 : Double(UInt32.random(in: 1_000_000...UInt32.max))
        var found: [URL: (temperature: Double, tint: Double)] = [:]
        for (index, photo) in photos.enumerated() {
            // Qlick Lab: stopped, or replaced by another recipe.
            if Task.isCancelled { break }
            progress?(index)
            if let known = lab.asShot.autos[photo] { found[photo] = known; continue }
            if given == nil { status = "Balancing \(index + 1) of \(photos.count)…" }
            let state = labEdits(for: photo).state
            let command: [String: JSONValue] = ["command": EngineCommand.prepareBalance.json, "input": .string(photo.path),
                                                "source_generation": .number(generationBase + Double(index + 1)), "params": state.params,
                                                "read_long_side": .number(1024)]
            // The helper reads in the background and answers at once; asked again, it says once it's done.
            for _ in 0..<60 {
                guard let (_, result) = try? await helper.request(command) else { break }
                if result["ready"].bool {
                    let auto = result["auto"].array.map(\.double), asShot = result["as_shot"].array.map(\.double)
                    if auto.count == 2 { found[photo] = (auto[0], auto[1]) }
                    if asShot.count == 2 { lab.asShot.set(photo, (asShot[0], asShot[1]), auto: auto.count == 2 ? (auto[0], auto[1]) : nil) }
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // The camera's own Auto as the lab reads it, when the engine found none.
            if found[photo] == nil {
                let fallback = await Task.detached(priority: .utility) { () -> (temperature: Double, tint: Double)? in
                    guard let asShot = WhiteBalanceMath.asShot(of: photo) else { return nil }
                    return WhiteBalanceMath.auto(of: photo, asShot: asShot)
                }.value
                if let fallback { found[photo] = fallback }
            }
        }
        return found
    }

    /// A copy of a recipe under a new name: a version to change without losing the first.
    func labDuplicate(_ preset: PresetFile) {
        Task {
            do {
                let data = try await presetLibrary.read(preset)
                let taken = Set(presets.map { PresetName.key($0.name) })
                _ = try await presetLibrary.add(data, name: PresetName.unique(preset.name, taken: taken))
                await refreshPresets()
            } catch { report(error) }
        }
    }
}
