// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// The import's checks (imported or left out) act on the selection, and only on it.
final class ImportChecksTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/c/A.DNG", isDirectory: false), b = URL(fileURLWithPath: "/c/B.DNG", isDirectory: false)
    private let c = URL(fileURLWithPath: "/c/C.DNG", isDirectory: false), d = URL(fileURLWithPath: "/c/D.DNG", isDirectory: false)
    private var shown: [URL] { [a, b, c, d] }

    /// A frame's check, clicked in a selection of several: the whole selection, in the grid's order, nothing else.
    func testAFramesCheckActsOnItsSelection() {
        XCTAssertEqual(ImportSession.checkTargets(clicked: c, selected: [c, a], shown: shown), [a, c])
        // Outside the selection, or with one frame selected: that frame alone.
        XCTAssertEqual(ImportSession.checkTargets(clicked: d, selected: [c, a], shown: shown), [d])
        XCTAssertEqual(ImportSession.checkTargets(clicked: b, selected: [b], shown: shown), [b])
        XCTAssertEqual(ImportSession.checkTargets(clicked: b, selected: [], shown: shown), [b])
    }

    /// The bar's Check and Uncheck: the selection when there is one of several, else every frame shown.
    func testTheBarsChecksActOnTheSelection() {
        XCTAssertEqual(ImportSession.checkAllTargets(selected: [d, b], shown: shown), [b, d])
        XCTAssertEqual(ImportSession.checkAllTargets(selected: [b], shown: shown), shown)
        XCTAssertEqual(ImportSession.checkAllTargets(selected: [], shown: shown), shown)
        // A frame selected but filtered out of the grid isn't touched.
        XCTAssertEqual(ImportSession.checkAllTargets(selected: [a, URL(fileURLWithPath: "/c/E.DNG", isDirectory: false)], shown: shown), [a])
    }
}
