// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The lab's tokens live in `macos/design-tokens.json`; `Design/ThemeTokens.swift` is written from it here.
/// After changing the tokens: `QLICK_UPDATE_GENERATED=1 swift test --filter DesignTokensTests`.
final class DesignTokensTests: XCTestCase {
    private struct Entry: Decodable { let name: String; let doc: String; var srgb: String?; var displayP3: [Double]?; var value: Double? }
    private struct Tokens: Decodable { let colours, radii, motion, caps: [Entry] }

    private var tokensURL: URL { root.appendingPathComponent("macos/design-tokens.json") }
    private var generatedURL: URL { root.appendingPathComponent("macos/Sources/QlickLab/Design/ThemeTokens.swift") }

    private func tokens() throws -> Tokens { try JSONDecoder().decode(Tokens.self, from: Data(contentsOf: tokensURL)) }

    func testThemeTokensSwiftIsCurrent() throws {
        let source = try Self.render(tokens())
        if ProcessInfo.processInfo.environment["QLICK_UPDATE_GENERATED"] == "1" {
            try source.write(to: generatedURL, atomically: true, encoding: .utf8)
        }
        let current = try String(contentsOf: generatedURL, encoding: .utf8)
        XCTAssertEqual(current, source, "Design/ThemeTokens.swift is out of date: QLICK_UPDATE_GENERATED=1 swift test --filter DesignTokensTests")
    }

    /// The system accent (menus, default buttons, focus) is the tokens' red, in Display P3.
    func testTheAccentColourSetIsTheTokensRed() throws {
        let red = try XCTUnwrap(tokens().colours.first { $0.name == "accent" }?.displayP3)
        let url = root.appendingPathComponent("macos/Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let color = try XCTUnwrap((json["colors"] as? [[String: Any]])?.first?["color"] as? [String: Any])
        let parts = try XCTUnwrap(color["components"] as? [String: String])
        XCTAssertEqual([parts["red"], parts["green"], parts["blue"]], red.map { String(format: "%.3f", $0) })
    }

    /// The sRGB red is the Display P3 red brought into sRGB (clipped where P3 reaches past it).
    func testTheSRGBRedIsTheP3RedConverted() throws {
        let accent = try XCTUnwrap(tokens().colours.first { $0.name == "accent" })
        let p3 = try XCTUnwrap(accent.displayP3)
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let l = p3.map(linear)
        let m = [[1.2249, -0.2247, 0], [-0.0420, 1.0419, 0], [-0.0197, -0.0786, 1.0979]]
        let srgb = m.map { row in gamma(min(1, max(0, zip(row, l).map(*).reduce(0, +)))) }
        let hex = srgb.map { Int(($0 * 255).rounded()) }.reduce(0) { $0 << 8 | $1 }
        XCTAssertEqual(accent.srgb, String(format: "#%06x", hex))
    }

    private static func render(_ tokens: Tokens) throws -> String {
        func hex(_ s: String?) throws -> String {
            let s = try XCTUnwrap(s?.dropFirst().lowercased())
            XCTAssertEqual(s.count, 6)
            return "0x" + s
        }
        func number(_ v: Double?) throws -> String {
            let v = try XCTUnwrap(v)
            return v == v.rounded() ? String(Int(v)) : String(v)
        }
        var out = """
        // Qlick Lab — GPL-3.0-only.
        // Generated from macos/design-tokens.json by DesignTokensTests: don't edit by hand.
        // QLICK_UPDATE_GENERATED=1 swift test --filter DesignTokensTests writes it again.
        import CoreGraphics

        extension Theme {
            /// The colour tokens as sRGB 0xRRGGBB, for AppKit, the contrast tests and the hex lookups.
            enum Hex {

        """
        for c in tokens.colours {
            out += "        /// \(c.doc)\n        static let \(c.name): UInt32 = \(try hex(c.srgb))\n"
        }
        out += "    }\n\n    /// The colours that have a Display P3 value of their own, as (red, green, blue).\n    enum P3 {\n"
        for c in tokens.colours where c.displayP3 != nil {
            let p = c.displayP3!.map { String($0) }.joined(separator: ", ")
            out += "        static let \(c.name): (CGFloat, CGFloat, CGFloat) = (\(p))\n"
        }
        out += "    }\n"
        for (title, doc, entries) in [("Radius", "Corner radii, continuous, in points.", tokens.radii),
                                      ("Motion", "Motion: one spring, one quick ease-out.", tokens.motion),
                                      ("Caps", "The capital label (`CapsLabel`).", tokens.caps)] {
            out += "\n    /// \(doc)\n    enum \(title) {\n"
            for e in entries { out += "        /// \(e.doc)\n        static let \(e.name): CGFloat = \(try number(e.value))\n" }
            out += "    }\n"
        }
        out += "}\n"
        return out
    }
}
