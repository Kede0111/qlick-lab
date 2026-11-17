// Qlick Lab — GPL-3.0-only.
import Foundation
import XCTest

/// The settings a test makes for itself, gone when it ends. A suite named by a path keeps its file there, in the
/// temporary folder, never in ~/Library/Preferences (where the preferences daemon writes an emptied domain's file
/// again after the tests have quit). The file goes at once, and once more when the tests are over.
enum TestDefaults {
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-test-defaults", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// A new suite's name: `prefix` and a UUID, in the temporary folder.
    static func name(_ prefix: String) -> String { folder.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var suites: Set<String> = []
    private static let sweeper: Sweeper = {
        let sweeper = Sweeper()
        XCTestObservationCenter.shared.addTestObserver(sweeper)
        return sweeper
    }()

    static func remove(_ suite: String) {
        _ = sweeper
        lock.withLock { _ = suites.insert(suite) }
        erase(suite)
    }

    fileprivate static func sweep() {
        let all = lock.withLock { suites }
        for suite in all { erase(suite) }
        // The preferences daemon writes an emptied domain's file a moment later, now and then: once more after it.
        Thread.sleep(forTimeInterval: 1.5)
        for suite in all { deleteFile(suite) }
    }

    private static func deleteFile(_ suite: String) {
        let file = suite.hasPrefix("/") ? URL(fileURLWithPath: suite + ".plist")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true).appendingPathComponent(suite + ".plist")
        try? FileManager.default.removeItem(at: file)
    }

    private static func erase(_ suite: String) {
        // Through the suite itself, written out at once: removed through another, the file comes back later.
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        deleteFile(suite)
    }

    private final class Sweeper: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) { TestDefaults.sweep() }
    }
}
