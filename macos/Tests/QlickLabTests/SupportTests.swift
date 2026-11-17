import XCTest
@testable import QlickLab

/// The coffee question: once after 50 photographs, a big batch counting once, then rarely, never after a no.
final class SupportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "qlick-support-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testItWaitsForFiftyPhotographs() {
        for _ in 0..<49 { XCTAssertFalse(Support.record(1, in: defaults)) }
        XCTAssertTrue(Support.record(1, in: defaults))
    }

    func testABigBatchAsksOnceOnly() {
        let now = Date()
        XCTAssertTrue(Support.record(300, in: defaults, now: now))
        Support.markAsked(in: defaults, now: now)
        XCTAssertFalse(Support.record(300, in: defaults, now: now))
        XCTAssertFalse(Support.due(defaults, now: now.addingTimeInterval(24 * 60 * 60)))
    }

    func testItComesBackAfterNinetyDaysAndFiftyMore() {
        let asked = Date()
        Support.record(60, in: defaults, now: asked)
        Support.markAsked(in: defaults, now: asked)
        let later = asked.addingTimeInterval(Support.interval + 1)
        XCTAssertFalse(Support.record(10, in: defaults, now: later), "Too few photographs since")
        XCTAssertTrue(Support.record(40, in: defaults, now: later))
    }

    func testNeverAgainAfterNo() {
        defaults.set(true, forKey: Support.Key.stopped)
        XCTAssertFalse(Support.record(500, in: defaults))
    }
}
