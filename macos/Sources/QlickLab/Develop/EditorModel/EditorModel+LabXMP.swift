// Qlick Lab — GPL-3.0-only.
import Foundation

extension EditorModel {
    /// What an export of a photograph developed with `state` says of itself (`LabXMP`): the film and paper by their
    /// names (a film scanned has no paper), `recipe`, and the stars and words of its library `summary`.
    func labXMP(state: EditState, summary: LibrarySummary?, recipe: String?, photo: URL?, metadata: ExportMetadata) -> LabXMP {
        let scanned = state.params["io.scan_film"].bool
        return LabXMP(film: filmName(state.film), paper: scanned ? nil : paperName(state.paper), recipe: recipe,
                      rating: summary.flatMap(ExportRating.value), keywords: summary?.words.keywords ?? [],
                      title: summary?.words.title ?? "", caption: summary?.words.caption ?? "", photo: photo,
                      personal: metadata != .none)
    }

    /// The open photograph's, with the recipe applied to it last.
    func currentLabXMP(_ save: SaveSettings) -> LabXMP {
        let recipe = appliedPreset.flatMap { url in presets.first { $0.url == url }?.name }
        return labXMP(state: state, summary: currentSummary, recipe: recipe, photo: source, metadata: save.metadata)
    }
}
