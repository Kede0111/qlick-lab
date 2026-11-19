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
    // MARK: Original

    /// Decodes the original ahead of a press, such as when the pointer
    /// reaches the button.
    func prepareOriginal() {
        dropStaleOriginal()
        if canShowOriginal, originalCache == nil { loadOriginal() }
    }

    static let lensCorrectionPath = "io.lens_correction.enabled"
    func dropStaleOriginal() {
        if originalLensCorrection != value(Self.lensCorrectionPath).bool { originalCache = nil; originalDetail = nil }
    }

    /// Shows the original in place of the developed photograph while held.
    /// The canvas keeps its crop, rotation, and border.
    func holdOriginal(_ held: Bool) {
        guard held, canShowOriginal else {
            holdingOriginal = false
            if let shown = original {
                original = nil
                // Core Animation may still be compositing it for a frame.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !self.holdingOriginal, self.originalCache === shown else { return }
                    shown.makeVolatile()
                }
            }
            return
        }
        guard !holdingOriginal else { return }
        holdingOriginal = true
        dropStaleOriginal()
        if let cached = originalCache {
            if cached.makeNonVolatile() { original = cached; loadOriginalDetail(); return }
            originalCache = nil
        }
        loadOriginal()
    }

    /// Qlick Lab: zoomed in past the original's own pixels, decodes the part on screen at the photograph's, once
    /// the zoom or the scroll has stopped, unless the part already decoded has it all.
    func loadOriginalDetail(after delay: Duration = .zero) {
        guard holdingOriginal, let original, let source, imageSize.width > 0,
              let visible = canvasScale.visiblePhotoRect, let wanted = canvasScale.screenPixelsPerPhotoPixel else { return }
        // The original's pixels for each of the photograph's.
        let has = CGFloat(max(original.width, original.height)) / max(imageSize.width, imageSize.height)
        guard wanted > has * 1.1 else { return }
        if let detail = originalDetail, detail.generation == sourceGeneration, Self.detailCovers(detail.rect, visible: visible, photo: imageSize) { return }
        let region = Self.detailRegion(visible: visible), raw = isRaw, generation = sourceGeneration
        let lensCorrection = value(Self.lensCorrectionPath).bool, size = imageSize
        originalDetailLoad?.cancel()
        originalDetailLoad = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let surface = await Task.detached(priority: .userInitiated) {
                OriginalImage.load(source, raw: raw, lensCorrection: lensCorrection, region: region)
            }.value
            guard let self, !Task.isCancelled, generation == self.sourceGeneration, let surface else { return }
            self.originalDetailLoad = nil
            let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height, width: region.width * size.width, height: region.height * size.height)
            self.originalDetail = OriginalDetail(image: surface, rect: rect, generation: generation)
        }
    }

    /// Decodes at the developed preview's resolution, so it is as sharp at
    /// actual size.
    func loadOriginal() {
        guard originalLoad == nil, let source, let image else { return }
        // Never above the source's own resolution: Image Size can enlarge the preview.
        let sourceLong = Int(max(sourceSize.width, sourceSize.height))
        let raw = isRaw, maxPixels = sourceLong > 0 ? min(max(image.width, image.height), sourceLong) : max(image.width, image.height), generation = sourceGeneration
        let lensCorrection = value(Self.lensCorrectionPath).bool
        originalLoad = Task { [weak self] in
            let surface = await Task.detached(priority: .userInitiated) {
                OriginalImage.load(source, raw: raw, lensCorrection: lensCorrection, maxPixels: maxPixels)
            }.value
            guard let self, generation == self.sourceGeneration, !Task.isCancelled else { return }
            self.originalLoad = nil
            self.originalLensCorrection = lensCorrection
            guard let surface else {
                if self.holdingOriginal {
                    self.holdingOriginal = false
                    self.status = "The original of \(source.lastPathComponent) couldn’t be shown"
                }
                return
            }
            self.originalCache = surface
            if self.holdingOriginal { self.original = surface; self.loadOriginalDetail() } else { surface.makeVolatile() }
        }
    }
}
