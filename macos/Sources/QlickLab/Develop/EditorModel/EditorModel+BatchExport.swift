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
    // MARK: Batch export

    /// What Export acts on: the open photograph in the edit view, the selection in the grid.
    var exportTargets: [URL] { ratingTargets }
    /// Export is a single export: the edit view's photograph, or the open one alone selected in the grid.
    var exportsSingle: Bool {
        mode == .photo || (!sourceDeleted && sourceItem.map { exportTargets == [$0] } ?? false)
    }
    /// The menu also needs no crop being drawn; crop has its own Return and Esc then.
    var canExport: Bool {
        guard ready, !exporting, !saving, !batchRunning else { return false }
        return exportsSingle ? source != nil : !exportTargets.isEmpty && hasCatalog && engine != nil
    }
    /// "Export Photograph…", or "Export 12 Photographs…" for a grid selection.
    var exportTitle: String {
        let count = exportsSingle ? 1 : exportTargets.count
        return count > 1 ? "Export \(count) Photographs…" : "Export Photograph…"
    }
    var batchRunning: Bool { batch?.running == true }

    /// Export: a single export, or a batch of the grid's selection.
    func exportPanel() {
        // Already open (perhaps out of sight): brought forward.
        if LabPanel.bringForward() { return }
        guard canExport, !cropping else { return }
        if exportsSingle { return savePanel(export: true) }
        batchPanel(exportTargets)
    }

    /// Picks a folder for `targets`, or for a single photograph that isn't
    /// open a file as today's single export does, then starts the batch.
    func batchPanel(_ targets: [URL]) {
        let single = targets.count == 1
        let panel: NSSavePanel
        if single { panel = NSSavePanel() } else {
            let open = NSOpenPanel()
            open.canChooseFiles = false; open.canChooseDirectories = true; open.allowsMultipleSelection = false
            open.prompt = "Export"
            panel = open
        }
        panel.title = single ? "Export Photograph" : "Export \(targets.count) Photographs"
        panel.canCreateDirectories = true
        if let folder = Self.lastSaveFolder { panel.directoryURL = folder }
        // The first photograph's name, to show what the naming does. Its edits, beside it on its disk, are read off
        // the main thread: until they come, the name is a never-edited photograph's.
        var named = BatchOptions()
        named.format = OutputFormat.last.rawValue
        var first = batchItems([targets[0]], options: named, restores: [:])[0]
        var chosenFormat = OutputFormat.last
        let rows = single ? nil : BatchRows { naming, custom in
            var options = BatchOptions(); options.naming = naming; options.custom = custom
            options.format = chosenFormat.rawValue
            return options.fileName(name: Self.batchName(first.item, title: first.title), film: first.state.film)
        }
        let previewSpace = previewSpace
        let count = targets.count
        let picker = FormatPicker(panel: panel, selected: OutputFormat.last, engine: ExportEngine.selected, size: ExportSize.last,
                                  restrictsType: single, extraRows: rows?.views ?? []) { engine, size, save in
            let extras = (size.summary.map { " \($0)." } ?? "") + (save.summary(export: true, previewSpace: previewSpace).map { " \($0)." } ?? "")
            let what = count == 1 ? "With its own edits, crop and border." : "Each of the \(count) photographs with its own edits, crop and border, one after another."
            return switch engine {
            case .fast?: "\(what) Fast looks the same as Reference, in a fraction of the time.\(extras)"
            default: "\(what) Reference is the most precise; about half a minute for each large photo.\(extras)"
            }
        }
        // Qlick Lab: one photograph, the open one: the message ends with its file's estimated weight.
        if single, targets[0] == sourceItem, photographSize != .zero { picker.photograph = photographSize; picker.refreshMessage() }
        rows?.changed = { [weak picker] in picker?.refreshMessage() }
        picker.formatChanged = { [weak picker, weak rows] in
            if let picker { chosenFormat = picker.format }
            rows?.refresh()
        }
        if single { panel.nameFieldStringValue = first.fileName }
        let guessed = first.fileName
        Task { [weak self, weak panel, weak rows] in
            guard let self, case let restores = await self.readRestores([targets[0]]), !restores.isEmpty else { return }
            first = self.batchItems([targets[0]], options: named, restores: restores)[0]
            // The name follows, unless it was typed meanwhile.
            if single, let panel, panel.nameFieldStringValue == guessed { panel.nameFieldStringValue = first.fileName }
            rows?.refresh()
        }
        LabPanel.begin(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let folder = single ? url.deletingLastPathComponent() : url
            OutputFormat.last = picker.format
            ExportSize.last = picker.size
            picker.remember(); rows?.remember()
            Self.lastSaveFolder = folder
            let engine = picker.engine ?? .reference
            ExportEngine.selected = engine
            let save = picker.settings, size = picker.size
            var options = BatchOptions(format: picker.format.rawValue, engine: engine.rawValue, edge: size.edge.rawValue, pixels: size.pixels,
                                       bitDepth: save.bitDepth, colorSpace: save.colorSpace, jpegQuality: save.jpegQuality,
                                       lowMemory: self.lowMemoryExport)
            options.saveSettings = save
            // The save panel asked before replacing.
            if let rows { options.naming = rows.naming; options.custom = rows.custom; options.existing = rows.existing } else { options.existing = .replace }
            Task { await self.exportBatch(targets, to: folder, options: options, named: single ? url.lastPathComponent : nil) }
        }
    }

    /// The name `{name}` stands for: the file's without its extension, a
    /// duplicate's number after it (`IMG_0412 (2)`).
    nonisolated static func batchName(_ item: URL, title: String) -> String {
        let photo = item.photoFile
        let suffix = title.hasPrefix(photo.lastPathComponent) ? String(title.dropFirst(photo.lastPathComponent.count)) : ""
        return photo.deletingPathExtension().lastPathComponent + suffix
    }

    /// Starts exporting `targets` to `folder`, with their edits as they are
    /// now; `named` names a batch of one. Nil if it couldn't start.
    @discardableResult
    func exportBatch(_ targets: [URL], to folder: URL, options: BatchOptions, named: String? = nil) async -> BatchRun? {
        if let open = sourceItem, targets.contains(open) { await settleBrightnessMatch() }
        guard canStartBatch else { return nil }
        let restores = await readRestores(targets)
        guard canStartBatch else { return nil }
        var items = batchItems(targets, options: options, restores: restores)
        if let named, items.count == 1 { items[0].fileName = named }
        // Replacing a photograph's own file is refused, as for a single export. The disks are asked off the main
        // thread, with the folder's bookmark.
        let pairs = options.existing == .replace ? items.map { (folder.appendingPathComponent($0.fileName), $0.item.photoFile) } : []
        let (replacesOriginal, bookmark) = await Task.detached(priority: .userInitiated) {
            (pairs.contains { Self.sameFile($0.0, $0.1) }, try? folder.bookmarkData())
        }.value
        if replacesOriginal {
            error = items.count == 1 ? "Choose a different filename to preserve the original photograph."
                : "Choose a different folder or file name to preserve the original photographs."
            return nil
        }
        let journal = BatchJournal(destination: folder, bookmark: bookmark, options: options, items: items)
        return startBatch(journal)
    }

    /// One exporter at a time: not during a single export either.
    var canStartBatch: Bool { !closing && !batchRunning && !exporting && hasCatalog && engine != nil }

    /// The saved edits of `targets` (all but the open photograph), read beside each on its disk off the main thread,
    /// at the disks' speed; none for a disk that's offline (the export finds out), nor without sidecars.
    func readRestores(_ targets: [URL]) async -> [URL: SidecarRestore] {
        guard let lookup = sidecarLookup else { return [:] }
        let open = sourceDeleted ? nil : sourceItem
        let wanted = targets.filter { !($0 == open && source != nil) }
        guard !wanted.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var restores: [URL: SidecarRestore] = [:]
            for target in wanted where !VolumeReach.offline(target.photoFile.path) {
                restores[target] = SidecarRestore.read(photo: target.photoFile, variant: target.variantID, store: lookup.store, data: lookup.data)
            }
            return restores
        }.value
    }

    /// Each target's edits as they are now, and the name it gets: `restores` holds the saved edits read beforehand
    /// (`readRestores`); a target without one is taken as never edited.
    func batchItems(_ targets: [URL], options: BatchOptions, restores: [URL: SidecarRestore]) -> [BatchItem] {
        let open = sourceDeleted ? nil : sourceItem
        let current = state
        var items = targets.map { target -> BatchItem in
            let photo = target.photoFile
            let raw = Self.rawExtensions.contains(photo.pathExtension.lowercased())
            let title = library.name(of: target)
            var item = BatchItem(item: target, title: title, state: current, needsMatch: false, storesMatch: false,
                                 rating: ExportRating.value(library.summary(for: target)), fileName: "")
            func matchable(_ state: EditState) -> Bool {
                state.brightnessMatch != nil && (raw || state.params["io.input_interpretation.mode"].string == "auto")
            }
            if target == open, source != nil {
                // As on screen, its match settled.
                let size = image != nil ? imageSize : placeholderSize
                item.size = size == .zero ? nil : size
            } else if let restore = restores[target], let saved = restore.edits, restore.problem == nil {
                item.state = restoredState(saved.state, legacy: false, matchSolved: saved.matchSolved)
                item.needsMatch = !saved.matchSolved && matchable(item.state)
                item.storesMatch = true
                item.look = library.looks[target]
                let film = item.state.film, paper = item.state.paper
                let missing = [films.contains { $0.id == film } ? nil : "the film “\(film)”", papers.contains { $0.id == paper } ? nil : "the paper “\(paper)”"].compactMap { $0 }
                if !missing.isEmpty {
                    item.status = .failed
                    item.reason = "Edited with \(missing.joined(separator: " and ")), which this version of Qlick Lab doesn’t have."
                }
            } else {
                // Never edited: as opening it now would show it.
                item.state = newPhotoState(after: current)
                item.needsMatch = matchable(item.state)
            }
            item.fileName = options.fileName(name: Self.batchName(target, title: title), film: item.state.film)
            // Qlick Lab: what its file will say of its development.
            let recipe = target == open ? appliedPreset.flatMap { url in presets.first { $0.url == url }?.name } : restores[target]?.recipe
            item.xmp = labXMP(state: item.state, summary: library.summary(for: target), recipe: recipe, photo: photo, metadata: .all)
            return item
        }
        let names = BatchNames.unique(items.map(\.fileName))
        for index in items.indices { items[index].fileName = names[index] }
        return items
    }

    @discardableResult
    func startBatch(_ journal: BatchJournal) -> BatchRun? {
        guard canStartBatch else { return nil }
        let run = BatchRun(journal: journal, journalURL: batchJournalURL)
        batch = run
        requestNotificationPermission()
        launchBatch(run)
        return run
    }

    func launchBatch(_ run: BatchRun) {
        run.running = true; run.cancelled = false
        run.task = Task { [weak self] in await self?.runBatch(run) }
    }

    /// Exports what's waiting, one photograph at a time, writing the journal
    /// after each. At quit the journal stays for the next launch.
    func runBatch(_ run: BatchRun) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting photographs")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? run.journal.write(to: run.journalURL)
        while !run.cancelled, !closing, let index = run.journal.items.firstIndex(where: { $0.status == .waiting }) {
            run.current = index
            run.journal.items[index] = await exportBatchItem(run.journal.items[index], of: run)
            if run.journal.items[index].status == .waiting { break }
            try? run.journal.write(to: run.journalURL)
        }
        run.current = nil
        guard !closing else { return }
        run.running = false
        BatchJournal.remove(at: run.journalURL)
        if let engine = batchEngine {
            batchEngine = nil
            await Task.detached(priority: .utility) { engine.stop() }.value
        }
        batchFinished(run)
        pumpThumbnails()
    }

    /// One photograph: its match solved if it needs one, then today's
    /// exporter. Still waiting if it was cancelled.
    func exportBatchItem(_ item: BatchItem, of run: BatchRun) async -> BatchItem {
        var item = item
        func failed(_ reason: String) -> BatchItem { item.status = .failed; item.reason = reason; return item }
        let photo = item.item.photoFile, folder = run.journal.destination, options = run.journal.options
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return failed("The folder “\(folder.lastPathComponent)” is missing.")
        }
        guard fm.fileExists(atPath: photo.path) else { return failed("The photograph is missing.") }
        guard let paths = engine?.paths, let scratch = engine?.scratch else { return failed("The engine isn’t running.") }
        var name = item.fileName
        func taken(_ name: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        if taken(name) {
            switch options.existing {
            case .skip:
                item.status = .skipped; item.reason = "\(name) already exists."
                return item
            case .number: name = BatchNames.numbered(name, taken: taken)
            case .replace: break
            }
        }
        let destination = folder.appendingPathComponent(name)
        guard !Self.sameFile(destination, photo) else { return failed("It would replace the photograph’s own file.") }
        var state = item.state, size = item.size
        let border = state.border
        let needsSize = size == nil && border.enabled && border.export && border.style == .film35
        if item.needsMatch || needsSize {
            do {
                let solved = try await solveBatchMatch(item, paths: paths)
                state = solved.state; size = solved.size
            } catch is CancellationError {
                return item
            } catch {
                // Unmatched, as the photograph would open; a 35mm border needs the size.
                if needsSize { return failed(error.localizedDescription) }
            }
            if run.cancelled || closing { return item }
        }
        var exportState = state
        exportState.params["settings.serial_grain"] = .bool(options.lowMemory)
        let job = ExportJob()
        run.job = job
        defer { run.job = nil }
        do {
            try await job.run(paths: paths, scratch: scratch, source: photo, destination: destination, state: exportState,
                              crop: state.crop.cropped ? state.crop : nil, border: state.border.exported(for: state.crop.size(of: size ?? .zero)),
                              size: options.size, save: options.save, engine: options.exportEngine, xmp: batchXMP(item, state: state, save: options.save))
            ExportEstimate.recordLater(destination, save: options.save)
            item.status = .done; item.written = destination; item.reason = nil
        } catch is CancellationError {
            return item
        } catch {
            return failed(error.localizedDescription)
        }
        return item
    }

    /// A batch photograph's XMP, with its film and paper as it develops (`state`) and the metadata `save` keeps.
    func batchXMP(_ item: BatchItem, state: EditState, save: SaveSettings) -> LabXMP {
        var xmp = item.xmp ?? LabXMP(rating: item.rating, photo: item.item.photoFile)
        let scanned = state.params["io.scan_film"].bool
        xmp.film = filmName(state.film); xmp.paper = scanned ? nil : paperName(state.paper)
        xmp.personal = save.metadata != .none
        return xmp
    }

    /// Solves Match camera brightness for a batch photograph in the batch's
    /// own helper, and stores it if its edits are unchanged. Also gives its
    /// size, which the helper reads with the decode.
    func solveBatchMatch(_ item: BatchItem, paths: EnginePaths) async throws -> (state: EditState, size: CGSize) {
        let photo = item.item.photoFile
        let raw = Self.rawExtensions.contains(photo.pathExtension.lowercased())
        let engine: EngineClient
        if let running = batchEngine { engine = running } else { engine = try EngineClient(paths: paths); batchEngine = engine }
        batchGeneration += 1
        let generation = batchGeneration
        let buffer = engine.directory.appendingPathComponent("batch-decode.rgba")
        defer { try? FileManager.default.removeItem(at: buffer) }
        var state = item.state
        let (_, decoded) = try await engine.request([
            "command": EngineCommand.thumbnail.json, "input": .string(photo.path), "source_generation": .number(Double(generation)),
            "film": .string(state.film), "paper": .string(state.paper), "params": state.params,
            "long_side": .number(16), "preview_path": .string(buffer.path),
        ])
        let size = ThumbnailReply(decoded).sourceSize
        guard item.needsMatch else { return (state, size) }
        let reference = engine.directory.appendingPathComponent("batch-brightness.png")
        defer { try? FileManager.default.removeItem(at: reference) }
        let solved = try await Self.solveBrightnessMatch(engine: engine, source: photo, generation: generation, size: size, raw: raw,
                                                         request: matchSolveState(state), reference: reference)
        guard let matched = Self.matching(state, ev: solved.exposure, limited: solved.limited, inputs: matchInputs(state)) else { return (state, size) }
        state = matched
        // Stored as opening it would, unless it was edited since Export.
        if item.storesMatch, let lookup = sidecarLookup, let sidecar = try? lookup.store.read(photo: photo),
           let variant = item.item.variantID.map({ id in sidecar.variants.first { $0.id == id } }) ?? sidecar.variants.first,
           let stored = variant.edits, PhotoSidecar.look(of: stored, defaultsVersion: sidecar.defaultsVersion) == item.look,
           let table = try? SidecarDefaults.load(version: sidecar.defaultsVersion, data: lookup.data),
           storeSolvedMatch(state, item: item.item, variant: variant.id, stored: stored, sidecar: sidecar, table: table) != nil {
            library.reload(photo)
        }
        return (state, size)
    }

    /// The failed photographs again.
    func retryBatch() {
        guard let run = batch, !run.running, !closing else { return }
        for index in run.journal.items.indices where run.journal.items[index].status == .failed {
            run.journal.items[index].status = .waiting; run.journal.items[index].reason = nil
        }
        guard run.journal.remaining > 0 else { return }
        launchBatch(run)
    }

    /// Forgets a finished batch, once its popover is closed.
    func clearBatch() {
        guard let run = batch, !run.running else { return }
        batch = nil
    }

    /// The batch's files selected in the Finder, or its folder.
    func showBatchInFinder() {
        guard let run = batch else { return }
        let written = run.items.compactMap(\.written).filter { FileManager.default.fileExists(atPath: $0.path) }
        if written.isEmpty { NSWorkspace.shared.open(run.journal.destination) } else { NSWorkspace.shared.activateFileViewerSelecting(written) }
    }

    func batchFinished(_ run: BatchRun) {
        let exported = run.exported.count, failed = run.failures.count
        let folder = run.journal.destination.lastPathComponent
        let text = (exported == 1 ? "Exported 1 photograph" : "Exported \(exported) photographs") + " to “\(folder)”"
            + (failed > 0 ? "; \(failed) failed" : "") + (run.skipped.isEmpty ? "" : "; \(run.skipped.count) skipped")
        status = run.cancelled ? "Export cancelled. " + text : text
        if !run.needsAttention, !batchPopoverShown { batch = nil }
        Support.exported(exported, model: self)
        if Self.notificationsAvailable, NSApp?.isActive == false, !run.cancelled { notifyBatchFinished(exported: exported, failed: failed, folder: folder) }
    }


    /// A batch the last session didn't finish, offered once launch has settled.
    func offerBatchResume() {
        guard batch == nil, !closing else { return }
        let url = batchJournalURL
        Task { [weak self] in
            guard let journal = await Task.detached(priority: .utility, operation: { BatchJournal.read(from: url) }).value else { return }
            guard let self, !self.closing, self.batch == nil else { return }
            guard journal.remaining > 0 else { return BatchJournal.remove(at: url) }
            let count = journal.remaining
            let answer = await self.ask(AppAlert(
                title: "Resume exporting \(count == 1 ? "1 photograph" : "\(count) photographs") to “\(journal.destination.lastPathComponent)”?",
                detail: "Qlick Lab quit before the export finished. Each photograph exports with its edits as they were when you chose Export.",
                buttons: [.init(title: "Resume"), .init(title: "Discard")]))
            guard answer.button == 0 else { return BatchJournal.remove(at: url) }
            // Started now, without the open photograph's state.
            if self.startBatch(journal) == nil { self.error = "The export couldn’t resume yet. Try again once Qlick Lab has started." }
        }
    }
}
