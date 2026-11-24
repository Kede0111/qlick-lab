// Qlick Lab — GPL-3.0-only.
import Foundation

/// The three things a lab hands back, as Print's File section orders them in one click: a proof to look at on a
/// screen, the scan to keep, the print's file for paper. Each sets the format, quality, size, colour space,
/// sharpening and resolution together; any of them can still be changed afterwards, and the order then reads as
/// the photographer's own.
enum LabOrder: String, CaseIterable, Sendable {
    case proof, scan, print

    var title: String {
        switch self {
        case .proof: "Proof"
        case .scan: "Scan"
        case .print: "Print"
        }
    }

    /// What it makes, for the line under the choice.
    var detail: String {
        switch self {
        case .proof: "For a screen: JPEG 90, 2048 px on the long edge, sRGB, sharpened for the screen. Under a megabyte."
        case .scan: "The photograph to keep: HEIF 10-bit 90 at full size, Display P3, the grain whole."
        case .print: "For paper: TIFF 8-bit, lossless, at full size, sRGB as most labs ask, 300 ppi, sharpened for glossy paper."
        }
    }

    var format: OutputFormat {
        switch self {
        case .proof: .jpeg
        case .scan: .heif
        case .print: .tiff
        }
    }
    var quality: Int? {
        switch self {
        case .proof: 90
        case .scan: 90
        case .print: nil
        }
    }
    var bitDepth: Int? { self == .print ? 8 : nil }
    var size: ExportSize { self == .proof ? ExportSize(edge: .long, pixels: 2048) : ExportSize(edge: .full, pixels: ExportSize.last.pixels) }
    var colorSpace: String { self == .scan ? "Display P3" : "sRGB" }
    var sharpening: OutputSharpening {
        switch self {
        case .proof: .screen
        case .scan: .none
        case .print: .glossy
        }
    }
    var ppi: Int { SaveSettings.defaultPPI }

    /// Stores its choices as the next export's (the save panel opens on them).
    func remember() {
        OutputFormat.last = format
        if let quality { SaveSettings.setQuality(quality, for: format) }
        if let bitDepth { SaveSettings.setBitDepth(bitDepth, for: format) }
        ExportSize.last = size
        OutputSharpening.remembered = sharpening
        SharpeningAmount.remembered = .standard
        SaveSettings.ppi = ppi
        if let index = SaveSettings.colorSpaces.firstIndex(of: colorSpace) { SaveSettings.chosenSpace = index }
    }

    /// The order the remembered choices make, with `space` the output colour space; nil when they're the
    /// photographer's own.
    static func current(space: String) -> LabOrder? {
        allCases.first { order in
            let last = ExportSize.last
            let sameSize = order.size.edge == last.edge && (order.size.edge == .full || order.size.pixels == last.pixels)
            return OutputFormat.last == order.format && sameSize && space == order.colorSpace
                && order.quality.map { SaveSettings.quality(for: order.format) == $0 } ?? true
                && order.bitDepth.map { SaveSettings.bitDepth(for: order.format) == $0 } ?? true
                && OutputSharpening.remembered == order.sharpening
                && (order.sharpening == .none || SharpeningAmount.remembered == .standard)
                && SaveSettings.ppi == order.ppi
        }
    }
}
