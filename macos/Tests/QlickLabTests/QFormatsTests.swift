// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// `.qsidecar` and `.qrecipe`, shared with QLab (docs/q-formats.md).
final class QFormatsTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-qformats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A former `.qlick` is still read; the lab writes a `.qsidecar` and leaves the `.qlick` as it was.
    func testFormerSidecarsAreReadAndLeftAlone() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("IMG_1.CR3"); try Data("raw".utf8).write(to: photo)
        let legacy = #"{"qlick": 1, "defaultsVersion": 1, "variants": [{"id": "v1", "rating": 2}]}"#
        try Data(legacy.utf8).write(to: PhotoSidecar.legacyURL(for: photo))
        let store = SidecarStore()
        XCTAssertEqual(try store.read(photo: photo)?.variants.first?.rating, 2)
        store.enqueue(SidecarPatch(variant: "v1", rating: 4, defaultsVersion: 1, app: "test"), for: photo)
        _ = await store.flush()
        XCTAssertEqual(try store.read(photo: photo)?.variants.first?.rating, 4, "the .qsidecar wins")
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: PhotoSidecar.url(for: photo)))
        XCTAssertEqual(written["qsidecar"], .number(1)); XCTAssertNil(written["qlick"].integer)
        XCTAssertEqual(try String(contentsOf: PhotoSidecar.legacyURL(for: photo), encoding: .utf8), legacy)
        // Everything cleared: an empty .qsidecar stays, so the .qlick's rating doesn't come back.
        store.enqueue(SidecarPatch(variant: "v1", rating: 0, defaultsVersion: 1, app: "test"), for: photo)
        _ = await store.flush()
        XCTAssertEqual(try store.read(photo: photo)?.variants.first?.rating ?? 0, 0)
    }

    /// QLab's sidecar opens in the lab, and QLab's blocks survive the lab's writes.
    func testQLabsSidecarsAreReadAndItsBlocksKept() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("QLB_0001.DNG"); try Data("raw".utf8).write(to: photo)
        let qlab = #"""
        {"qsidecar": 1, "app": "QLab", "defaultsVersion": 1,
         "qlab": {"record": {"id": "R1"}, "order": ["V1"]},
         "variants": [{"id": "V1", "name": "Portra", "engine": {"name": "spektrafilm-rs", "revision": "689db67"},
                       "edits": {"film": "kodak_portra_400", "paper": "kodak_portra_endura", "params": {"enlarger": {"y_filter_shift": 3}}},
                       "flag": "pick", "qlab": {"version": {"id": "V1"}}}]}
        """#
        try Data(qlab.utf8).write(to: PhotoSidecar.url(for: photo))
        let store = SidecarStore(storage: { .qlickFiles })
        let read = try XCTUnwrap(try store.read(photo: photo))
        XCTAssertEqual(read.variants.first?.flag, .pick)
        XCTAssertEqual(read.variants.first?.edits?["film"], .string("kodak_portra_400"))
        store.enqueue(SidecarPatch(variant: "V1", rating: 5, defaultsVersion: 1, app: "test"), for: photo)
        _ = await store.flush()
        let after = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: PhotoSidecar.url(for: photo)))
        XCTAssertEqual(after["qlab"], .object(["record": .object(["id": .string("R1")]), "order": .array([.string("V1")])]))
        XCTAssertEqual(after["variants"].array.first?["qlab"], .object(["version": .object(["id": .string("V1")])]))
        XCTAssertEqual(after["variants"].array.first?["rating"], .number(5))
    }

    /// Recipes kept as `.json` become `.qrecipe` once, with their identifier; the former files are kept apart.
    func testRecipesBecomeQRecipesWithTheirIdentifiers() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let preset = #"{"simulation": {"film_stock": "kodak_portra_400", "print_paper": "kodak_portra_endura"}, "grain": {"blur": Infinity}}"#
        try Data(preset.utf8).write(to: dir.appendingPathComponent("Portra.json"))
        try Data(#"{"ids": {"Portra.json": "ID-PORTRA"}}"#.utf8).write(to: dir.appendingPathComponent(".ids.json"))
        let library = PresetLibrary(folder: dir)
        let listed = try await library.list()
        XCTAssertEqual(listed.map(\.name), ["Portra"])
        XCTAssertEqual(listed.first?.url.pathExtension, "qrecipe")
        XCTAssertEqual(listed.first?.shelfID, "ID-PORTRA")
        let data = try Data(contentsOf: try XCTUnwrap(listed.first?.url))
        XCTAssertEqual(QRecipe.id(data), "ID-PORTRA")
        XCTAssertEqual(QRecipe.header(data)?["origin"] as? String, "Qlick Lab")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Infinity"), "Python's numbers stay as they were")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Before qrecipe/Portra.json").path))
        // Again: nothing more to do.
        let again = try await library.list(); XCTAssertEqual(again.count, 1)
        // A recipe from QLab keeps its id, its name and QLab's block; a copy gets a new id.
        let fromQLab = #"{"simulation": {"film_stock": "kodak_gold_200"}, "qrecipe": {"format": 1, "id": "ID-QLAB", "name": "Gold", "origin": "QLab"}, "qlab": {"recipe": {"name": "Gold"}}}"#
        let added = try await library.add(Data(fromQLab.utf8), name: "Gold")
        let addedData = try Data(contentsOf: added.url)
        XCTAssertEqual(QRecipe.id(addedData), "ID-QLAB")
        XCTAssertEqual(QRecipe.header(addedData)?["origin"] as? String, "QLab")
        XCTAssertNotNil(try QRecipe.object(addedData)["qlab"])
        XCTAssertNil(QRecipe.id(QRecipe.withoutID(addedData)))
        // Renamed: the header follows.
        let renamed = try await library.rename(added, to: "Gold 200")
        XCTAssertEqual(QRecipe.header(try Data(contentsOf: renamed.url))?["name"] as? String, "Gold 200")
        XCTAssertEqual(renamed.shelfID, "ID-QLAB")
        // Edit Recipe: in place, the same id and name, QLab's block kept, a new revision so QLab sees the change.
        let before = QRecipe.header(try Data(contentsOf: renamed.url))
        let text = try XCTUnwrap(RecipeText.editing(String(decoding: try Data(contentsOf: renamed.url), as: UTF8.self),
                                                    develop: RecipeDevelop(groups: [.tone], values: [:], matchBrightness: false)))
        let edited = try await library.replace(renamed, with: Data(text.utf8))
        let editedData = try Data(contentsOf: edited.url)
        XCTAssertEqual(edited.url, renamed.url); XCTAssertEqual(edited.shelfID, "ID-QLAB")
        XCTAssertEqual(QRecipe.id(editedData), "ID-QLAB")
        XCTAssertEqual(QRecipe.header(editedData)?["name"] as? String, "Gold 200")
        XCTAssertNotNil(try QRecipe.object(editedData)["qlab"])
        XCTAssertNotEqual(QRecipe.header(editedData)?["revision"] as? String, before?["revision"] as? String)
    }

    /// A photograph from QLab opens with QLab's development (film, paper, its versions) and names its recipe, by the
    /// identifier the lab's copy of the recipe carries too.
    func testAPhotographFromQLabOpensWithItsDevelopmentAndRecipe() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("QLB_0032.DNG"); try Data("raw".utf8).write(to: photo)
        let qlab = #"""
        {"qsidecar": 1, "app": "QLab", "defaultsVersion": 1, "qlab": {"record": {"id": "R1"}},
         "variants": [
          {"id": "V2", "name": "Version 2", "recipe": "Kodak Vision3 250D (Q)", "recipeRef": {"id": "ID-VISION"},
           "engine": {"name": "spektrafilm-rs", "revision": "689db67"},
           "edits": {"film": "kodak_vision3_250d", "paper": "kodak_2383", "params": {"camera": {"exposure_compensation_ev": 0.3}}}},
          {"id": "V1", "name": "Version 1", "edits": {"film": "kodak_portra_400", "paper": "kodak_portra_endura"}}]}
        """#
        try Data(qlab.utf8).write(to: PhotoSidecar.url(for: photo))
        let data = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
            .appendingPathComponent("../../../data", isDirectory: true).standardizedFileURL
        let restore = SidecarRestore.read(photo: photo, store: SidecarStore(), data: data)
        XCTAssertNil(restore.problem, restore.problem ?? "")
        XCTAssertEqual(restore.variant, "V2")
        XCTAssertEqual(restore.edits?.state.film, "kodak_vision3_250d")
        XCTAssertEqual(restore.edits?.state.paper, "kodak_2383")
        XCTAssertEqual(restore.recipe, "Kodak Vision3 250D (Q)")
        XCTAssertEqual(restore.recipeID, "ID-VISION")
        let second = SidecarRestore.read(photo: photo, variant: "V1", store: SidecarStore(), data: data)
        XCTAssertEqual(second.edits?.state.film, "kodak_portra_400")
        XCTAssertNil(second.recipe)
    }
}
