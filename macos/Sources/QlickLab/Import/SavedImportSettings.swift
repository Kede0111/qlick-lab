// Qlick Lab — GPL-3.0-only.
import Foundation

/// The import's Saved Settings, kept in the catalogue beside its projects (`saved-settings.json`, top-level key
/// `qlick`), so they travel with it when it's copied, saved as another or opened on another Mac.
enum SavedImportSettings {
    static let fileName = "saved-settings.json"
    /// Where they were kept before 0.3: the app's preferences. Moved into the first catalogue that opens.
    static let oldKey = "qlick.importProfiles"

    private struct File: Codable {
        var qlick: Body
        struct Body: Codable {
            var schema = 1
            var importSettings: [String: ImportOptions]
        }
    }

    static func file(inCatalog directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The catalogue's Saved Settings; those kept in the preferences before move into it when it has none yet.
    static func read(inCatalog directory: URL, defaults: UserDefaults = .standard) -> [String: ImportOptions] {
        let url = file(inCatalog: directory)
        if let data = try? Data(contentsOf: url) {
            // A newer schema, or a file damaged, reads as none and isn't written over until something is saved.
            guard let file = try? JSONDecoder().decode(File.self, from: data), file.qlick.schema <= 1 else { return [:] }
            return file.qlick.importSettings
        }
        guard let data = defaults.data(forKey: oldKey),
              let old = try? JSONDecoder().decode([String: ImportOptions].self, from: data) else { return [:] }
        if write(old, inCatalog: directory) { defaults.removeObject(forKey: oldKey) }
        return old
    }

    @discardableResult static func write(_ settings: [String: ImportOptions], inCatalog directory: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(File(qlick: .init(importSettings: settings))).write(to: file(inCatalog: directory), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("saved settings: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
