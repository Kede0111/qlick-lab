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
    // MARK: Qlick Lab — import

    /// A recipe as the edits of a photograph that has none yet: what the import writes for each photograph it's
    /// given to. Through the engine's `preset_import`, as applying it in Recipes does.
    func labRecipeState(_ preset: PresetFile) async -> EditState? {
        guard hasCatalog, let engine else { return nil }
        do {
            let text = try Self.presetText(try await presetLibrary.read(preset))
            let base = plainState
            let (_, result) = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(text), "params": base.params])
            let (film, paper) = (result["film"].string, result["paper"].string)
            guard films.contains(where: { $0.id == film }), papers.contains(where: { $0.id == paper }) else { return nil }
            var next = base
            next.film = film; next.paper = paper; next.params = result["params"]
            // Qlick Lab: its Develop part, with the box ticked; the import's balance and match are written after.
            if let develop = recipeDevelop(text) { next = develop.applied(to: next, photo: base) }
            return next
        } catch {
            return nil
        }
    }

    /// Writes what an import decided for a photograph it just copied and checked: its rating, its mark, how it's
    /// turned and its recipe, in its sidecar (or inside a DNG, where Settings keeps them). False when nothing could
    /// be written. Queued: `labFlushSidecars` writes them.
    @discardableResult func labWriteImported(_ photo: URL, marks: ImportMarks, recipe: EditState?,
                                             balance: (temperature: Double, tint: Double)? = nil, matchExposure: Bool = false) -> Bool {
        let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:))
        let wantsEdits = recipe != nil || marks.rotation % 4 != 0
        guard wantsEdits || marks.rating > 0 || flag != nil else { return true }
        guard sidecarsEnabled, let sidecars, sidecars.writes, PhotoLibrary.canWrite(beside: photo) else { return false }
        var patch = SidecarPatch(variant: SidecarRestore.newVariantID(), primary: true, defaultsVersion: SidecarDefaults.latest, app: Self.appVersion)
        if marks.rating > 0 { patch.rating = marks.rating }
        if let flag { patch.flag = .some(flag) }
        var wrote = true
        if wantsEdits {
            if hasCatalog, let data = engine?.paths.data, let table = try? SidecarDefaults.load(version: SidecarDefaults.latest, data: data) {
                var state = recipe ?? plainState
                if marks.rotation % 4 != 0 { state.params["io.rotate_cw"] = .number(Double(((marks.rotation % 4) + 4) % 4)) }
                if recipe != nil {
                    if let balance, Self.rawExtensions.contains(photo.pathExtension.lowercased()) {
                        state.params["io.raw_white_balance.mode"] = .string("custom")
                        state.params["io.raw_white_balance.temperature"] = .number((balance.temperature / 10).rounded() * 10)
                        state.params["io.raw_white_balance.tint"] = .number(balance.tint)
                    }
                    if matchExposure {
                        state.brightnessMatch = BrightnessMatch()
                        state.params["prep.exposure_ev"] = .number(0)
                    }
                }
                patch.edits = .some(PhotoSidecar.encodeEdits(state, matchSolved: false, table: table))
                patch.known = known(table)
            } else {
                wrote = false
            }
        }
        sidecars.enqueue(patch, for: photo)
        return wrote
    }

    /// Writes the queued sidecar changes; the photographs it couldn't write, with why.
    @discardableResult func labFlushSidecars() async -> [URL: String] { await sidecars?.flush() ?? [:] }


    /// Qlick Lab: keeps `savingLeft` up to date until everything is written.
    func labWatchSaving() {
        guard savingWatch == nil, let sidecars else { return }
        savingWatch = Task { [weak self] in
            while !Task.isCancelled {
                let left = sidecars.pendingCount
                guard let self else { return }
                self.savingLeft = left
                if left == 0 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.savingWatch = nil
        }
    }

    func shutdown() {
        cancelBrightnessMatch()
        matchCache.flush()

        closing = true; pendingRender?.cancel(); activityTimer?.cancel()
        if let powerStateObserver { NotificationCenter.default.removeObserver(powerStateObserver); self.powerStateObserver = nil }
        thumbnailTask?.cancel(); thumbnailIdle?.cancel()
        thumbnailsDeveloping.values.forEach { $0.task.cancel() }; thumbnailEngines.values.forEach { $0.stop() }
        exportJob?.cancel(); batch?.job?.cancel(); batchEngine?.stop(); engine?.stop()
        // Qlick Lab's own helpers.
        lab.previewBuilder.shutdown(); lab.proxyMaker.shutdown(); lab.compareModel.developer.shutdown()
        // An import under way stops after its file; its journal takes it up next time.
        lab.importer.runner?.cancel()
    }
    func report(_ error: Error) { self.error = error.localizedDescription; status = "Could not complete the operation" }
}
