import XCTest
@testable import QlickLab

/// Qlick Lab: the user's own Grain and Halation presets, colourless grain, Show mask and no film.
@MainActor final class SectionPresetTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-section-\(UUID().uuidString).json")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: file) }

    func testPresetsAreSavedRenamedAndDeletedAndReadBack() {
        let store = SectionPresets(file: file)
        XCTAssertEqual(store.list(.grain), [], "the lab ships none")
        store.save("Fine", values: ["film_render.grain.blur": .number(0.5)], in: .grain)
        store.save("Coarse", values: ["film_render.grain.blur": .number(1.5)], in: .grain)
        store.save("Glow", values: ["film_render.halation.halation_amount": .number(2)], in: .halation)
        // The same name again replaces it.
        store.save("fine", values: ["film_render.grain.blur": .number(0.6)], in: .grain)
        XCTAssertEqual(store.list(.grain).map(\.name), ["Coarse", "fine"])
        store.rename("Coarse", to: "Rough", in: .grain)
        store.delete("Glow", in: .halation)

        let reopened = SectionPresets(file: file)
        XCTAssertEqual(reopened.list(.grain).map(\.name), ["fine", "Rough"])
        XCTAssertEqual(reopened.list(.grain).first?.values["film_render.grain.blur"], .number(0.6))
        XCTAssertEqual(reopened.list(.halation), [])
    }

    func testAPresetMatchesTheSettingsItHoldsAndSetsOnlyItsSection() {
        var params = JSONValue.object([:])
        params["film_render.grain.blur"] = .number(0.89)
        params["film_render.grain.rms_granularity"] = .array([.number(10), .number(12), .number(14)])
        params["film_render.halation.halation_amount"] = .number(1)
        let preset = SectionPreset(name: "Mine", values: [
            "film_render.grain.blur": .number(0.8900000001),
            "film_render.grain.rms_granularity": .array([.number(10), .number(12), .number(14)]),
        ])
        XCTAssertTrue(preset.matches(params, .grain))
        params["film_render.grain.rms_granularity.1"] = .number(13)
        XCTAssertFalse(preset.matches(params, .grain))
        XCTAssertEqual(preset.settings(.grain).map(\.0), ["film_render.grain.rms_granularity", "film_render.grain.blur"])
        XCTAssertTrue(PresetSection.grain.paths.allSatisfy { $0.hasPrefix("film_render.grain.") })
        XCTAssertTrue(PresetSection.halation.paths.allSatisfy { $0.hasPrefix("film_render.halation.") })
        XCTAssertFalse(PresetSection.halation.paths.contains("film_render.halation.show_mask"), "the mask is never saved")
    }

    func testNoFilmGoesWithTheFilmAndChoosingAFilmEndsIt() {
        XCTAssertEqual(EditGroup.of(section: "io", key: "no_film"), .filmAndPaper)
        var state = EditState()
        state.params["io.no_film"] = .bool(true)
        let chosen = PreviewRules.choosing("kodak_portra_400", paper: false, keepPaper: true, in: state, stocks: [])
        XCTAssertEqual(chosen.params["io.no_film"], .bool(false))
        let paper = PreviewRules.choosing("kodak_portra_endura", paper: true, keepPaper: true, in: state, stocks: [])
        XCTAssertEqual(paper.params["io.no_film"], .bool(true))
    }

    private func paths() -> EnginePaths {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return EnginePaths(helper: root.appendingPathComponent("target/release/spektrafilm-native"), exporter: root.appendingPathComponent("target/release/spektrafilm-f64"), data: root.appendingPathComponent("data"))
    }

    func testTheEngineKnowsTheNewSettingsAndNeverListsTheMask() async throws {
        guard FileManager.default.isExecutableFile(atPath: paths().helper.path) else { throw XCTSkip("Build the release helper first") }
        let model = EditorModel()
        defer { model.shutdown() }
        await model.start(paths: paths())
        XCTAssertTrue(model.hasCatalog, model.error ?? "Engine did not start")
        XCTAssertEqual(model.defaultValue("io.no_film"), .bool(false))
        XCTAssertEqual(model.defaultValue(GrainSimpleRows.monochrome), .bool(false))
        XCTAssertEqual(model.defaultValue("film_render.halation.show_mask"), .null)
        // Colourless grain and no film are edits, counted on the Lab tab.
        model.set(GrainSimpleRows.monochrome, .bool(true))
        model.set(EditorModel.noFilmPath, .bool(true))
        let titles = InspectorEdits.edits(.lab, model).map(\.title)
        XCTAssertTrue(titles.contains("No film") && titles.contains("Grain · Monochrome"), "\(titles)")
        XCTAssertEqual(InspectorEdits.count(.film, model), InspectorEdits.edits(.lab, model).filter { ["No film", "Grain · Monochrome", "Film development"].contains($0.title) }.count)
        // Show mask is the app's, not the edit's.
        let before = model.state
        model.halationMask = true
        XCTAssertEqual(model.state, before)
        XCTAssertFalse(model.showsHalationMask, "a scanned negative printed with no film has no halation of its own")
        model.set(EditorModel.noFilmPath, .bool(false))
        XCTAssertTrue(model.showsHalationMask)
        XCTAssertFalse(model.canSave)
        model.set("film_render.halation.active", .bool(false))
        XCTAssertFalse(model.showsHalationMask, "no halation, no mask")
    }
}
