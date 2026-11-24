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

    /// Leave in Place takes in what's checked, never the rest of the folder: the unchecked are kept out of the lab,
    /// with the JPEG of a pair the RAW + JPEG choice leaves, but not what the lab already showed or what lies outside.
    func testLeaveInPlaceKeepsTheUncheckedOut() {
        func file(_ path: String) -> ImportFile { ImportFile(url: URL(fileURLWithPath: path), size: 1) }
        let frames = [ImportFrame(file: file("/c/A.DNG"), companion: file("/c/A.JPG")), ImportFrame(file: file("/c/B.DNG")),
                      ImportFrame(file: file("/c/sub/C.DNG")), ImportFrame(file: file("/c/D.DNG")), ImportFrame(file: file("/elsewhere/E.DNG"))]
        let taken = ImportPlan.files(of: frames[0], .rawOnly).map(\.url)
        let shownBefore = URL(fileURLWithPath: "/c/D.DNG")
        let left = ImportSession.leftOut(of: frames, taken: taken, within: [URL(fileURLWithPath: "/c", isDirectory: true)]) { $0 == shownBefore }
        XCTAssertEqual(left.map(\.path), ["/c/A.JPG", "/c/B.DNG", "/c/sub/C.DNG"])
        // Everything checked: nothing is kept out.
        let all = frames.flatMap { ImportPlan.files(of: $0, .both).map(\.url) }
        XCTAssertEqual(ImportSession.leftOut(of: frames, taken: all, within: [URL(fileURLWithPath: "/c", isDirectory: true)]) { _ in false }, [])
    }
}
