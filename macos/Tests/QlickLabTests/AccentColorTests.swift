import XCTest
@testable import QlickLab

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app's accent colour (round 16, A · Graphite): the warm grey of its
/// outlines, so the system's menus, default buttons and focus take it
/// instead of the system blue. `scripts/build_app.sh` compiles it into
/// Assets.car and Info.plist names it.
final class AccentColorTests: XCTestCase {
    /// Qlick Lab: the system accent is QLab's red (Display P3 0.89, 0.11, 0.14), the pencil's, not Negs's outline grey.
    func testTheAccentIsTheOutlinesGrey() throws {
        let url = root.appendingPathComponent("macos/Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 1, "one colour, for light and dark alike")
        let color = try XCTUnwrap(colors.first?["color"] as? [String: Any])
        XCTAssertEqual(color["color-space"] as? String, "display-p3")
        let parts = try XCTUnwrap(color["components"] as? [String: String])
        XCTAssertEqual([parts["red"], parts["green"], parts["blue"]], ["0.890", "0.110", "0.140"])
        XCTAssertEqual(parts["alpha"], "1.000")
    }

    func testWhiteTextReadsOnIt() {
        // The menus draw a highlighted row's words in white.
        func linear(_ c: UInt32) -> Double { let v = Double(c) / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let hex = Theme.Hex.track
        let luminance = 0.2126 * linear(hex >> 16 & 0xff) + 0.7152 * linear(hex >> 8 & 0xff) + 0.0722 * linear(hex & 0xff)
        XCTAssertGreaterThan(1.05 / (luminance + 0.05), 4.5)
    }
}
