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
    // MARK: Rendering

    /// The edit as the helper renders it: in the preview space. Sessions
    /// keep the edit itself; the space is the app's.
    var renderState: EditState {
        var rendered = state
        rendered.params["io.output_color_space"] = .string(previewSpace)
        return rendered
    }
    /// Develops the preview in `name` from now on, and remembers it for the
    /// next save.
    func choosePreviewSpace(_ name: String) {
        guard name != previewSpace, let index = SaveSettings.colorSpaces.firstIndex(of: name) else { return }
        SaveSettings.chosenSpace = index
        previewSpace = name
        changed()
    }

    /// Try Again, after a develop failed: the same edit, developed again.
    func retryDevelop() {
        guard renderFailed else { return }
        changed(invalidateCache: false)
    }

    func changed(invalidateCache: Bool = true) {
        heldPreview = nil
        scheduleToneCurve()
        if invalidateCache { previewCache.invalidate(); showingCachedPreview = false }
        revision += 1; previewCurrent = false
        if developFailure != nil { developFailure = nil }
        // Dims the thumbnails now, or blanks them for a new photograph.
        pumpPreviews()
        guard ready, source != nil, !closing else { return }
        scheduleRender()
        scheduleActivity()
    }
    /// Renders run one at a time; edits made meanwhile coalesce into the next.
    func scheduleRender() {
        guard pendingRender == nil else { return }
        pendingRender = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.pendingRender = nil
            await self.render()
            // The main preview goes first; thumbnails follow once it's current.
            self.pumpPreviews()
            self.pumpThumbnails()
        }
    }
    /// What a render develops: the export-size frame, or as many pixels as
    /// the canvas shows, while a slider moves (`drag`) or ahead of the
    /// export-size frame of a discrete edit (`quick`).
    enum RenderStep: Equatable {
        case settled, drag(CGFloat), quick(CGFloat)
        /// Qlick Lab: a settled frame with as many pixels as the canvas shows (`fastPreview`).
        case screen(CGFloat)
        /// Qlick Lab: the part of the photograph on screen at its own pixels, zoomed in on a large one (`detail`).
        case detail
        var interactiveScale: CGFloat? {
            switch self { case .settled, .detail: nil; case .drag(let scale), .quick(let scale), .screen(let scale): scale }
        }
        var isScreen: Bool { if case .screen = self { true } else { false } }
        var isDrag: Bool { if case .drag = self { true } else { false } }
        var isQuick: Bool { if case .quick = self { true } else { false } }
    }
    /// A quick frame only pays when the export-size render takes a while
    /// (about 33 ms per megapixel on the GPU, so ~150 ms here) and the canvas
    /// shows at most half of its pixels.
    nonisolated static let quickFrameMinimumPixels = 4.5e6
    nonisolated static let quickFrameMaximumPixelFraction = 0.5

    /// `showsFinishedFrame`: the canvas shows this edit's developed frame
    /// already (a restored launch frame, or a photograph's kept last
    /// develop), which a quick frame would only blur. A new photograph's
    /// first frame is quick too (ticket 39).
    nonisolated static func renderStep(interacting: Bool, screenScale: CGFloat?, framePixels: Double,
                                       showsFinishedFrame: Bool, quickFrameDone: Bool, reusesHelperOutput: Bool,
                                       screenPreview: Bool = false, dragBudget: Double = dragPixelBudget) -> RenderStep {
        let scale = screenScale.flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
        // Qlick Lab: zoomed in, a slider's frames are a few megapixels all the same, shown enlarged until it's let go:
        // a whole photograph per frame never keeps up with the hand (nor its white balance).
        if interacting, screenPreview, framePixels > 0 {
            let budget = CGFloat((dragBudget / framePixels).squareRoot())
            if budget < 1, (screenScale ?? 1) > budget { return .drag(budget) }
        }
        if interacting { return scale.map(RenderStep.drag) ?? .settled }
        // Qlick Lab: fitted in the window, the settled frame is the screen's too; zoomed in, the photograph's.
        if screenPreview, let scale, scale <= screenPreviewMaximumScale { return .screen(scale) }
        guard let scale, !showsFinishedFrame, !quickFrameDone, !reusesHelperOutput,
              framePixels >= quickFrameMinimumPixels,
              Double(scale * scale) <= quickFrameMaximumPixelFraction else { return .settled }
        return .quick(scale)
    }
    /// Qlick Lab: the most pixels a slider's frame develops (zoomed in, or under a large canvas).
    nonisolated static let dragPixelBudget = 6_000_000.0
    /// The fewest, on the slowest Mac: about 1250 pixels wide.
    nonisolated static let dragPixelFloor = 1_000_000.0
    /// How long a slider's frame may take for the photograph to follow the hand.
    nonisolated static let dragFrameTarget = 0.1
    /// Qlick Lab: the budgets a slider's frame can have, each about 1.4 times fewer pixels than the one before. A
    /// fast Mac keeps the first; a slow one goes down them until a frame takes about `dragFrameTarget`, and shows
    /// it enlarged until the slider is let go, rather than the same frame three times a second. In steps, and kept
    /// (`dragLevel`) until the rate has clearly moved: every change of size resamples the photograph once.
    nonisolated static let dragBudgets: [Double] = [dragPixelBudget, 4_200_000, 3_000_000, 2_100_000, 1_500_000, dragPixelFloor]
    /// The level to drag at, from the one in use and what this Mac's last slider frames took (`secondsPerPixel`):
    /// down while a frame takes over 1.3 times the target, up once the level above would take under 0.8 of it.
    nonisolated static func dragLevel(_ level: Int, secondsPerPixel: Double?) -> Int {
        var level = min(max(level, 0), dragBudgets.count - 1)
        guard let rate = secondsPerPixel, rate > 0 else { return level }
        while level < dragBudgets.count - 1, dragBudgets[level] * rate > dragFrameTarget * 1.3 { level += 1 }
        while level > 0, dragBudgets[level - 1] * rate < dragFrameTarget * 0.8 { level -= 1 }
        return level
    }
    /// What a slider frame of `pixels` that took `seconds` makes of the rate: half the last, half this one. A frame
    /// far slower than the last ones (it read the photograph, or built a film) counts for three of them at most.
    nonisolated static func dragRate(_ rate: Double?, seconds: Double, pixels: Double) -> Double? {
        guard seconds > 0, pixels > 0 else { return rate }
        let sample = seconds / pixels
        guard let rate, rate > 0 else { return sample }
        return rate * 0.5 + min(sample, rate * 3) * 0.5
    }
    static let dragRateKey = "qlick.dragSecondsPerPixel"
    /// Past this many screen pixels to a photograph pixel, `fastPreview` develops the whole photograph.
    nonisolated static let screenPreviewMaximumScale: CGFloat = 0.7
    /// The scale that develops a photograph of `size` about as large as a screen shows it fitted.
    nonisolated static func screenWorth(_ size: CGSize) -> CGFloat? {
        let long = max(size.width, size.height)
        return long > 0 ? min(2400 / long, 1) : nil
    }
    nonisolated static let matchIgnoresWhiteBalance = NSClassFromString("XCTestCase") == nil
    nonisolated static let logsRenders = ProcessInfo.processInfo.environment["QLICK_RENDER_LOG"] == "1"
    /// The parts of a render request the helper's reuse depends on.
    nonisolated static func reuseKey(_ command: [String: JSONValue]) -> [String: JSONValue] {
        var key = command
        key["preview_path"] = nil
        key["params"]?["post"] = .null
        return key
    }

    func render() async {
        #if DEBUG
        willRender?()
        #endif
        guard !rendering, !closing, let source, let engine else { return }
        let currentRevision = revision, snapshot = renderState, generation = sourceGeneration
        let frame = FrameID(revision: currentRevision, generation: generation)
        // A quick frame's settled render waits for a solve that started after
        // it was scheduled (matching turned on while the quick frame shows,
        // which at exposure 0 is no new edit): the old exposure never renders
        // at export size. The solve's end settles it (`settleQuickFrame`).
        if quickStep == frame, !previewCurrent, !interacting, matchTask != nil || heldPreview != nil { return }
        // A pending brightness match is solved first, on a decode alone, so
        // the old exposure is never rendered (ticket 39). The solve's end
        // renders the matched edit (`renderAfterMatch`).
        if !interacting, !cropping, brightnessMatchPending, matchDecodeFailed != frame {
            reconcileBrightnessMatch()
            if matchTask != nil { return }
        }
        // A photograph's first frame: its decode first, so the quick frame
        // that follows knows the photograph's size and the canvas has laid
        // out its placeholder, whose scale it renders at (ticket 39). The
        // helper keeps the decode for the render. Not when its kept last
        // develop or its restored frame shows: those go straight to export size.
        let firstFrame = image == nil
        let showsFinishedFrame = showingCachedPreview || firstFrame && placeholderFor.map { $0.generation == generation && $0.kept } == true
        if firstFrame, !showsFinishedFrame, !interacting, decodedFor?.generation != generation {
            rendering = true
            let decoded = try? await engine.request(decodeOnlyCommand(source: source, generation: generation, state: snapshot, engine: engine)).1
            rendering = false
            // A failed decode leaves its error to the render.
            if generation == sourceGeneration { decodedFor = (generation, decoded.map { ThumbnailReply($0).sourceSize } ?? .zero) }
            guard !closing else { return }
            guard revision == currentRevision, generation == sourceGeneration else { return scheduleRender() }
        }
        let buffer = engine.directory.appendingPathComponent("preview.rgba")
        // Qlick Lab: Show mask goes to this render alone, never into the edits.
        let masked = showsHalationMask
        var params = snapshot.params
        if masked { params["film_render.halation.show_mask"] = .bool(true) }
        var command: [String: JSONValue] = [
            "command": EngineCommand.render.json, "input": .string(source.path),
            "source_generation": .number(Double(generation)),
            "film": .string(snapshot.film), "paper": .string(snapshot.paper), "params": params,
            "limit_preview": .bool(snapshot.limitPreview), "preview_path": .string(buffer.path)
        ]
        // The target describes the cropped photograph; the helper sizes the frame from the crop.
        if ImageSize.mode(of: snapshot.params) == .longestSide, let crop = Self.cropJSON(snapshot.crop) { command["crop"] = crop }
        let reuseKey = Self.reuseKey(command)
        // While a slider moves, render only as many pixels as the canvas
        // shows; the frame on release is the export-size one. A discrete
        // edit shows such a frame first, unless the helper can answer
        // quickly anyway: a small photograph, or post adjustments alone.
        // A first frame's canvas scale is the placeholder's, once it shows
        // this photograph at its size (a test's fixed scale stands in).
        let placeholderShown = placeholderFor.map { $0.generation == generation && !$0.kept } == true
        let screenScale = !firstFrame ? canvasScale.screenPixelsPerPhotoPixel
            : canvasScale.fixed ?? (placeholderShown ? canvasScale.screenPixelsPerPhotoPixel : nil)
                // Qlick Lab: no placeholder laid out yet: the scale the photograph will be fitted at.
                ?? (fastPreview && fitImage ? canvasScale.fitScale(for: decodedFor?.generation == generation && decodedFor?.size != .zero
                    ? decodedFor?.size ?? .zero : placeholderSize) : nil)
                // Nor laid out: a screen's worth, made sharper once the canvas says (`canvasScaleChanged`).
                ?? (fastPreview && fitImage ? Self.screenWorth(decodedFor?.generation == generation ? decodedFor?.size ?? placeholderSize : placeholderSize) : nil)
        let frameSize = !firstFrame ? imageSize : decodedFor?.generation == generation ? decodedFor?.size ?? .zero : .zero
        // Qlick Lab: a placeholder smaller than the photograph (the camera's preview) is laid out at its own size:
        // the canvas's scale is then per pixel of the placeholder, not of the photograph.
        let placeholderRatio = firstFrame && fastPreview && placeholderShown && frameSize.width > 0 && placeholderSize.width > 0
            ? min(max(placeholderSize.width, placeholderSize.height) / max(frameSize.width, frameSize.height), 1) : 1
        var step = Self.renderStep(
            interacting: interacting, screenScale: screenScale.map { $0 * placeholderRatio },
            framePixels: Double(frameSize.width * frameSize.height),
            showsFinishedFrame: showsFinishedFrame, quickFrameDone: quickStep == frame,
            reusesHelperOutput: helperOutput.map { $0.key == reuseKey && $0.launch == engine.runningLaunch } ?? false,
            screenPreview: fastPreview, dragBudget: Self.dragBudgets[dragLevel])
        // Qlick Lab: zoomed in on a large photograph: the part on screen at its own pixels first, then the
        // screen's frame under it (the histogram's, the grid's, and what shows around when the canvas moves).
        var region: CGRect?
        if step == .settled, fastPreview, !firstFrame, !cropping, original == nil, noDetailFor != frame,
           Double(frameSize.width * frameSize.height) >= Self.detailMinimumPixels, let visible = canvasScale.visiblePhotoRect {
            if detailCurrent, baseFor != frame {
                step = .screen(min(canvasScale.fitRatio ?? Self.screenWorth(frameSize) ?? 0.25, Self.screenPreviewMaximumScale))
            } else {
                step = .detail
                region = Self.detailRegion(visible: visible)
            }
        }
        if let region {
            command["region"] = .array([region.minX, region.minY, region.width, region.height].map { .number(Double($0)) })
        }
        let interactiveScale = step.interactiveScale
        if Self.logsRenders, firstFrame {
            FileHandle.standardError.write(Data("first frame: scale=\(String(describing: screenScale)) placeholder=\(placeholderSize) decoded=\(String(describing: decodedFor)) gen=\(generation) fit=\(fitImage) shown=\(placeholderShown) finished=\(showsFinishedFrame)\n".utf8))
        }
        if let interactiveScale {
            command["interactive_scale"] = .number(Double(interactiveScale))
            // Qlick Lab: the photograph's size is known (its kept develop, or its decode): a RAW read for the
            // first time is read only as large as this frame.
            let known = frameSize != .zero ? frameSize : placeholderFor?.generation == generation && placeholderFor?.kept == true ? placeholderSize : .zero
            if known != .zero { command["read_long_side"] = .number((max(known.width, known.height) * interactiveScale).rounded(.up)) }
        }
        rendering = true
        defer {
            rendering = false
            // The quick frame is done: the next render settles. Once that
            // ran, failed or not, nothing waits to settle (no retries).
            if revision == currentRevision, generation == sourceGeneration {
                if step.isQuick { quickStep = frame } else if step == .settled || step == .detail || step.isScreen { quickStep = nil }
            }
            if step.isDrag, !interacting, !closing { scheduleRender() }
            if revision != currentRevision, !closing { scheduleRender() }
            // A match that went stale while this rendered (a drag's release,
            // matching turned on) is solved now, before the next render.
            reconcileBrightnessMatch()
            settleQuickFrame()
        }
        do {
            // The cache's name stats the helper's data (~18 ms): worked out
            // while the helper renders, not before (ticket 39).
            let cacheKeyTask = interactiveScale == nil && step != .detail && !masked ? Task.detached(priority: .utility) {
                RenderedPreviewCache.key(source: source, state: snapshot, paths: engine.paths)
            } : nil
            guard shouldShow(currentRevision, generation) else { cacheKeyTask?.cancel(); return }
            // The helper replaces its kept output with each render, and keeps
            // none if this one fails.
            helperOutput = nil
            #if DEBUG
            renderLog.append(step)
            #endif
            let sent = Date()
            let (id, result, launch) = try await engine.requestOnLaunch(command)
            let reply = RenderReply(result)
            if Self.logsRenders {
                EngineTrace.log("render \(step) first=\(firstFrame) wall=\(Int(Date().timeIntervalSince(sent) * 1000))ms engine=\(Int(reply.elapsedMs))ms \(Int(reply.width))x\(Int(reply.height))")
            }
            if step.isDrag, fastPreview {
                dragSecondsPerPixel = Self.dragRate(dragSecondsPerPixel, seconds: Date().timeIntervalSince(sent),
                                                    pixels: reply.outputWidth * reply.outputHeight)
                if let dragSecondsPerPixel { UserDefaults.standard.set(dragSecondsPerPixel, forKey: Self.dragRateKey) }
                dragLevel = Self.dragLevel(dragLevel, secondsPerPixel: dragSecondsPerPixel)
            }
            // A detail that came as the whole photograph: its params read the whole frame.
            let part: [Double] = reply.region
            let whole = step == .settled || step == .detail && part.count != 4
            if step == .detail, part.count != 4 { noDetailFor = frame }
            if whole { helperOutput = (reuseKey, launch) }
            // A quick frame of an earlier edit still shows while edits keep
            // coming (Undo held down); the current one renders next.
            let quick = step.isQuick
            func showable() -> Bool { quick ? !closing && generation == sourceGeneration : shouldShow(currentRevision, generation) }
            guard showable() else { return }
            let width = Int(reply.width), height = Int(reply.height)
            let display = reply.displayColorSpace
            let developed = try await Task.detached(priority: .userInitiated) {
                try Self.readPreview(buffer, width: width, height: height, displaySpace: display)
            }.value
            let cacheKey = await cacheKeyTask?.value ?? nil
            guard showable() else { return }
            // The brightness match reads these; the rest waits for the frame.
            sourceSize = CGSize(width: reply.sourceWidth, height: reply.sourceHeight)
            isRaw = reply.raw
            let show = { [weak self] in
                guard let self else { return }
                if part.count == 4 {
                    // The part on screen: over the image, which stays.
                    guard revision == currentRevision, !interacting else { return }
                    detail = DetailFrame(image: developed, rect: CGRect(x: part[0], y: part[1], width: part[2], height: part[3]), frame: frame)
                    renderAtExportSize = false
                    if baseFor == frame {
                        renderID = id; previewCurrent = true; hideActivity()
                    } else {
                        scheduleRender()
                    }
                    return
                }
                if detail?.frame != frame { detail = nil }
                imageSize = CGSize(width: reply.photoWidth, height: reply.photoHeight)
                workingSize = CGSize(width: reply.workingWidth, height: reply.workingHeight)
                let settledFrame = interactiveScale == nil || step.isScreen
                if settledFrame {
                    previewScale = workingSize.width > 0 ? min(Double(width) / workingSize.width, 1) : 1
                }
                showingInteractiveFrame = !settledFrame
                quickFrame = quick ? frame : nil
                image = developed; placeholder = nil; standIn = nil
                imageIsMask = masked
                if revision == currentRevision { trialImage = nil }
                updateHistogram()
                let film = FilmHistogram(reply.filmHistogram)
                if film != filmHistogram { filmHistogram = film }
                cropSession?.update(photo: shownImageSize, rotation: imageRotation)
                updateFilmStrip()
                if inputColour != reply.inputColour { inputColour = reply.inputColour }
                lensCorrectionSupported = reply.lensCorrectionSupported
                if revision == currentRevision, settledFrame {
                    baseFor = frame
                    screenFrameScale = step.isScreen ? interactiveScale : nil
                    // Developed before the canvas knew its scale: sharper now if it wants more.
                    if step.isScreen { Task { @MainActor [weak self] in self?.canvasScaleChanged() } }
                    // Shown from a smaller source than the canvas wants, while a larger one is read.
                    if reply.refining { refineSoon() } else { refineRender?.cancel() }
                    renderID = id; previewCurrent = true; hideActivity()
                    showingCachedPreview = false
                    prepareBalanceSoon()
                    renderAtExportSize = reply.exportResolution && !masked
                    renderOnGPU = ExportEngine.ranOnGPU(backend: reply.backend)
                    if let cacheKey { previewCache.save(developed, photoSize: imageSize, sourceSize: sourceSize, workingSize: workingSize, raw: isRaw, key: cacheKey) }
                }
                // The photograph as exported, and whether the shown texture has fewer
                // pixels: inspect grain in an export when it does. Qlick Lab: no develop time.
                let photograph = crop.size(of: workingSize)
                status = !settledFrame
                    ? "Preview · \(Int(reply.outputWidth)) × \(Int(reply.outputHeight))"
                    : "\(Int(photograph.width)) × \(Int(photograph.height))\(previewScale < 1 ? " · shown at \(Self.percent(previewScale))" : "")"
            }
            // A settled or quick frame with a stale match would show the old
            // exposure for as long as the solve and the next render take: keep
            // the previous frame and the activity badge up until the match is
            // in. A stale match is solved before rendering, so this is only a
            // match that went stale while the frame rendered (turned on at
            // exposure 0, which is no new edit).
            if !step.isDrag, revision == currentRevision, !interacting, !cropping, brightnessMatchPending {
                heldPreview = (currentRevision, generation, show)
            } else {
                show()
            }
        } catch {
            // A failed quick frame leaves the error to the export-size render that follows.
            if step.isQuick { return }
            if currentRevision == revision, generation == sourceGeneration, !closing {
                // Said on the canvas and in the status line, not in an alert (§6.10).
                developFailure = error.localizedDescription; hideActivity()
            }
        }
    }

    /// Qlick Lab: the eyedropper's click: the helper finds the temperature and tint that make the photograph
    /// neutral there, and the balance becomes Custom at them, as one undoable step.
    func pickWhiteBalance(at point: CGPoint) {
        guard isRaw, let source, let engine, canChangeEdits else { NSSound.beep(); return }
        let generation = sourceGeneration
        let command: [String: JSONValue] = [
            "command": EngineCommand.pickBalance.json, "input": .string(source.path), "source_generation": .number(Double(generation)),
            "params": renderState.params, "x": .number(Double(point.x)), "y": .number(Double(point.y)),
        ]
        Task {
            do {
                let (_, result) = try await engine.request(command)
                guard self.sourceGeneration == generation else { return }
                let temperature = (result["temperature"].double / 10).rounded() * 10, tint = result["tint"].double
                self.setParams([("io.raw_white_balance.mode", .string("custom")), ("io.raw_white_balance.temperature", .number(temperature)),
                                ("io.raw_white_balance.tint", .number(min(max(tint, 0.05), 4)))])
                self.lab.pickingWhite = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }


    /// Qlick Lab: once a RAW's first frame is in, the helper reads it again in Daylight, reduced, and fits As Shot
    /// as a matrix (`prepare_balance`): from then on every canvas-size frame takes its white balance from a matrix,
    /// so no slider waits for the RAW. Its answer is As Shot's and Auto's temperature and tint in the engine's own
    /// terms, so the sliders start where the photograph is and Auto lands where it says.
    func prepareBalanceSoon() {
        guard fastPreview, isRaw, let source, engine != nil, balancePrepared != sourceGeneration, !closing else { return }
        let generation = sourceGeneration
        balancePrepared = generation
        balanceTask?.cancel()
        balanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            // The editor's own work first.
            while let self, !Task.isCancelled, self.sourceGeneration == generation, self.interacting || self.rendering || self.pendingRender != nil {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, !Task.isCancelled, self.sourceGeneration == generation, !self.closing, let engine = self.engine else { return }
            let size = self.sourceSize != .zero ? self.sourceSize : self.decodedFor?.size ?? .zero
            let scale = self.screenFrameScale ?? Self.screenWorth(size) ?? 0.25
            let command: [String: JSONValue] = [
                "command": EngineCommand.prepareBalance.json, "input": .string(source.path), "source_generation": .number(Double(generation)),
                "params": self.renderState.params, "read_long_side": .number((max(size.width, size.height) * scale).rounded(.up)),
            ]
            do {
                // The helper reads in the background and answers at once; asked again, it says once it's done.
                for _ in 0..<20 {
                    let (_, result) = try await engine.request(command)
                    guard self.sourceGeneration == generation, !Task.isCancelled else { return }
                    if result["ready"].bool {
                        let asShot = result["as_shot"].array.map(\.double), auto = result["auto"].array.map(\.double)
                        if asShot.count == 2 { self.lab.asShot.set(source, (asShot[0], asShot[1]), auto: auto.count == 2 ? (auto[0], auto[1]) : nil) }
                        if Self.logsRenders { FileHandle.standardError.write(Data("prepare balance: \(result)\n".utf8)) }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            } catch {
                if Self.logsRenders { FileHandle.standardError.write(Data("prepare balance failed: \(error.localizedDescription)\n".utf8)) }
            }
        }
    }

    /// Qlick Lab: the canvas shows more pixels than the settled frame has (zoomed in, or a larger window):
    /// develops it again at that size, or whole past `screenPreviewMaximumScale`.
    func canvasScaleChanged() {
        if holdingOriginal { loadOriginalDetail(after: .milliseconds(160)) }
        guard fastPreview, ready, source != nil, !closing, !interacting, previewCurrent, let shown = screenFrameScale,
              let wanted = canvasScale.screenPixelsPerPhotoPixel, wanted > shown * 1.1 else { return }
        // Zoomed in with the part on screen at its own pixels already: nothing sharper to develop.
        if wanted > Self.screenPreviewMaximumScale, detailCurrent { return }
        zoomRender?.cancel()
        zoomRender = Task { [weak self] in
            // Once the pinch or the resize has stopped.
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, self.previewCurrent, !self.interacting, !self.closing, let shown = self.screenFrameScale,
                  let wanted = self.canvasScale.screenPixelsPerPhotoPixel, wanted > shown * 1.1 else { return }
            if wanted > Self.screenPreviewMaximumScale, self.detailCurrent { return }
            self.previewCurrent = false
            self.scheduleRender()
            self.scheduleActivity()
        }
    }

    /// Qlick Lab: the canvas scrolled while a detail shows: once it has stopped, the part now on screen is
    /// developed if the detail hasn't all of it. Until then the image shows there, with fewer pixels.
    func canvasMoved() {
        if holdingOriginal { loadOriginalDetail(after: .milliseconds(120)) }
        guard fastPreview, detail != nil, ready, source != nil, !closing, !interacting, previewCurrent, !cropping,
              (canvasScale.screenPixelsPerPhotoPixel ?? 0) > Self.screenPreviewMaximumScale, !detailCurrent else { return }
        panRender?.cancel()
        panRender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, self.previewCurrent, !self.interacting, !self.closing, !self.rendering,
                  self.pendingRender == nil, self.detail != nil, !self.detailCurrent,
                  (self.canvasScale.screenPixelsPerPhotoPixel ?? 0) > Self.screenPreviewMaximumScale else { return }
            self.previewCurrent = false
            self.scheduleRender()
        }
    }


    /// Qlick Lab: the frame came at once from a smaller source than the canvas shows (a photograph's proxy under a
    /// large canvas, or zoomed in) while the helper reads a larger one on a thread of its own (`refining`). Asks
    /// for the frame again in a moment: the same one for almost nothing while the read goes on, the sharper one
    /// once it's in. An edit or a drag meanwhile develops by itself, and its frame says whether to ask again.
    func refineSoon() {
        refineRender?.cancel()
        refineRender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.previewCurrent, !self.interacting, !self.closing, !self.rendering,
                  self.pendingRender == nil else { return }
            self.previewCurrent = false
            self.scheduleRender()
        }
    }

    /// After a quick frame of the current edit, renders it at export size
    /// once no brightness match is pending or running: a match that changes
    /// the exposure is a new edit, with its own quick frame. Called wherever
    /// one of these conditions can clear; does nothing until all hold. A
    /// slider's release renders by itself.
    func settleQuickFrame() {
        let frame = FrameID(revision: revision, generation: sourceGeneration)
        guard quickStep == frame, !previewCurrent, !renderFailed, !interacting, !rendering, pendingRender == nil,
              matchTask == nil, heldPreview == nil, ready, source != nil, !closing else { return }
        scheduleRender()
    }

    /// While a slider moves, show each finished frame. Otherwise only the
    /// latest edit, so a discrete change never flashes an older state.
    func shouldShow(_ renderedRevision: Int, _ generation: Int) -> Bool {
        !closing && generation == sourceGeneration && (revision == renderedRevision || interacting)
    }

    /// Counts the preview's tones off the main thread. A newer preview or
    /// crop supersedes a count still running.
    func updateHistogram() {
        histogramRequest += 1
        guard let image else { histogram = nil; waveform = nil; return }
        let request = histogramRequest, crop = crop, rotation = imageRotation
        Task.detached(priority: .userInitiated) { [weak self] in
            let counted = ImageScopes.of(image, crop: crop, rotation: rotation)
            await self?.showHistogram(counted, request: request)
        }
    }
    func showHistogram(_ counted: ImageScopes, request: Int) {
        guard request == histogramRequest else { return }
        histogram = counted.histogram
        waveform = counted.waveform
    }
}
