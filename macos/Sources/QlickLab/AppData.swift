import Foundation

/// The app's own folders.
enum AppDataLocations {
    /// The folder name of the app's own data: the bundle identifier, so a
    /// preview build (`be.jackfrom.qlicklab.app.preview`) keeps its sessions, presets and
    /// caches apart from the release's. `swift run` has no bundle.
    static var root: String { Bundle.main.bundleIdentifier ?? "be.jackfrom.qlicklab" }
    /// Sessions and presets.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(root, isDirectory: true)
    }
    static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(root, isDirectory: true)
    }
}
