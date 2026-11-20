// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// Several recipes in one `.qlickrecipes` file: written, read back, and nothing read outside it.
final class RecipeBundleTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testABundleKeepsItsRecipesTheirNamesIdentifiersAndStars() throws {
        let recipes = [RecipeBundle.Recipe(name: "Portra Warm", id: "A1", favourite: true, data: Data(#"{"film":"portra"}"#.utf8)),
                       RecipeBundle.Recipe(name: "Tri-X: Push", id: "B2", favourite: false, data: Data(#"{"film":"trix"}"#.utf8)),
                       RecipeBundle.Recipe(name: "Portra Warm", id: "C3", favourite: false, data: Data(#"{"film":"portra2"}"#.utf8))]
        let url = try folder().appendingPathComponent("Three.\(RecipeBundle.fileExtension)")
        try RecipeBundle.write(recipes, to: url)
        // A zip archive, so it travels as one file.
        XCTAssertEqual(try Data(contentsOf: url).prefix(2), Data("PK".utf8))
        XCTAssertEqual(try RecipeBundle.read(url), recipes, "names as they were, even one a file can't bear, and two of the same name")
        XCTAssertEqual(RecipeBundle.suggestedName(["Portra Warm", "Tri-X"]), "2 Recipes")
    }

    func testABundleNamingAFileOutsideItsRecipesIsRefused() throws {
        let work = try folder()
        try FileManager.default.createDirectory(at: work.appendingPathComponent("Recipes"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: work.appendingPathComponent("secret.json"))
        let manifest = RecipeBundle.Manifest(recipes: [.init(file: "../secret.json", name: "Secret", id: "S")])
        try JSONEncoder().encode(manifest).write(to: work.appendingPathComponent("manifest.json"))
        let url = work.appendingPathComponent("Bad.\(RecipeBundle.fileExtension)")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.lastPathComponent, "manifest.json", "Recipes", "secret.json"]
        zip.currentDirectoryURL = work
        try zip.run(); zip.waitUntilExit()
        XCTAssertThrowsError(try RecipeBundle.read(url))
    }

    func testAFileThatIsntABundleSaysSo() throws {
        let url = try folder().appendingPathComponent("Not.\(RecipeBundle.fileExtension)")
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try RecipeBundle.read(url))
    }
}
