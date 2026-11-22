import XCTest
@testable import QlickLab

/// A disk that doesn't answer (a NAS gone away while mounted) never holds the lab up: the look gives up after its
/// patience, the disk is left aside without waiting again, and it's taken back once it answers.
final class VolumeReachTests: XCTestCase {
    func testOnlyDisksUnderVolumesAreWatched() {
        XCTAssertEqual(VolumeReach.volume(of: "/Volumes/NAS QUENTIN/PHOTOS/2024/a.RAF"), "/Volumes/NAS QUENTIN")
        XCTAssertEqual(VolumeReach.volume(of: "/Volumes/NAS"), "/Volumes/NAS")
        XCTAssertNil(VolumeReach.volume(of: "/Users/someone/Pictures/a.DNG"))
        XCTAssertEqual(VolumeReach.volumeName(of: "/Volumes/NAS QUENTIN/PHOTOS"), "NAS QUENTIN")
    }

    func testADiskThatDoesNotAnswerIsLeftAsideThenTakenBack() {
        // A path whose top isn't there: once left aside, the watch finds it answering at once.
        let volume = "/Volumes/QlickLabNoSuchDisk-\(UUID().uuidString)"
        let back = expectation(forNotification: VolumeReach.changed, object: nil) { note in
            (note.userInfo?["volume"] as? String) == volume && !VolumeReach.isSilent(volume)
        }
        let start = Date()
        // A look that would take ten seconds, as a share whose server has gone does.
        let value = VolumeReach.look(volume + "/Photos", patience: 0.2) { Thread.sleep(forTimeInterval: 10); return true }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        // While it's aside, nothing waits on it.
        if VolumeReach.isSilent(volume) {
            let again = Date()
            XCTAssertFalse(VolumeReach.exists(volume + "/Photos/a.RAF"))
            XCTAssertLessThan(Date().timeIntervalSince(again), 0.1)
        }
        wait(for: [back], timeout: 5)
        XCTAssertFalse(VolumeReach.isSilent(volume))
    }

    func testTheStartupDiskIsAskedDirectly() {
        XCTAssertTrue(VolumeReach.exists(NSTemporaryDirectory()))
        XCTAssertTrue(VolumeReach.answers("/Users"))
    }
}
