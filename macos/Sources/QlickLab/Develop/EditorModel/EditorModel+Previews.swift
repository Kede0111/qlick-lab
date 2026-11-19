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
    // MARK: Film, paper and preset previews

    /// Settings › Film, paper and preset previews. Off shows the menus and
    /// the plain preset list, and frees the thumbnails here and in the helper.
    func setPreviews(_ enabled: Bool) {
        guard enabled != previews.enabled else { return }
        if !enabled { endTray(keep: true) }
        previews.enabled = enabled
        if enabled { pumpPreviews(); return }
        if previews.clear(), let engine {
            Task.detached(priority: .utility) { _ = try? await engine.request(["command": EngineCommand.releaseThumbnails.json]) }
        }
    }

    /// Settings › Keep paper when changing film. The film tiles show what a
    /// click would develop, so they go stale (their key holds the paper).
    func setKeepPaper(_ keep: Bool) {
        guard keep != previews.keepPaper else { return }
        previews.keepPaper = keep
        pumpPreviews()
    }

    /// Marks out-of-date thumbnails (dimmed, or blank for another photograph)
    /// and requests the next one of an open grid or the Presets list: one
    /// helper request at a time, and only while the main preview is current
    /// and nothing is dragged.
    func pumpPreviews() {
        guard previews.enabled, !closing, let source else { return }
        let scanning = state.params["io.scan_film"].bool
        let rendered = renderState, generation = sourceGeneration
        // Each wanted tile: its look's key, the request, and a name for logs.
        var wanted: [(tile: PreviewTile, key: PreviewTile.Key, command: [String: JSONValue], name: String)] = []
        var entries: [StockEntry] = []
        if previews.filmOpen, previews.filmShown {
            let listed = Set(listedFilms.map(\.id))
            entries += previews.filmsFavoritesFirst.filter { listed.contains($0.stock.id) }
        }
        if previews.paperOpen, previews.paperShown, !scanning { entries += previews.papersFavoritesFirst }
        for entry in entries {
            let command = PreviewRules.request(for: entry.stock, keepPaper: previews.keepPaper, state: rendered, stocks: stocks,
                                               source: source, generation: generation)
            wanted.append((entry.tile, PreviewTile.Key(generation: generation, request: command), command, entry.stock.id))
        }
        if previews.presetsShown, checkingPresets == 0 {
            let kept = catalog["preset_kept"].array.map(\.string)
            let ordered = PreviewRules.renderOrder(presets, raw: isRaw, whiteBalance: { self.presetWhiteBalances[$0] },
                                                        photo: rendered.params["io.raw_white_balance"])
            for preset in ordered {
                guard case .valid = presetStatus[preset], let text = presetTexts[preset], let tile = previews.tile(preset: preset.url) else { continue }
                let command = PreviewRules.presetCommand(text: text, state: rendered, source: source, generation: generation)
                wanted.append((tile, PreviewRules.presetKey(command, kept: kept.isEmpty ? nil : kept, generation: generation), command, preset.name))
            }
        }
        guard !wanted.isEmpty else { return }
        var next: (tile: PreviewTile, key: PreviewTile.Key, command: [String: JSONValue], name: String)?
        for item in wanted {
            if item.tile.mark(wanted: item.key), next == nil { next = item }
        }
        guard !previews.busy, ready, previewCurrent, !rendering, pendingRender == nil, !interacting, let engine else { return }
        guard let (tile, key, request, name) = next else { return }
        previews.busy = true
        let buffer = engine.directory.appendingPathComponent("thumbnail-\(UUID().uuidString).rgba")
        var command = request
        command["preview_path"] = .string(buffer.path)
        Task { [weak self] in
            let image: CGImage?
            do {
                let (_, result) = try await engine.request(command)
                let (width, height) = (Int(result["width"].double), Int(result["height"].double))
                let display = result["display_color_space"].string
                image = await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: buffer) }
                    return try? Self.thumbnailImage(Data(contentsOf: buffer), width: width, height: height, displaySpace: display)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: buffer)
                FileHandle.standardError.write(Data("thumbnail \(name): \(error.localizedDescription)\n".utf8))
                image = nil
            }
            guard let self else { return }
            self.previews.busy = false
            guard !self.closing, self.previews.enabled else { return }
            // The photograph changed meanwhile: drop it, the next pump retries.
            // A failure stays blank until the next edit, so nothing spins.
            if key.generation == self.sourceGeneration { tile.show(image, for: key) }
            self.pumpPreviews()
        }
    }

    /// The helper's RGBA thumbnail as an image tagged like the main preview
    /// (`display_color_space`), so it shows the same colours.
    nonisolated static func thumbnailImage(_ data: Data, width: Int, height: Int, displaySpace: String) throws -> CGImage {
        guard width > 0, height > 0, width <= 4096, height <= 4096, data.count == width * height * 4,
              let space = displayColorSpace(displaySpace), let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw EngineError(message: "The image engine returned an invalid thumbnail.") }
        return image
    }

    /// Reads the engine's RGBA buffer into an IOSurface tagged with its
    /// colour space (`display_color_space`). Core Animation composites it
    /// directly, converting for the display, with nothing on the main thread.
    nonisolated static func readPreview(_ url: URL, width: Int, height: Int, displaySpace: String = "sRGB") throws -> IOSurface {
        try previewSurface(Data(contentsOf: url), width: width, height: height, displaySpace: displaySpace)
    }

    /// The helper's proxy spaces: sRGB for an sRGB preview, otherwise
    /// Rec. 2020 primaries with the sRGB curve, which holds the wide spaces.
    nonisolated static func displayColorSpace(_ name: String) -> CGColorSpace? {
        CGColorSpace(name: name == "Rec. 2020 (sRGB transfer)" ? CGColorSpace.itur_2020_sRGBGamma : CGColorSpace.sRGB)
    }

    /// The proxy space a surface from `previewSurface` is tagged with.
    nonisolated static func displaySpace(of surface: IOSurface) -> String {
        let tag = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace).flatMap { CGColorSpace(propertyListPlist: $0 as CFPropertyList) }
        return tag?.name == CGColorSpace.itur_2020_sRGBGamma ? "Rec. 2020 (sRGB transfer)" : "sRGB"
    }

    nonisolated static func previewSurface(_ data: Data, width: Int, height: Int, bgra: Bool = false, displaySpace: String = "sRGB") throws -> IOSurface {
        let invalid = EngineError(message: "The image engine returned an invalid preview buffer.")
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw EngineError(message: "Invalid preview dimensions") }
        guard data.count == width * height * 4,
              let surface = IOSurface(properties: [
                  .width: width, .height: height, .bytesPerElement: 4,
                  .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
                  .pixelFormat: kCVPixelFormatType_32BGRA
              ]),
              let colorSpace = displayColorSpace(displaySpace)?.copyPropertyList()
        else { throw invalid }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let permuted = data.withUnsafeBytes { raw -> vImage_Error in
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var destination = vImage_Buffer(data: surface.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: surface.bytesPerRow)
            // RGBA → BGRA, and opaque regardless of the engine's alpha byte.
            let error = vImagePermuteChannels_ARGB8888(&source, &destination, bgra ? [0, 1, 2, 3] : [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
            return error == kvImageNoError ? vImageOverwriteChannelsWithScalar_ARGB8888(255, &destination, &destination, 0x1, vImage_Flags(kvImageNoFlags)) : error
        }
        guard permuted == kvImageNoError else { throw invalid }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpace)
        return surface
    }
}
