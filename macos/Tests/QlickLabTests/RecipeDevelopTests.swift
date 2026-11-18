import XCTest
@testable import QlickLab

/// Qlick Lab: a recipe's Develop part, saved beside spektrafilm's settings and applied with the box ticked.
@MainActor final class RecipeDevelopTests: XCTestCase {
    private func state(highlights: Double, exposure: Double, match: Bool, temperature: Double) -> EditState {
        var state = EditState()
        state.params["prep.highlights"] = .number(highlights)
        state.params["prep.saturation"] = .number(-10)
        state.params["prep.exposure_ev"] = .number(exposure)
        state.params["io.raw_white_balance.mode"] = .string("custom")
        state.params["io.raw_white_balance.temperature"] = .number(temperature)
        state.params["camera.auto_exposure"] = .bool(true)
        state.brightnessMatch = match ? BrightnessMatch(ev: 1.2) : nil
        return state
    }

    func testTheDevelopPartIsAddedToTheEnginesTextAndReadBack() throws {
        // As the engine writes it: Python's Infinity, which JSON lacks.
        let engine = "{\n  \"couplers\": {\n    \"langmuir_donor_k_rgb\": [\n      Infinity,\n      1.0\n    ]\n  },\n  \"simulation\": {\n    \"film_stock\": \"kodak_portra_400\"\n  }\n}\n"
        XCTAssertNil(RecipeDevelop.read(engine), "a recipe saved without it has none")
        let source = state(highlights: -40, exposure: 1.5, match: true, temperature: 4800)
        let develop = RecipeDevelop.taking([.tone, .brightness], from: source, exposureOffset: 0.3)
        let text = develop.adding(to: engine)
        XCTAssertTrue(text.hasPrefix("{\n  \"couplers\""))
        XCTAssertTrue(text.contains("Infinity"))
        let read = try XCTUnwrap(RecipeDevelop.read(text))
        XCTAssertEqual(read, develop)
        XCTAssertEqual(read.values["prep.highlights"], .number(-40))
        // The exposure above the match, not the solved total.
        XCTAssertEqual(read.values["prep.exposure_ev"], .number(0.3))
        XCTAssertTrue(read.matchBrightness)
        XCTAssertNil(read.values["prep.saturation"], "colour wasn't chosen")
        XCTAssertNil(read.values["io.raw_white_balance.temperature"], "white balance wasn't chosen")
        XCTAssertEqual(read.summary, "brightness, tone")
    }

    func testAppliedTheChosenGroupsComeFromTheRecipeTheOthersFromThePhotograph() {
        let recipe = RecipeDevelop.taking([.tone, .brightness], from: state(highlights: -40, exposure: 0.5, match: false, temperature: 4800),
                                          exposureOffset: 0)
        let photo = state(highlights: 10, exposure: 2, match: true, temperature: 6100)
        // What the engine made of the recipe over the photograph: its white balance and auto exposure.
        var next = photo
        next.params["io.raw_white_balance.temperature"] = .number(5500)
        next.params["camera.auto_exposure"] = .bool(false)
        let applied = recipe.applied(to: next, photo: photo)
        XCTAssertEqual(applied.params["prep.highlights"], .number(-40))
        XCTAssertEqual(applied.params["prep.exposure_ev"], .number(0.5))
        XCTAssertEqual(applied.params["camera.auto_exposure"], .bool(true))
        XCTAssertNil(applied.brightnessMatch, "the recipe doesn't match")
        XCTAssertEqual(applied.params["prep.saturation"], .number(-10), "the photograph's own colour")
        XCTAssertEqual(applied.params["io.raw_white_balance.temperature"], .number(6100), "the photograph's own white balance")

        // Matching, it's solved again where it lands, the recipe's exposure above it.
        let matching = RecipeDevelop.taking([.brightness], from: state(highlights: 0, exposure: 1.5, match: true, temperature: 4800), exposureOffset: 0.3)
        let landed = matching.applied(to: photo, photo: photo)
        XCTAssertEqual(landed.brightnessMatch, BrightnessMatch())
        XCTAssertEqual(landed.params["prep.exposure_ev"], .number(0.3))
        XCTAssertEqual(landed.params["prep.highlights"], .number(10))
    }

    // MARK: With the engine

    private func paths() -> EnginePaths {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return EnginePaths(helper: root.appendingPathComponent("target/release/spektrafilm-native"), exporter: root.appendingPathComponent("target/release/spektrafilm-f64"), data: root.appendingPathComponent("data"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out")
    }

    func testARecipeSavedWithDevelopAppliesItOnlyWithTheBoxTicked() async throws {
        guard FileManager.default.isExecutableFile(atPath: paths().helper.path) else { throw XCTSkip("Build the release helper first") }
        let defaults = UserDefaults.standard
        let (groups, applies) = (defaults.object(forKey: "recipeDevelopGroups"), defaults.object(forKey: "recipeAppliesDevelop"))
        defer { defaults.set(groups, forKey: "recipeDevelopGroups"); defaults.set(applies, forKey: "recipeAppliesDevelop") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PresetLibrary(folder: folder)
        let model = EditorModel(presetLibrary: library)
        defer { model.shutdown() }
        await model.start(paths: paths())
        XCTAssertTrue(model.hasCatalog, model.error ?? "Engine did not start")
        model.recipesApplyDevelop = false

        // Saved with its tone and colour.
        model.set("prep.highlights", .number(-50))
        model.set("prep.saturation", .number(25))
        model.set("prep.midtone_detail", .number(30))
        DevelopGroup.saved = [.tone, .color]
        model.newPreset(named: "Toned")
        try await waitUntil { model.presets.contains { $0.name == "Toned" } }
        let toned = try XCTUnwrap(model.presets.first { $0.name == "Toned" })
        try await waitUntil { model.presetStatus[toned] != nil }
        guard case .valid = model.presetStatus[toned] else { return XCTFail("the engine still reads it: \(String(describing: model.presetStatus[toned]))") }
        let text = try String(contentsOf: toned.url, encoding: .utf8)
        XCTAssertEqual(RecipeDevelop.read(text)?.groups, [.tone, .color])

        // One saved without.
        DevelopGroup.saved = []
        model.newPreset(named: "Plain")
        try await waitUntil { model.presets.contains { $0.name == "Plain" } }
        let plain = try XCTUnwrap(model.presets.first { $0.name == "Plain" })
        XCTAssertNil(RecipeDevelop.read(try String(contentsOf: plain.url, encoding: .utf8)))

        // Box off: the photograph keeps its own Develop settings.
        for path in ["prep.highlights", "prep.saturation", "prep.midtone_detail"] { model.set(path, .number(0)) }
        model.applyPreset(toned)
        try await waitUntil { model.status == "Applied preset “Toned”" }
        XCTAssertEqual(model.value("prep.highlights"), .number(0))

        // Box on: the recipe's tone and colour; detail wasn't saved.
        model.recipesApplyDevelop = true
        model.status = ""
        model.applyPreset(toned)
        try await waitUntil { model.status == "Applied preset “Toned”" }
        XCTAssertEqual(model.value("prep.highlights"), .number(-50))
        XCTAssertEqual(model.value("prep.saturation"), .number(25))
        XCTAssertEqual(model.value("prep.midtone_detail"), .number(0))

        // A recipe without Develop settings, box on: as before.
        model.set("prep.highlights", .number(12))
        model.status = ""
        model.applyPreset(plain)
        try await waitUntil { model.status == "Applied preset “Plain”" }
        XCTAssertEqual(model.value("prep.highlights"), .number(12))

        // The import's recipe has them too, with the box on only.
        let imported = await model.labRecipeState(toned)
        XCTAssertEqual(imported?.params["prep.highlights"], .number(-50))
        model.recipesApplyDevelop = false
        let importedOff = await model.labRecipeState(toned)
        XCTAssertEqual(importedOff?.params["prep.highlights"], .number(0))
    }
}
