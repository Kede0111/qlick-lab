// Qlick Lab — GPL-3.0-only.
import Foundation
import UniformTypeIdentifiers

/// Several recipes in one file, to pass them on or keep them: a `.qlickrecipes` file, a zip archive holding
/// `manifest.json` (top-level key `qlick`: each recipe's file, name, identifier and star) and the recipes themselves in
/// `Recipes/`, in spektrafilm's own format, each one openable alone.
enum RecipeBundle {
    static let fileExtension = "qlickrecipes"
    /// Declared by the app (Info.plist), so the Finder opens a bundle in Qlick Lab with a double-click.
    static let typeIdentifier = "be.jackfrom.qlicklab.recipes"
    static var contentType: UTType { UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension, conformingTo: .zip) ?? .zip }

    struct Manifest: Codable, Equatable {
        var qlick = 1
        var kind = "recipes"
        var recipes: [Entry]
    }

    struct Entry: Codable, Equatable {
        /// The file in `Recipes/`.
        var file: String
        var name: String
        /// The recipe's identifier on the shelf (`PresetFile.shelfID`), so a star or a hiding follows it.
        var id: String
        var favourite: Bool?
    }

    struct Recipe: Equatable {
        var name: String
        var id: String
        var favourite: Bool
        var data: Data
    }

    static let most = 500

    /// Writes `recipes` as one bundle at `url` (replacing it).
    static func write(_ recipes: [Recipe], to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("qlick-recipes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent("Recipes", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [Entry] = [], taken = Set<String>()
        for recipe in recipes {
            let name = PresetName.unique(PresetName.from(fileName: recipe.name), taken: taken)
            taken.insert(PresetName.key(name))
            let file = "\(name).json"
            try recipe.data.write(to: folder.appendingPathComponent(file))
            entries.append(Entry(file: file, name: recipe.name, id: recipe.id, favourite: recipe.favourite ? true : nil))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(recipes: entries)).write(to: work.appendingPathComponent("manifest.json"))
        let zip = work.appendingPathComponent("bundle.zip")
        // Relative paths, from the work folder: manifest.json and Recipes/ at the archive's top.
        try run(["/usr/bin/zip", "-q", "-r", "-X", zip.lastPathComponent, "manifest.json", "Recipes"], in: work)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: zip, to: url)
    }

    /// The recipes of the bundle at `url`, in its order. Only the manifest's own files are read, inside the
    /// archive's `Recipes/` folder, each within a recipe's size.
    static func read(_ url: URL) throws -> [Recipe] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("qlick-recipes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try run(["/usr/bin/ditto", "-x", "-k", url.path, work.path])
        guard let data = try? Data(contentsOf: work.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.kind == "recipes" else {
            throw EngineError(message: "“\(url.lastPathComponent)” isn’t a bundle of recipes.")
        }
        guard manifest.qlick <= 1 else { throw EngineError(message: "“\(url.lastPathComponent)” comes from a newer Qlick Lab.") }
        let folder = work.appendingPathComponent("Recipes", isDirectory: true).labStandardized
        return try manifest.recipes.prefix(most).map { entry in
            let file = folder.appendingPathComponent(entry.file).labStandardized
            // Never outside the archive's own folder.
            guard file.deletingLastPathComponent().path == folder.path, !entry.file.contains("/") else {
                throw EngineError(message: "“\(url.lastPathComponent)” names a file outside its recipes.")
            }
            return Recipe(name: entry.name, id: entry.id, favourite: entry.favourite ?? false, data: try PresetLibrary.read(file))
        }
    }

    /// The name a bundle of these recipes is offered under.
    static func suggestedName(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names.count) Recipes"
    }

    private static func run(_ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EngineError(message: "The recipes couldn’t be packed or unpacked.") }
    }
}
