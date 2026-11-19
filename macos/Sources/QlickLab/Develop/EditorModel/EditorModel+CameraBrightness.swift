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
    // MARK: Saving

    var canExportLUT: Bool { hasCatalog && engine != nil && !saving && !exporting && !cropping }

    // MARK: Camera brightness

    /// Prep › Match camera brightness for this photograph.
    var matchesBrightness: Bool { state.brightnessMatch != nil }
    /// Why matching can't run for this photograph, or nil.
    var brightnessMatchUnavailable: String? {
        if let failure = brightnessMatchFailure, failure.generation == sourceGeneration, failure.inputs == nil { return failure.message }
        if !isRaw, state.params["io.input_interpretation.mode"].string != "auto" {
            return "Matching reads the file’s own colour tags. Set Input Colour to Automatic to use it."
        }
        return nil
    }
    var brightnessMatchFailedHere: Bool {
        guard let failure = brightnessMatchFailure, failure.generation == sourceGeneration, let inputs = failure.inputs else { return false }
        return inputs == matchInputs(state)
    }
    /// On, possible, and not failed for the current settings: the meter then
    /// only sets where the highlight limit starts.
    var brightnessMatchActive: Bool { matchesBrightness && brightnessMatchUnavailable == nil && !brightnessMatchFailedHere }
    /// On and not yet solved for the current settings. Save and Export wait.
    var brightnessMatchPending: Bool {
        guard brightnessMatchActive, let match = state.brightnessMatch else { return false }
        return match.ev == nil || match.inputs != matchInputs(state)
    }
    /// The note under the Exposure slider.
    var brightnessMatchNote: String? {
        guard matchesBrightness else { return nil }
        if let unavailable = brightnessMatchUnavailable { return unavailable }
        if brightnessMatchFailedHere, let failure = brightnessMatchFailure { return failure.message }
        if brightnessMatchPending || matchingBrightness { return "Matching…" }
        guard let match = state.brightnessMatch, let ev = match.ev else { return nil }
        let value = ev.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))
        let reference = isRaw ? "the camera" : "the original"
        return match.highlightLimited
            ? "Starts at \(value) EV to match \(reference), held back to protect highlights."
            : "Starts at \(value) EV to match \(reference)."
    }

    /// Turns matching on (from the match, Exposure back to 0) or off (the
    /// brightness stays; Exposure then shows all of it). One undo step.
    func setMatchesBrightness(_ on: Bool) {
        guard on != matchesBrightness else { return }
        var next = state
        if on {
            next.brightnessMatch = BrightnessMatch()
            next.params["prep.exposure_ev"] = .number(0)
        } else {
            next.brightnessMatch = nil
        }
        apply(next, action: on ? "Match Camera Brightness" : "Stop Matching Camera Brightness")
    }

    /// The Exposure slider: the user's exposure above the match.
    var matchedEV: Double { brightnessMatchActive ? state.brightnessMatch?.ev ?? 0 : 0 }
    /// Keeps the engine's total within its ±3 EV.
    var exposureOffsetRange: ClosedRange<Double> {
        let matched = matchedEV
        return (-3 - matched)...(3 - matched)
    }
    var exposureOffset: Binding<Double> {
        Binding(get: { self.value("prep.exposure_ev").double - self.matchedEV }, set: { value in
            let range = self.exposureOffsetRange
            let offset = min(max((value / 0.05).rounded() * 0.05, range.lowerBound), range.upperBound)
            let total = abs(offset) < 1e-9 ? self.matchedEV : self.matchedEV + offset
            self.set("prep.exposure_ev", .number(min(3, max(-3, total))))
        })
    }
    var exposureOffsetModified: Bool { abs(value("prep.exposure_ev").double - matchedEV) > 1e-6 }
    func resetExposureOffset() { set("prep.exposure_ev", .number(matchedEV)) }

    /// What the match depends on: everything that changes how bright the
    /// developed photograph is, except the brightness edits that are the
    /// user's own (Prep, and the enlarger's print exposure) and settings that
    /// can't change it. A change re-solves the match; Prep edits never do.
    func matchInputs(_ state: EditState) -> JSONValue {
        var params = state.params
        for path in ["prep", "enlarger.print_exposure", "post", "effects", "film_render.grain", "io.rotate_cw", "io.crop",
                     "io.crop_center", "io.crop_size", "io.output_color_space", "io.output_cctf_encoding",
                     "settings.serial_grain"] {
            params[path] = .null
        }
        // Qlick Lab: the white balance doesn't move the match. Solving it again reads the whole RAW with the new
        // balance, seconds for a 60 MP file, to shift the exposure by what the balance changed: the photographer
        // sets the balance, then the exposure, as in any RAW developer. (NEgs's own tests keep its behaviour.)
        if Self.matchIgnoresWhiteBalance { params["io.raw_white_balance"] = .null }
        return .object(["film": .string(state.film), "paper": .string(state.paper), "params": params])
    }

    func cancelBrightnessMatch() {
        matchTask?.cancel(); matchTask = nil; matchRequest = nil; matchingBrightness = false
    }

    /// Solves the match when it's on and stale, before the edit renders
    /// (ticket 39): a decode alone first, which the helper keeps for the
    /// render (nearly free when it holds the photograph already), then the
    /// solve on it. One solve at a time; its completion looks again, so
    /// edits made meanwhile coalesce, then renders. A result is applied only
    /// if the inputs it was solved for are still current, without an undo
    /// step of its own: Undo restores a state together with the match solved
    /// for it, and a restored state whose match is stale is solved again.
    func reconcileBrightnessMatch() {
        // Cheap checks first: this runs on every edit, drag frames included.
        guard matchTask == nil, !interacting, !rendering, ready, !cropping, !closing,
              let engine, let source, brightnessMatchPending,
              matchDecodeFailed != FrameID(revision: revision, generation: sourceGeneration) else { return }
        let inputs = matchInputs(state)
        let id = UUID(), generation = sourceGeneration, frame = FrameID(revision: revision, generation: sourceGeneration)
        let request = matchSolveState(renderState)
        let reference = engine.directory.appendingPathComponent("camera-brightness-\(id.uuidString).png")
        // The camera preview is read once a photograph, while the helper
        // decodes; a RAW by its extension (the decode says for sure).
        if matchReference?.generation != generation {
            let raw = Self.rawExtensions.contains(source.pathExtension.lowercased())
            matchReference = (generation, nil, raw ? Task.detached(priority: .userInitiated) { CameraBrightnessReference.Prepared(from: source) } : nil)
        }
        let askDeclared = matchReference?.declared == nil && matchReference?.prepared != nil
        let prepared = matchReference?.prepared
        var decode = decodeOnlyCommand(source: source, generation: generation, state: request, engine: engine)
        if askDeclared { decode["preview_colour_space"] = .bool(true) }
        // Solved before on this file for this very request: the same value.
        let cache = matchCache, key = matchCacheKey(source, request: request, paths: engine.paths)
        matchRequest = id; matchingBrightness = true
        matchTask = Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: reference)
                if let self, self.matchRequest == id {
                    self.matchTask = nil; self.matchRequest = nil; self.matchingBrightness = false
                    self.reconcileBrightnessMatch()
                    if self.matchTask == nil { self.showHeldPreview(); self.settleQuickFrame(); self.renderAfterMatch() }
                }
            }
            @MainActor func stillWanted() throws {
                guard let self, !self.closing, self.sourceGeneration == generation, self.matchRequest == id else { throw CancellationError() }
            }
            if let key, let kept = cache.solved(key) {
                guard (try? stillWanted()) != nil, let self else { return }
                self.applyBrightnessMatch(kept.ev, limited: kept.limited, inputs: inputs)
                return
            }
            #if DEBUG
            self?.matchSolves += 1
            #endif
            do {
                // The whole photograph, as a render decodes it, with the
                // pipeline the solve and the render use.
                let decoded: ThumbnailReply
                do {
                    decoded = ThumbnailReply(try await engine.request(decode).1)
                } catch {
                    try stillWanted()
                    // The render reports why, as it would without the match.
                    self?.matchDecodeFailed = frame
                    return
                }
                try stillWanted()
                let raw = decoded.raw
                let size = decoded.sourceSize
                self?.decodedFor = (generation, size)
                if askDeclared, let self, self.matchReference?.generation == generation {
                    self.matchReference?.declared = decoded.previewColourSpace
                }
                let declared: JSONValue? = raw ? (self?.matchReference).flatMap { $0.generation == generation ? $0.declared : nil } : nil
                let solved = try await Self.solveBrightnessMatch(engine: engine, source: source, generation: generation, size: size, raw: raw,
                                                                 request: request, reference: reference, declared: declared,
                                                                 prepared: raw ? prepared : nil, stillWanted: stillWanted)
                guard let self, !self.closing, self.sourceGeneration == generation, self.matchRequest == id else { return }
                // Kept unless the file changed while it was solved.
                if let key, key == self.matchCacheKey(source, request: request, paths: engine.paths) {
                    cache.store(key, ev: solved.exposure, limited: solved.limited)
                }
                self.applyBrightnessMatch(solved.exposure, limited: solved.limited, inputs: inputs)
            } catch is CancellationError {
                // A different photograph or shutdown supersedes this request.
            } catch {
                guard let self, !self.closing, self.sourceGeneration == generation, self.matchRequest == id,
                      self.matchInputs(self.state) == inputs else { return }
                let failure = CameraBrightnessReference.failure(error)
                self.brightnessMatchFailure = (generation, failure.forPhoto ? nil : inputs, failure.message)
            }
        }
    }

    /// Has the helper decode `source` whole, as a render would, without
    /// developing it (and build the pipeline `state` renders with).
    func decodeOnlyCommand(source: URL, generation: Int, state: EditState, engine: EngineClient) -> [String: JSONValue] {
        [
            "command": EngineCommand.thumbnail.json, "input": .string(source.path), "source_generation": .number(Double(generation)),
            "film": .string(state.film), "paper": .string(state.paper), "params": state.params,
            // Qlick Lab: with screen-sized previews, no more than the photograph's proxy holds (2560 pixels): its
            // proxy if it has one, else a reduced read, never the whole RAW before the first frame.
            "long_side": .number(fastPreview ? 2560 : 16), "preview_path": .string(engine.directory.appendingPathComponent("decode-only.rgba").path),
            "reduced_decode": .bool(fastPreview), "decode_only": .bool(true)
        ]
    }

    /// The match cache's name for solving `request` on `file` in the helper at `paths`.
    func matchCacheKey(_ file: URL, request: EditState, paths: EnginePaths) -> String? {
        if matchEngine?.helper != paths.helper || matchEngine?.data != paths.data {
            matchEngine = (paths.helper, paths.data, BrightnessMatchCache.engineStamp(paths))
        }
        return matchEngine.flatMap { BrightnessMatchCache.key(file: file, request: request, engine: $0.stamp) }
    }

    /// What the match is solved with: `state` as rendered, without the
    /// brightness edits that are the user's own.
    func matchSolveState(_ state: EditState) -> EditState {
        var request = state
        request.params["prep"] = defaults["prep"]
        request.params["enlarger.print_exposure"] = defaults["enlarger.print_exposure"]
        return request
    }

    /// Solves Match camera brightness for `source`, which `engine` holds
    /// decoded as `generation` (`size` pixels): the exposure that develops it
    /// as bright as the camera's preview, and whether highlights limited it.
    /// `stillWanted` throws to stop before the helper is asked. `declared`:
    /// the helper's `preview_colour_space` answer, if it was read already.
    nonisolated static func solveBrightnessMatch(engine: EngineClient, source: URL, generation: Int, size: CGSize, raw: Bool, request: EditState,
                                                 reference: URL, declared given: JSONValue? = nil, prepared: Task<CameraBrightnessReference.Prepared, Never>? = nil,
                                                 stillWanted: @MainActor () throws -> Void = {}) async throws -> (exposure: Double, limited: Bool) {
        // What the RAW says its preview is in, read by the engine as on the
        // web and Windows.
        let declared: PreviewColourSpace?
        if !raw {
            declared = nil
        } else if let given {
            declared = PreviewColourSpace(rawValue: given.string)
        } else {
            declared = PreviewColourSpace(rawValue: try await engine.request([
                "command": EngineCommand.previewColourSpace.json, "input": .string(source.path)
            ]).1["colour_space"].string)
        }
        try Task.checkCancellation()
        let data = if raw, let prepared {
            try await prepared.value.png(expectedSize: size, declared: declared)
        } else {
            try await Task.detached(priority: .userInitiated) {
                raw ? try CameraBrightnessReference.png(from: source, expectedSize: size, declared: declared)
                    : try CameraBrightnessReference.filePNG(from: source, expectedSize: size)
            }.value
        }
        try Task.checkCancellation()
        try await stillWanted()
        try data.write(to: reference, options: .atomic)
        let (_, result) = try await engine.request([
            "command": EngineCommand.placeExposure.json, "input": .string(source.path),
            "source_generation": .number(Double(generation)), "film": .string(request.film),
            "paper": .string(request.paper), "params": request.params,
            "reference_path": .string(reference.path)
        ])
        try Task.checkCancellation()
        try await stillWanted()
        guard case .number(let exposure) = result["exposure_ev"], exposure.isFinite, (-3...3).contains(exposure) else {
            throw EngineError(message: "No reliable brightness match with these settings.")
        }
        return (exposure, result["highlight_limited"].bool)
    }

    /// The match is in, or failed, without changing the render: the held
    /// frame is the current one. A change re-renders and drops it.
    func showHeldPreview() {
        guard let held = heldPreview else { return }
        heldPreview = nil
        guard held.revision == revision, held.generation == sourceGeneration, !closing else { return }
        held.show()
        pumpPreviews()
        settleQuickFrame()
    }
    /// The shown frame is the settled render of its edit, not one rendered
    /// at canvas size (a slider's or a discrete edit's quick frame). It
    /// changes only with `image`, which the canvas observes.
    var showsSettledFrame: Bool { showingCachedPreview || (!showingInteractiveFrame && quickFrame == nil) }
    /// The solve is over and the edit it waited for is still unrendered:
    /// a match that moved the exposure rendered already (a new edit), so
    /// this is one it left as it was, or a failed one.
    func renderAfterMatch() {
        guard ready, source != nil, !closing, !previewCurrent, !renderFailed, !rendering, pendingRender == nil,
              !interacting, heldPreview == nil else { return }
        scheduleRender()
    }

    /// Moves the total with the match, keeping the user's exposure above it.
    /// A change under 0.05 EV keeps the values and only marks them current.
    func applyBrightnessMatch(_ ev: Double, limited: Bool, inputs: JSONValue) {
        guard matchInputs(state) == inputs, let next = Self.matching(state, ev: ev, limited: limited, inputs: inputs) else { return }
        replaceState(next)
    }

    /// `state` with its match solved as `ev`, for `inputs`.
    nonisolated static func matching(_ state: EditState, ev: Double, limited: Bool, inputs: JSONValue) -> EditState? {
        guard var match = state.brightnessMatch else { return nil }
        var next = state
        let offset = next.params["prep.exposure_ev"].double - (match.ev ?? 0)
        if match.ev.map({ abs(ev - $0) >= 0.05 }) ?? true {
            match.ev = ev
            next.params["prep.exposure_ev"] = .number(min(3, max(-3, abs(offset) < 1e-9 ? ev : ev + offset)))
        }
        match.inputs = inputs; match.highlightLimited = limited
        next.brightnessMatch = match
        return next
    }
}
