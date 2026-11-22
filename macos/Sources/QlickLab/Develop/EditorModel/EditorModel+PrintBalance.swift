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
    // MARK: Print balance

    var canBalancePrint: Bool { hasCatalog && engine != nil && !balancingPrint && !cropping && !state.params["io.scan_film"].bool }

    /// Solves the enlarger's magenta and yellow shifts so a mid-grey prints
    /// neutral with the current settings (upstream's print balance), and
    /// sets them as one undoable edit. Doesn't depend on the photograph.
    func balancePrint() {
        guard canBalancePrint, let engine else { return }
        let snapshot = state
        balancingPrint = true
        status = "Balancing print…"
        Task {
            defer { balancingPrint = false }
            do {
                let (_, result) = try await engine.request(["command": EngineCommand.balancePrint.json, "film": .string(snapshot.film),
                                                            "paper": .string(snapshot.paper), "params": snapshot.params])
                let m = result["m_filter_shift"].double, y = result["y_filter_shift"].double
                var next = state
                next.params["enlarger.m_filter_shift"] = .number(m)
                next.params["enlarger.y_filter_shift"] = .number(y)
                apply(next, action: "Balance Print")
                status = "Print balanced: magenta \(m.formatted(.number.precision(.fractionLength(2)))), yellow \(y.formatted(.number.precision(.fractionLength(2))))"
            } catch { report(error) }
        }
    }

    func exportLUTPanel() {
        guard canExportLUT else { return }
        let panel = NSSavePanel()
        panel.title = "Export LUT"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = "\(state.film)_\(state.params["io.scan_film"].bool ? "direct_scan" : state.paper).cube"
        panel.message = "33 × 33 × 33 CUBE · sRGB input and output. Uses the current film and paper color settings. Auto exposure, print filter shifts, preflash, grain, halation, glare, diffusion, blur, sharpening, RAW development, and Post edits are excluded."
        if let path = UserDefaults.standard.string(forKey: "lastLUTFolder") {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastLUTFolder")
            Task { await self.exportLUT(to: url) }
        }
    }

    func exportLUT(to url: URL) async {
        guard canExportLUT, let engine else { return }
        if let source, Self.sameFile(url, source) {
            error = "Choose a different filename to preserve the original photograph."; return
        }
        let snapshot = state
        let temporary = engine.directory.appendingPathComponent("lut-\(UUID().uuidString).cube")
        saving = true
        status = "Exporting LUT…"
        defer { saving = false; try? FileManager.default.removeItem(at: temporary) }
        do {
            _ = try await engine.request(["command": EngineCommand.exportLut.json, "film": .string(snapshot.film),
                                          "paper": .string(snapshot.paper), "params": snapshot.params,
                                          "size": .number(33), "output": .string(temporary.path)])
            try await Task.detached {
                try Data(contentsOf: temporary).write(to: url, options: .atomic)
            }.value
            status = "Exported \(url.lastPathComponent)"
        } catch { report(error) }
    }

    func savePanel(export: Bool) {
        guard let source, !cropping, export ? !exporting && !saving : canSave else { return }
        let panel = NSSavePanel()
        panel.title = export ? "Export Photograph" : "Save Preview"
        panel.canCreateDirectories = true
        // Without a directory the panel shows the last folder of any panel,
        // usually the Open panel's, so start where the last save went.
        if let folder = Self.lastSaveFolder { panel.directoryURL = folder }
        var extras = ""
        let photograph = photographSize
        if photograph != .zero { extras += " The photograph is \(Int(photograph.width)) × \(Int(photograph.height)) px." }
        if state.crop.cropped { extras += " Crops the photograph." }
        if let border = state.border.exported(for: photoSize) {
            extras += " Adds the \(border.style.title.lowercased()) border\(border.instagram ? ", extended to a 3:4 portrait" : "")."
        }
        let previewSpace = previewSpace
        let picker = FormatPicker(panel: panel, selected: OutputFormat.last, engine: export ? ExportEngine.selected : nil, size: ExportSize.last) { engine, size, save in
            let extras = extras + (size.summary.map { " \($0)." } ?? "") + (save.summary(export: export, previewSpace: previewSpace).map { " \($0)." } ?? "")
            return switch engine {
            case .reference?: "The most precise result. Can take about half a minute for large photos.\(extras)"
            case .fast?: "Looks the same as Reference, in a fraction of the time.\(extras)"
            case nil: "Saves the preview as shown.\(extras)"
            }
        }
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent)_\(state.film).\(picker.format.type.preferredFilenameExtension ?? "png")"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard !Self.sameFile(url, source) else {
                self.error = "Choose a different filename to preserve the original photograph."; return
            }
            OutputFormat.last = picker.format
            ExportSize.last = picker.size
            picker.remember()
            Self.lastSaveFolder = url.deletingLastPathComponent()
            let engine = picker.engine ?? .reference
            let size = picker.size
            let save = picker.settings
            if export { ExportEngine.selected = engine }
            Task {
                if export { await self.export(to: url, engine: engine, size: size, save: save) } else { await self.savePreview(to: url, size: size, save: save) }
                // Then the preview follows the space just saved in.
                self.choosePreviewSpace(save.spaceName)
            }
        }
    }

    /// The folder of the last save or export, if it still exists.
    static var lastSaveFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "lastSaveFolder") else { return nil }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "lastSaveFolder") }
    }

    /// Path comparison misses case-only differences on case-insensitive
    /// volumes and hard links, so compare file identity when both exist.
    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath().labStandardized == b.resolvingSymlinksInPath().labStandardized { return true }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    /// Saves the current preview with the crop, rotation, border, size, and encoding.
    func saveCommand(to url: URL, size: ExportSize, save: SaveSettings) -> [String: JSONValue] {
        var command: [String: JSONValue] = ["command": EngineCommand.save.json, "render_id": .number(Double(renderID)), "output": .string(url.path),
                                            "rotate_cw": .number(Double(imageRotation)), "save_options": save.json]
        if let crop = Self.cropJSON(state.crop) { command["crop"] = crop }
        if let border = state.border.exported(for: photoSize) {
            command["border"] = .string(border.style.rawValue)
            command["border_options"] = .object(border.options)
            command["instagram"] = .bool(border.instagram)
        }
        if let fit = size.json { command["fit"] = fit }
        return command
    }

    /// A crop for the helper, or nil when uncropped.
    nonisolated static func cropJSON(_ crop: CropSettings) -> JSONValue? {
        guard crop.cropped else { return nil }
        let r = crop.rect
        return .object(["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height), "angle": .number(crop.angle)])
    }

    /// A reduction such as 68%; below 10% with one decimal.
    nonisolated static func percent(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) + "%"
    }

    /// A pending brightness match changes the exposure: Save and Export
    /// wait for it and its preview, so they write what the inspector shows.
    func settleBrightnessMatch() async {
        let deadline = Date().addingTimeInterval(30)
        while !closing, Date() < deadline, brightnessMatchPending || matchingBrightness || !previewCurrent && brightnessMatchActive {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func savePreview(to url: URL, size: ExportSize = .full, save: SaveSettings = SaveSettings()) async {
        await settleBrightnessMatch()
        guard canSave, let engine else { return }
        saving = true
        defer { saving = false }
        do {
            if ExportFinisher.needed(save, destination: url) {
                let written = ExportFinisher.engineFile(for: url), finished = ExportFinisher.engineFile(for: url).deletingPathExtension().appendingPathExtension(url.pathExtension)
                defer { try? FileManager.default.removeItem(at: written); try? FileManager.default.removeItem(at: finished) }
                _ = try await engine.request(saveCommand(to: written, size: size, save: save))
                try await Task.detached(priority: .userInitiated) { try ExportFinisher.finish(written, as: url, into: finished, save: save) }.value
                guard rename(finished.path, url.path) == 0 else { throw EngineError(message: "Could not save \(url.path)") }
            } else {
                _ = try await engine.request(saveCommand(to: url, size: size, save: save))
            }
            status = "Saved \(url.lastPathComponent)"
        } catch { report(error) }
    }

    /// A current preview at export size is what a Fast export would render,
    /// so save it instead of developing the photograph again. Like ExportJob,
    /// write a sibling temporary file and rename it, so a failure leaves an
    /// existing file untouched. False if the preview could not be saved.
    /// Another colour space than the preview's develops again in it.
    func exportPreview(to url: URL, size: ExportSize, save: SaveSettings) async -> Bool {
        guard canSave, renderAtExportSize, save.spaceName == renderSpace, !ExportFinisher.needed(save, destination: url), let engine else { return false }
        saving = true
        defer { saving = false }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".qlick-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard (try? await engine.request(saveCommand(to: staging, size: size, save: save))) != nil else { return false }
        if let rating = currentSummary.flatMap(ExportRating.value) {
            do { try ExportRating.embed(rating, in: staging) } catch { report(error); return true }
        }
        guard rename(staging.path, url.path) == 0 else {
            report(EngineError(message: "Could not move the completed export to \(url.path): \(String(cString: strerror(errno)))"))
            return true
        }
        status = renderOnGPU
            ? "Exported \(url.lastPathComponent)"
            : "Exported \(url.lastPathComponent) on the CPU (32-bit): no GPU was available for Fast export"
        return true
    }

    func export(to url: URL, engine exportEngine: ExportEngine, size: ExportSize = .full, save: SaveSettings = SaveSettings()) async {
        await settleBrightnessMatch()
        // An edit made meanwhile makes the save fail; develop the photograph then.
        if exportEngine == .fast, await exportPreview(to: url, size: size, save: save) { Support.exported(1, model: self); return }
        guard !exporting, !saving, let source, let engine else { return }
        let job = ExportJob(); exportJob = job; exporting = true; exportStarted = Date()
        var exportState = state
        exportState.params["settings.serial_grain"] = .bool(lowMemoryExport)
        defer { exporting = false; exportJob = nil }
        do {
            let outcome = try await job.run(paths: engine.paths, scratch: engine.scratch, source: source, destination: url, state: exportState,
                                            crop: state.crop.cropped ? state.crop : nil, border: state.border.exported(for: photoSize), size: size, save: save,
                                            engine: exportEngine, rating: currentSummary.flatMap(ExportRating.value))
            status = outcome.fellBackToCPU
                ? "Exported \(url.lastPathComponent) on the CPU (32-bit): no GPU was available for Fast export"
                : "Exported \(url.lastPathComponent)"
            Support.exported(1, model: self)
        } catch is CancellationError { status = "Export cancelled" }
        catch { report(error) }
    }
    func cancelExport() { exportJob?.cancel() }
    func flushPreviewCache() async { await previewCache.flush() }
}
