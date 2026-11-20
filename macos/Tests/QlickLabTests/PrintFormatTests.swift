// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// Print's formats: applied, they are what the export offers first; kept, they come back.
final class PrintFormatTests: XCTestCase {
    private let keys = ["outputFormat", "jpegQuality", "colorSpace", "bitDepth.tiff", "bitDepth.png", "exportEdge", "exportEdgePixels"]

    func testAFormatAppliedIsWhatTheExportOffers() throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }

        let web = try XCTUnwrap(PrintFormat.first.first { $0.name == "Web" })
        web.apply()
        XCTAssertEqual(OutputFormat.last, .jpeg)
        XCTAssertEqual(SaveSettings.lastQuality, 90)
        XCTAssertEqual(ExportSize.last, ExportSize(edge: .long, pixels: 2048))
        XCTAssertTrue(web.isCurrent)
        XCTAssertEqual(PrintFormat.first.filter(\.isCurrent).map(\.name), ["Web"], "one format is the export's at a time")
        XCTAssertEqual(web.summary, "JPEG 90 · sRGB · 2048 px long edge")

        let archive = try XCTUnwrap(PrintFormat.first.first { $0.name == "Archive TIFF" })
        archive.apply()
        XCTAssertEqual(SaveSettings.bitDepth(for: .tiff), 16)
        XCTAssertEqual(SaveSettings.colorSpaces[SaveSettings.chosenSpace], "Adobe RGB (1998)")
        XCTAssertTrue(PrintFormat.current(named: "Mine").sameSettings(as: archive))
    }

    func testFormatsKeptComeBack() {
        let suite = TestDefaults.name("qlick-print-formats"), defaults = UserDefaults(suiteName: suite)!
        defer { TestDefaults.remove(suite) }
        XCTAssertEqual(PrintFormat.load(defaults).map(\.name), ["Web", "Full Size JPEG", "Archive TIFF"])
        var formats = PrintFormat.load(defaults)
        formats.append(PrintFormat(name: "Lab Print", format: "tiff", quality: 95, colorSpace: "Display P3", bitDepth: 8, edge: "short", pixels: 3000))
        formats.removeFirst()
        PrintFormat.save(formats, defaults)
        XCTAssertEqual(PrintFormat.load(defaults).map(\.name), ["Full Size JPEG", "Archive TIFF", "Lab Print"])
    }
}
