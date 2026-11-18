import XCTest
@testable import QlickLab

/// Qlick Lab: the proxies' queue counts photographs, each once, makes no more than the cache keeps, and says how
/// far it got as the pill and the panel show it.
final class BackgroundWorkTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testCandidatesAreRawPhotographsEachOnce() {
        let raw = url("/roll/L1000001.DNG"), other = url("/roll/L1000002.DNG")
        let items = [raw, raw.variant("a1b2c3d4"), raw.variant("e5f6a7b8"), other, url("/roll/scan.jpg"), url("/roll/L1000003.dng")]
        // A duplicate is its photograph's; a JPEG has no proxy; one waiting or made already is left out.
        XCTAssertEqual(ProxyMaker.candidates(items, skipping: [other]), [raw, url("/roll/L1000003.dng")])
        XCTAssertEqual(ProxyMaker.candidates(items + items, skipping: []).count, 3)
    }

    func testRoomIsWhatThePruneLeaves() {
        let mb = 1024 * 1024
        // 47.5 GB of proxies' room, pruned to three quarters: about 4,050 of 9 MB.
        let limit = 50 * 1024 * mb - 2560 * mb
        XCTAssertEqual(ProxyMaker.room(limit: limit, averageSize: 9 * mb, queued: 0), 4_053)
        // Less those already there or waiting.
        XCTAssertEqual(ProxyMaker.room(limit: limit, averageSize: 9 * mb, queued: 1_454), 2_599)
        XCTAssertEqual(ProxyMaker.room(limit: limit, averageSize: 9 * mb, queued: 9_000), 0)
        XCTAssertEqual(ProxyMaker.room(limit: 0, averageSize: 0, queued: 0), 0)
    }

    func testHelpersAreBounded() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(ProxyMaker.helpers(cores: 14, memory: 36 * gb, lowPower: false), 3)
        XCTAssertEqual(ProxyMaker.helpers(cores: 10, memory: 16 * gb, lowPower: false), 2)
        XCTAssertEqual(ProxyMaker.helpers(cores: 8, memory: 8 * gb, lowPower: false), 1)
        XCTAssertEqual(ProxyMaker.helpers(cores: 4, memory: 64 * gb, lowPower: false), 1)
        XCTAssertEqual(ProxyMaker.helpers(cores: 64, memory: 512 * gb, lowPower: true), 1)
        for cores in [1, 8, 12, 24, 128] { XCTAssertLessThanOrEqual(ProxyMaker.helpers(cores: cores, memory: 1024 * gb, lowPower: false), 3) }
    }

    func testOrderGoesOutwardFromTheOpenPhotograph() {
        let all = (0..<7).map { url("/roll/L\($0).DNG") }
        XCTAssertEqual(ProxyMaker.order(all, around: all[3], in: all), [all[3], all[2], all[4], all[1], all[5], all[0], all[6]])
        XCTAssertEqual(ProxyMaker.order(all, around: nil, in: all), all)
        XCTAssertEqual(ProxyMaker.order([all[6], all[0]], around: all[5], in: all), [all[6], all[0]])
    }

    func testFigures() {
        let proxies = BackgroundTask(kind: .proxies, title: "Making proxies", done: 1_411, total: 4_950, stop: {})
        XCTAssertEqual(proxies.figure, "\(BackgroundWork.number(1_412)) of \(BackgroundWork.number(4_950))")
        XCTAssertEqual(proxies.fraction ?? 0, 1_411.0 / 4_950.0, accuracy: 1e-9)
        // The last one under way never reads past the total.
        XCTAssertEqual(BackgroundTask(kind: .previews, title: "", done: 3, total: 3, stop: nil).figure, "3 of 3")
        let thumbnails = BackgroundTask(kind: .thumbnails, title: "", done: 0, total: nil, left: 48, stop: nil)
        XCTAssertEqual(thumbnails.figure, "48 left")
        XCTAssertNil(thumbnails.fraction)
    }
}
