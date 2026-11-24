// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Sharpening for where the photograph is shown, after it's sized: a screen wants a fine, light touch; paper a wider
/// one, matte more than glossy (its ink spreads).
enum OutputSharpening: String, CaseIterable, Codable, Sendable {
    case none, screen, matte, glossy
    var title: String {
        switch self { case .none: "None"; case .screen: "Screen"; case .matte: "Matte Paper"; case .glossy: "Glossy Paper" }
    }
    /// The unsharp mask's radius, in pixels of the finished file, at its long side of 3000 (scaled with it).
    var radius: Double { switch self { case .none: 0; case .screen: 0.6; case .matte: 1.6; case .glossy: 1.1 } }
    /// The choice last made, in Print or the save panel.
    static var remembered: OutputSharpening {
        get { UserDefaults.standard.string(forKey: "qlick.exportSharpen").flatMap(Self.init) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "qlick.exportSharpen") }
    }
}

enum SharpeningAmount: String, CaseIterable, Codable, Sendable {
    case low, standard, high
    var title: String { rawValue.capitalized }
    var intensity: Double { switch self { case .low: 0.25; case .standard: 0.5; case .high: 0.85 } }
    static var remembered: SharpeningAmount {
        get { UserDefaults.standard.string(forKey: "qlick.exportSharpenAmount").flatMap(Self.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "qlick.exportSharpenAmount") }
    }
}

/// What the file says of where and how it was taken.
enum ExportMetadata: String, CaseIterable, Codable, Sendable {
    case all, noLocation, none
    var title: String { switch self { case .all: "All"; case .noLocation: "All but Location"; case .none: "None" } }
    static var remembered: ExportMetadata {
        get { UserDefaults.standard.string(forKey: "qlick.exportMetadata").flatMap(Self.init) ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "qlick.exportMetadata") }
    }
}

/// The last steps of a save or an export, after the engine has written its file in the lab's scratch folder, on the
/// Mac's own disk: 10-bit HEIF (the engine writes a 16-bit TIFF, which macOS encodes), output sharpening and the
/// metadata kept (`finish`), then the lab's XMP (`LabXMP`), written once beside the destination and renamed onto it.
/// Nothing large is ever written twice on the destination's disk, which may be a slow share.
enum ExportFinisher {
    static func isHEIF(_ url: URL) -> Bool { ["heic", "heif"].contains(url.pathExtension.lowercased()) }

    static func needed(_ save: SaveSettings, destination: URL) -> Bool {
        isHEIF(destination) || save.sharpening != .none || save.metadata != .all
    }

    /// Where the engine writes for `destination`, in `folder` (the lab's scratch space): a TIFF for a HEIF.
    static func engineFile(for destination: URL, in folder: URL) -> URL {
        folder.appendingPathComponent("engine-\(UUID().uuidString).\(isHEIF(destination) ? "tif" : destination.pathExtension)")
    }

    /// The hidden file beside `destination` that the finished export is written to, then renamed onto it.
    static func staging(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".qlick-\(UUID().uuidString).\(destination.pathExtension)")
    }

    private static let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])

    /// Takes the engine's file `written` to `destination`: finished when `needed`, with `xmp` embedded, through a
    /// hidden file beside it that is renamed onto it, so a failure leaves an existing file as it was. Off the main
    /// thread.
    nonisolated static func deliver(_ written: URL, to destination: URL, save: SaveSettings, xmp: LabXMP?) throws {
        guard needed(save, destination: destination) else { return try place(written, at: destination, xmp: xmp) }
        let finished = written.deletingLastPathComponent().appendingPathComponent("finished-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: finished) }
        try finish(written, as: destination, into: finished, save: save)
        try place(finished, at: destination, xmp: xmp)
    }

    private static func place(_ source: URL, at destination: URL, xmp: LabXMP?) throws {
        let staging = staging(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        try LabXMP.write(source, to: staging, xmp: xmp)
        guard rename(staging.path, destination.path) == 0 else {
            throw EngineError(message: "Could not move the completed export to \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Encodes `written` (the engine's file) as `destination`'s format, sharpened and with its metadata as asked,
    /// into `output`.
    nonisolated static func finish(_ written: URL, as destination: URL, into output: URL, save: SaveSettings) throws {
        guard var image = CIImage(contentsOf: written, options: [.applyOrientationProperty: true]) else {
            throw EngineError(message: "The export couldn’t be read back to finish it.")
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if save.sharpening != .none {
            let long = Double(max(image.extent.width, image.extent.height))
            let radius = save.sharpening.radius * max(long / 3000, 0.5)
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: radius, kCIInputIntensityKey: save.sharpeningAmount.intensity,
            ]).cropped(to: image.extent)
        }
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = nil
        switch save.metadata {
        case .all: break
        case .noLocation: properties[kCGImagePropertyGPSDictionary as String] = nil
        case .none:
            // The resolution stays: it says how large to print, nothing of the photographer.
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] { properties[key as String] = nil }
            var kept: [String: Any] = [:]
            for key in [kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFSoftware] {
                if let value = tiff?[key as String] { kept[key as String] = value }
            }
            if !kept.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = kept }
        }
        // The print resolution, as the engine wrote it, in whichever place each format keeps it.
        properties[kCGImagePropertyDPIWidth as String] = save.ppi
        properties[kCGImagePropertyDPIHeight as String] = save.ppi
        var tiffFields = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiffFields[kCGImagePropertyTIFFXResolution as String] = save.ppi
        tiffFields[kCGImagePropertyTIFFYResolution as String] = save.ppi
        tiffFields[kCGImagePropertyTIFFResolutionUnit as String] = 2
        properties[kCGImagePropertyTIFFDictionary as String] = tiffFields
        image = image.settingProperties(properties)
        let heif = isHEIF(destination)
        let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                        Double(heif ? save.heifQuality : save.jpegQuality) / 100]
        let sixteen = (save.bitDepth ?? 8) >= 16
        switch destination.pathExtension.lowercased() {
        case "heic", "heif":
            try context.writeHEIF10Representation(of: image, to: output, colorSpace: space, options: quality)
        case "jpg", "jpeg":
            try context.writeJPEGRepresentation(of: image, to: output, colorSpace: space, options: quality)
        default:
            // PNG and TIFF go through ImageIO: lossless, and TIFF compressed as the engine's (Deflate).
            guard let cgImage = context.createCGImage(image, from: image.extent, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: space) else {
                throw EngineError(message: "The export couldn’t be finished.")
            }
            try writeLossless(cgImage, properties: properties, to: output, png: destination.pathExtension.lowercased() == "png")
        }
        context.clearCaches()
    }

    /// A PNG or a TIFF (Deflate) of `image`, without its alpha, with `properties`.
    private static func writeLossless(_ image: CGImage, properties: [String: Any], to output: URL, png: Bool) throws {
        let opaque = opaqueCopy(image) ?? image
        let type = (png ? UTType.png : UTType.tiff).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw EngineError(message: "Could not write \(output.lastPathComponent).")
        }
        var options = properties
        if !png {
            var tiff = options[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = 8
            options[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        CGImageDestinationAddImage(destination, opaque, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EngineError(message: "Could not write \(output.lastPathComponent).") }
    }

    /// `image` drawn without an alpha channel, as the engine's files are: three samples a pixel.
    private static func opaqueCopy(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace else { return nil }
        let bits = image.bitsPerComponent
        let info: UInt32 = bits == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
