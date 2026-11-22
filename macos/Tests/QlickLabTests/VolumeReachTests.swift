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

    /// A disk plugged into the Mac (an exFAT SSD busy with the lab's reading, 2026-11-22) is slow at worst, never
    /// gone while mounted: it's asked directly and never left aside, or its photographs would vanish from the lab.
    func testADiskPluggedInIsNeverLeftAside() throws {
        let local = (try FileManager.default.contentsOfDirectory(atPath: "/Volumes")).map { "/Volumes/" + $0 }.first(where: VolumeReach.isLocal)
        // A Mac with no disk plugged in (GitHub's runners) has nothing to look at: the test says so and is skipped.
        guard let volume = local else { throw XCTSkip("No disk under /Volumes on this Mac") }
        let value = VolumeReach.look(volume + "/Photos", patience: 0.1) { Thread.sleep(forTimeInterval: 0.4); return true }
        XCTAssertEqual(value, true, "a slow look is waited for")
        XCTAssertFalse(VolumeReach.isSilent(volume))
        XCTAssertFalse(VolumeReach.isLocal("/Volumes/QlickLabNoSuchDisk-\(UUID().uuidString)"), "a disk not mounted is watched as a share")
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
