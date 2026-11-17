// Qlick Lab — GPL-3.0-only.
import Foundation
import XCTest

/// The settings a test makes for itself, gone when it ends. Removing the domain leaves an empty file in
/// ~/Library/Preferences, and what's still alive of the test may write it again afterwards: the file goes at once,
/// and once more when the tests are over.
enum TestDefaults {
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
        for suite in lock.withLock({ suites }) { erase(suite) }
    }

    private static func erase(_ suite: String) {
        // Through the suite itself, written out at once: removed through another, the file comes back later.
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true).appendingPathComponent(suite + ".plist")
        try? FileManager.default.removeItem(at: file)
    }

    private final class Sweeper: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) { TestDefaults.sweep() }
    }
}
