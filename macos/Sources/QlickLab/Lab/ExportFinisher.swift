// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Sharpening for where the photograph is shown, after it's sized: a screen wants a fine, light touch; paper a wider
/// one, matte more than glossy (its ink spreads).
enum OutputSharpening: String, CaseIterable, Sendable {
    case none, screen, matte, glossy
    var title: String {
        switch self { case .none: "None"; case .screen: "Screen"; case .matte: "Matte Paper"; case .glossy: "Glossy Paper" }
    }
    /// The unsharp mask's radius, in pixels of the finished file, at its long side of 3000 (scaled with it).
    var radius: Double { switch self { case .none: 0; case .screen: 0.6; case .matte: 1.6; case .glossy: 1.1 } }
}

enum SharpeningAmount: String, CaseIterable, Sendable {
    case low, standard, high
    var title: String { rawValue.capitalized }
    var intensity: Double { switch self { case .low: 0.25; case .standard: 0.5; case .high: 0.85 } }
}

/// What the file says of where and how it was taken.
enum ExportMetadata: String, CaseIterable, Sendable {
    case all, noLocation, none
    var title: String { switch self { case .all: "All"; case .noLocation: "All but Location"; case .none: "None" } }
}

/// The last step of a save or an export, after the engine has written the file: 10-bit HEIF (the engine writes a
/// 16-bit TIFF, which macOS encodes), output sharpening, and the metadata kept. Nothing to do, the engine's file is
/// the export as it is.
enum ExportFinisher {
    static func isHEIF(_ url: URL) -> Bool { ["heic", "heif"].contains(url.pathExtension.lowercased()) }

    static func needed(_ save: SaveSettings, destination: URL) -> Bool {
        isHEIF(destination) || save.sharpening != .none || save.metadata != .all
    }

    /// Where the engine writes for `destination`: beside it, hidden; a TIFF for a HEIF.
    static func engineFile(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".qlick-\(UUID().uuidString).\(isHEIF(destination) ? "tif" : destination.pathExtension)")
    }

    private static let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])

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
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] { properties[key as String] = nil }
        }
        image = image.settingProperties(properties)
        let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(save.jpegQuality) / 100]
        let sixteen = (save.bitDepth ?? 8) >= 16
        switch destination.pathExtension.lowercased() {
        case "heic", "heif":
            try context.writeHEIF10Representation(of: image, to: output, colorSpace: space, options: quality)
        case "jpg", "jpeg":
            try context.writeJPEGRepresentation(of: image, to: output, colorSpace: space, options: quality)
        case "png":
            try context.writePNGRepresentation(of: image, to: output, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: space)
        default:
            try context.writeTIFFRepresentation(of: image, to: output, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: space)
        }
        context.clearCaches()
    }
}
