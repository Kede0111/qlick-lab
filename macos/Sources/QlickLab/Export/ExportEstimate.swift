// Qlick Lab — GPL-3.0-only.
import Foundation
import ImageIO

/// About how heavy an exported file will be, before it's made, as a lab's ticket says. Bytes a pixel, measured on a
/// 60-megapixel Leica M11 DNG developed with its grain (which is most of a file's weight: the grain is real detail),
/// then corrected by what this Mac's own exports weighed: each export records its bytes a pixel for its format and
/// quality, and the estimate follows the last ones.
enum ExportEstimate {
    /// (quality, bytes a pixel), highest quality first; between two, the estimate is drawn on a line.
    static let jpeg: [(Int, Double)] = [(100, 1.28), (95, 0.53), (92, 0.375), (90, 0.32), (85, 0.241), (80, 0.199), (70, 0.145), (1, 0.03)]
    static let heif: [(Int, Double)] = [(100, 2.33), (95, 0.885), (92, 0.712), (90, 0.63), (85, 0.391), (75, 0.349), (60, 0.264), (1, 0.02)]
    /// Lossless: (bits, bytes a pixel).
    static let png: [Int: Double] = [8: 1.64, 16: 5.74]
    static let tiff: [Int: Double] = [8: 1.87, 16: 5.26]

    /// The key a format, quality and sharpening learn under.
    static func key(_ format: OutputFormat, _ save: SaveSettings) -> String {
        let base = switch format {
        case .jpeg: "jpeg-\(save.jpegQuality)"
        case .heif: "heif-\(save.heifQuality)"
        case .png, .tiff: "\(format.rawValue)-\(save.bitDepth ?? SaveSettings.bitDepth(for: format))"
        }
        return save.sharpening == .none ? base : "\(base)-\(save.sharpening.rawValue)-\(save.sharpeningAmount.rawValue)"
    }

    /// Sharpening makes the grain crisper, and the file heavier: measured +13 % for a screen's on a HEIF, +40 % for
    /// glossy paper's on a TIFF, at the standard amount.
    static func sharpeningFactor(_ save: SaveSettings) -> Double {
        let extra: Double = switch save.sharpening {
        case .none: 0
        case .screen: 0.13
        case .matte, .glossy: 0.4
        }
        let amount: Double = switch save.sharpeningAmount { case .low: 0.5; case .standard: 1; case .high: 1.6 }
        return 1 + extra * amount
    }

    /// Bytes a pixel from the table.
    static func table(_ format: OutputFormat, _ save: SaveSettings) -> Double {
        switch format {
        case .jpeg: interpolate(jpeg, save.jpegQuality)
        case .heif: interpolate(heif, save.heifQuality)
        case .png: png[(save.bitDepth ?? 8) >= 16 ? 16 : 8]!
        case .tiff: tiff[(save.bitDepth ?? 16) >= 16 ? 16 : 8]!
        }
    }

    static func interpolate(_ points: [(Int, Double)], _ quality: Int) -> Double {
        guard let upper = points.first, quality < upper.0 else { return points.first?.1 ?? 0 }
        for (high, low) in zip(points, points.dropFirst()) where quality >= low.0 {
            let t = Double(quality - low.0) / Double(max(high.0 - low.0, 1))
            return low.1 + (high.1 - low.1) * t
        }
        return points.last?.1 ?? 0
    }

    /// Bytes a pixel learned from this Mac's exports, by key.
    private static var learned: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "qlick.exportBytesPerPixel") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "qlick.exportBytesPerPixel") }
    }

    /// The estimate in bytes, nil when the size is unknown.
    static func bytes(format: OutputFormat, save: SaveSettings, pixels: CGSize) -> Double? {
        let count = Double(pixels.width * pixels.height)
        guard count > 0 else { return nil }
        let rate = learned[key(format, save)] ?? table(format, save) * sharpeningFactor(save)
        return rate * count
    }

    /// "38 MB", "820 KB"; nil when the size is unknown.
    static func text(format: OutputFormat, save: SaveSettings, pixels: CGSize) -> String? {
        bytes(format: format, save: save, pixels: pixels).map(Self.format)
    }

    static func format(_ bytes: Double) -> String {
        if bytes >= 10e6 { return "\(Int((bytes / 1e6).rounded())) MB" }
        if bytes >= 1e6 { return String(format: "%.1f MB", bytes / 1e6) }
        return "\(max(1, Int((bytes / 1e3).rounded()))) KB"
    }

    /// `record`, off the main thread: the file may be on a slow disk.
    static func recordLater(_ file: URL, save: SaveSettings) {
        guard let format = OutputFormat(extension: file.pathExtension) else { return }
        Task.detached(priority: .utility) { record(file, format: format, save: save) }
    }

    /// After an export: what its file weighed, so the next estimate follows this Mac's photographs (their grain,
    /// their sizes). Weighted towards the newest, never jumping on one odd photograph.
    static func record(_ file: URL, format: OutputFormat, save: SaveSettings) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return }
        let rate = Double(size) / Double(width * height)
        let key = key(format, save)
        var values = learned
        values[key] = values[key].map { $0 * 0.6 + rate * 0.4 } ?? rate
        learned = values
    }
}
