// Qlick Lab — GPL-3.0-only.

/// The commands the engine's helper understands: `enum Command` in crates/spektrafilm-native/src/main.rs, which
/// reads `{"id": …, "command": "<name>", …fields}`. `crates/spektrafilm-native/commands.txt` lists them, and a test
/// on each side (`EngineContractTests`, `commands_match_the_shared_list`) checks its own list against that file, so a
/// command renamed or added on one side only fails the tests instead of failing at run time.
enum EngineCommand: String, CaseIterable, Sendable {
    case balancePrint = "balance_print"
    case catalog
    case exportLut = "export_lut"
    case presetImport = "preset_import"
    case presetExport = "preset_export"
    case level
    case previewColourSpace = "preview_colour_space"
    case prepareBalance = "prepare_balance"
    case makeProxy = "make_proxy"
    case pickBalance = "pick_balance"
    case placeExposure = "place_exposure"
    case render
    case thumbnail
    case releaseThumbnails = "release_thumbnails"
    case releaseFilmCache = "release_film_cache"
    case toneCurve = "tone_curve"
    case save

    /// The value of a request's `command` key.
    var json: JSONValue { .string(rawValue) }
}
