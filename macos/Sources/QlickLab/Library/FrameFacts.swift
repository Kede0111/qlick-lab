// Qlick Lab — GPL-3.0-only.
import Foundation
import ImageIO
import Observation

/// What a file says about its own exposure: read from its EXIF and TIFF tags, never written.
struct FrameFacts: Equatable, Sendable {
    var date: Date?
    var camera: String?
    var lens: String?
    var iso: Double?
    /// Seconds.
    var exposure: Double?
    var aperture: Double?
    /// Millimetres.
    var focalLength: Double?
    var pixels: CGSize?

    nonisolated static func read(_ url: URL) -> FrameFacts {
        var facts = FrameFacts()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return facts }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func number(_ value: Any?) -> Double? {
            guard let value = (value as? [Any])?.first ?? value, let number = (value as? NSNumber)?.doubleValue, number > 0, number.isFinite else { return nil }
            return number
        }
        let shared = PhotoFacts(properties: properties)
        facts.camera = shared.camera
        facts.iso = shared.iso; facts.exposure = shared.exposure; facts.aperture = shared.aperture; facts.focalLength = shared.focalLength
        facts.lens = ((exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String)?.trimmingCharacters(in: .whitespaces)
        if facts.lens?.isEmpty == true { facts.lens = nil }
        if let text = (exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            facts.date = formatter.date(from: text)
        }
        if let width = number(properties[kCGImagePropertyPixelWidth]), let height = number(properties[kCGImagePropertyPixelHeight]) {
            let turned = (properties[kCGImagePropertyOrientation] as? NSNumber).map { $0.intValue >= 5 } ?? false
            facts.pixels = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        return facts
    }

    /// "1/250 s · f/2.8 · ISO 400 · 35 mm"
    var exposureLine: String {
        var parts: [String] = []
        if let exposure { parts.append(exposure >= 0.4 ? "\(Self.trim(exposure)) s" : "1/\(Int((1 / exposure).rounded())) s") }
        if let aperture { parts.append("f/\(Self.trim(aperture))") }
        if let iso { parts.append("ISO \(Int(iso.rounded()))") }
        if let focalLength { parts.append("\(Self.trim(focalLength)) mm") }
        return parts.joined(separator: " · ")
    }

    var dateLine: String? {
        date.map { $0.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "en_GB"))) }
    }

    var dayLine: String? {
        date.map { $0.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_GB"))) }
    }

    /// One line under a frame of the detailed sheet.
    var caption: String { [dateLine, exposureLine.isEmpty ? nil : exposureLine].compactMap { $0 }.joined(separator: "  ·  ") }

    private static func trim(_ value: Double) -> String {
        let text = String(format: value < 10 ? "%.1f" : "%.0f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }
}

/// The facts of the photographs on screen, read once each off the main thread.
@MainActor @Observable final class FrameFactsCache {
    private(set) var facts: [URL: FrameFacts] = [:]
    @ObservationIgnored private var reading: Set<URL> = []

    func get(_ item: URL) -> FrameFacts? {
        let file = item.photoFile
        if let known = facts[file] { return known }
        guard reading.insert(file).inserted else { return nil }
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { FrameFacts.read(file) }.value
            self?.reading.remove(file)
            self?.facts[file] = read
        }
        return nil
    }

    /// Without asking for it.
    func known(_ item: URL) -> FrameFacts? { facts[item.photoFile] }

    func forget() { facts = [:]; reading = [] }
}
