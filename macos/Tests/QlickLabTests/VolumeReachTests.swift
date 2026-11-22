import XCTest
@testable import QlickLab

/// A disk is away only when it truly is (not mounted, or the Mac says a share stopped answering), never because it's
/// slow; and a slow disk never holds the window up.
final class VolumeReachTests: XCTestCase {
    func testOnlyDisksUnderVolumesAreWatched() {
        XCTAssertEqual(VolumeReach.volume(of: "/Volumes/NAS QUENTIN/PHOTOS/2024/a.RAF"), "/Volumes/NAS QUENTIN")
        XCTAssertEqual(VolumeReach.volume(of: "/Volumes/NAS"), "/Volumes/NAS")
        XCTAssertNil(VolumeReach.volume(of: "/Users/someone/Pictures/a.DNG"))
        XCTAssertEqual(VolumeReach.volumeName(of: "/Volumes/NAS QUENTIN/PHOTOS"), "NAS QUENTIN")
    }

    private func someMountedVolume() throws -> String {
        let list = VolumeReach.mountList()
        let mounted = (try FileManager.default.contentsOfDirectory(atPath: "/Volumes")).map { "/Volumes/" + $0 }.first { list[$0] != nil }
        // A Mac with no disk plugged in (GitHub's runners) has nothing to look at: the test says so and is skipped.
        guard let mounted else { throw XCTSkip("No disk under /Volumes on this Mac") }
        return mounted
    }

    /// A NAS saturated by the lab's reading (1 Gb/s, 2026-11-22) answers in seconds: the window doesn't wait for it,
    /// the disk never shows as away, and once the look comes back the lab is told to look again.
    func testASlowDiskIsNeverAwayAndNeverHoldsTheWindow() throws {
        let volume = try someMountedVolume()
        let back = expectation(forNotification: VolumeReach.changed, object: nil) { ($0.userInfo?["volume"] as? String) == volume }
        let start = Date()
        let value = VolumeReach.look(volume + "/Photos", patience: 0.2) { Thread.sleep(forTimeInterval: 1.5); return true }
        XCTAssertNil(value, "not known yet")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(VolumeReach.offline(volume + "/Photos"))
        XCTAssertFalse(VolumeReach.isSilent(volume))
        XCTAssertTrue(VolumeReach.answers(volume + "/Photos"))
        // While its answer is out, the window doesn't wait on it again, and takes its files as there.
        let again = Date()
        XCTAssertTrue(VolumeReach.exists(volume + "/Photos/a.RAF"))
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.1)
        wait(for: [back], timeout: 5)
        XCTAssertFalse(VolumeReach.offline(volume + "/Photos"))
    }

    /// Off the main thread a look is made at the disk's speed, however slow.
    func testOffTheMainThreadASlowLookIsWaitedFor() throws {
        let volume = try someMountedVolume()
        let done = expectation(description: "answered")
        DispatchQueue.global().async {
            let value = VolumeReach.look(volume + "/Photos", patience: 0.1) { Thread.sleep(forTimeInterval: 0.5); return 7 }
            XCTAssertEqual(value, 7)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testADiskNotMountedIsAway() {
        let volume = "/Volumes/QlickLabNoSuchDisk-\(UUID().uuidString)"
        XCTAssertTrue(VolumeReach.offline(volume + "/Photos"))
        XCTAssertFalse(VolumeReach.answers(volume + "/Photos"))
        XCTAssertFalse(VolumeReach.exists(volume + "/Photos/a.RAF"))
        XCTAssertNil(VolumeReach.look(volume) { true })
        XCTAssertFalse(VolumeReach.isLocal(volume))
    }

    /// A share the Mac says stopped answering is away until it answers again; nothing waits on it meanwhile.
    func testAShareTheMacSaysIsSilentIsAwayThenBack() throws {
        let volume = try someMountedVolume()
        VolumeReach.testSetSilent(volume, true)
        XCTAssertTrue(VolumeReach.offline(volume + "/Photos"))
        let start = Date()
        XCTAssertFalse(VolumeReach.exists(volume + "/Photos"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        let back = expectation(forNotification: VolumeReach.changed, object: nil) {
            ($0.userInfo?["volume"] as? String) == volume && !VolumeReach.isSilent(volume)
        }
        VolumeReach.testSetSilent(volume, false)
        wait(for: [back], timeout: 5)
        XCTAssertFalse(VolumeReach.offline(volume + "/Photos"))
    }

    func testTheStartupDiskIsAskedDirectly() {
        XCTAssertTrue(VolumeReach.exists(NSTemporaryDirectory()))
        XCTAssertTrue(VolumeReach.answers("/Users"))
    }

    /// `URL(fileURLWithPath:)` without `isDirectory:` asks the disk whether the path is a folder. For a photograph or a
    /// folder on a NAS that doesn't answer, that question never returns, and done at launch it kept the lab from
    /// opening (the recent files, 2026-11-22). The lab's code says which it is; only these files, whose paths are
    /// the lab's own or a developer's, may leave it out.
    func testNoPathAsksTheDiskWhetherItIsAFolder() throws {
        let sources = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/QlickLab", isDirectory: true).standardizedFileURL
        let allowed: Set<String> = ["Automation.swift", "Engine.swift", "Theme.swift", "Main.swift", "RecipeBundle.swift", "AutoStraighten.swift",
                                    "PhotoFolderWatcher.swift", "ImportLoupe.swift", "ImportRun.swift", "InteractionBenchmark.swift", "GridBenchmark.swift",
                                    "SpeedBenchmark.swift", "LaunchBenchmark.swift"]
        let pattern = try NSRegularExpression(pattern: #"URL\(fileURLWithPath: [^,()]*(\([^()]*\))?[^,()]*\)"#)
        var found: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            guard !allowed.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.append("\(file.lastPathComponent): \((text as NSString).substring(with: match.range))")
            }
        }
        XCTAssertEqual(found, [], "say isDirectory: true or false")
    }

    /// Paths are made standard by their words alone: Foundation's own asks whether the file can be reached.
    func testPathsAreStandardizedWithoutTheDisk() throws {
        XCTAssertEqual(URL.labStandardizing("/Volumes/NAS/a/./b/../c//d.DNG"), "/Volumes/NAS/a/c/d.DNG")
        XCTAssertEqual(URL.labStandardizing("/private/tmp/x"), "/tmp/x")
        XCTAssertEqual(URL.labStandardizing("/private/var/folders/x"), "/var/folders/x")
        XCTAssertEqual(URL(fileURLWithPath: "/Volumes/NAS/a/", isDirectory: true).labStandardized.hasDirectoryPath, true)
        let sources = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/QlickLab", isDirectory: true).labStandardized
        var found: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" && file.lastPathComponent != "LabPath.swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(".standardizedFileURL") { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, [], "use labStandardized")
    }
}
