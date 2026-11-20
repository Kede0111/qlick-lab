// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreImage
import ImageIO

/// Develops photographs for the loupe and for Comparaison, at the size they're looked at.
///
/// A helper of its own (a second `spektrafilm-native`), so the editor's is never held up and a comparison of four
/// films is four real developments, not four filters. It runs one request at a time, at the engine's reduced read,
/// and quits after a while without work to give its memory back.
@MainActor final class LabDeveloper {
    struct Request: Hashable {
        var item: URL
        var film: String?
        var paper: String?
        var recipe: URL?
        /// The undeveloped photograph: the file as macOS reads it.
        var original = false
        var longSide: Int
        /// Qlick Lab: another output colour space than the preview's (Print's gamut check).
        var space: String? = nil
    }

    private let model: EditorModel
    private var engine: EngineClient?
    private var idle: Task<Void, Never>?
    private var held: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var running: [Key: Task<CGImage?, Never>] = [:]
    /// Images kept, most recent last: about 20 MB each at 2400 pixels.
    static let most = 12

    private struct Key: Hashable {
        var request: Request
        /// The photograph's look when it was developed, so an edit makes a new image.
        var look: String?
    }

    init(model: EditorModel) { self.model = model }

    /// The open photograph's edits as last developed here, and a count of how often they changed.
    private var openState: EditState?
    private var openSerial = 0

    private func key(_ request: Request) -> Key {
        if request.original { return Key(request: request, look: nil) }
        guard request.item == model.sourceItem else { return Key(request: request, look: model.thumbnailLook(for: request.item)) }
        let state = model.renderState
        if state != openState { openState = state; openSerial += 1 }
        return Key(request: request, look: "open|\(openSerial)")
    }

    /// An image already made for `request`, if any.
    func cached(_ request: Request) -> CGImage? { held[key(request)] }

    func image(_ request: Request) async -> CGImage? {
        let key = key(request)
        if let image = held[key] { touch(key); return image }
        if let running = running[key] { return await running.value }
        let task = Task { [weak self] () -> CGImage? in
            guard let self else { return nil }
            let image = await self.develop(request)
            self.running[key] = nil
            if let image { self.keep(image, as: key) }
            return image
        }
        running[key] = task
        return await task.value
    }

    private func develop(_ request: Request) async -> CGImage? {
        if request.original { return await original(request) }
        guard let paths = model.labEnginePaths else { return nil }
        idle?.cancel(); idle = nil
        if engine == nil { engine = try? EngineClient(paths: paths, quality: .userInitiated); engine?.label = "lab" }
        guard let engine else { return nil }
        var preset: String?
        if let recipe = request.recipe {
            guard let file = model.presets.first(where: { $0.url == recipe }), let text = model.labPresetText(file) else { return nil }
            preset = text
        }
        let image = await model.labDevelop(request.item, film: request.film, paper: request.paper, preset: preset, longSide: request.longSide, engine: engine,
                                           space: request.space)
        stopSoon()
        return image
    }

    /// The file as macOS shows it, cropped and turned as its development is, so the two lie over one another.
    private func original(_ request: Request) async -> CGImage? {
        let state = model.labEdits(for: request.item).state
        let photo = request.item.photoFile, longSide = request.longSide
        let raw = EditorModel.rawExtensions.contains(photo.pathExtension.lowercased())
        let lens = state.params[EditorModel.lensCorrectionPath].bool
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(photo, raw: raw, lensCorrection: lens, maxPixels: longSide) }.value
        guard let decoded else { return nil }
        let size = CGSize(width: decoded.width, height: decoded.height)
        return ThumbnailComposer.compose(decoded, size: size, crop: state.crop, cut: false, rotation: Int(state.params["io.rotate_cw"].double),
                                         border: nil, texture: nil, strip: nil, longSide: CGFloat(longSide),
                                         space: decoded.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? decoded
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func decode(_ url: URL, raw: Bool, lensCorrection: Bool, maxPixels: Int) -> CGImage? {
        autoreleasepool {
            if raw, let filter = CIRAWFilter(imageURL: url) {
                if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = lensCorrection }
                if let full = filter.outputImage, !full.extent.isEmpty {
                    let scale = min(1, CGFloat(maxPixels) / max(full.extent.width, full.extent.height))
                    if scale < 1 { filter.scaleFactor = Float(scale) }
                    if let output = filter.outputImage,
                       let image = context.createCGImage(output, from: output.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) {
                        context.clearCaches()
                        return image
                    }
                }
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }
    }

    private func keep(_ image: CGImage, as key: Key) {
        held[key] = image
        touch(key)
        while order.count > Self.most { held[order.removeFirst()] = nil }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Quits the helper after a while without work.
    private func stopSoon() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, self.running.isEmpty, let engine = self.engine else { return }
            self.engine = nil
            await Task.detached(priority: .utility) { engine.stop() }.value
        }
    }

    func shutdown() {
        idle?.cancel()
        running.values.forEach { $0.cancel() }
        if let engine { self.engine = nil; Task.detached(priority: .utility) { engine.stop() } }
        held = [:]; order = []
    }
}
