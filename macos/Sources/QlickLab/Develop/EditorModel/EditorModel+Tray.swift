// Qlick Lab — GPL-3.0-only. Part of EditorModel (Develop/EditorModel.swift holds its stored state).
import Accelerate
import AppKit
import CoreVideo
import CryptoKit
import ImageIO
import IOSurface
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension EditorModel {
    // MARK: The tray (§4.5, §5.1)

    /// Opens the film or paper tray on the current stock, keeping whatever
    /// the other tray was trying.
    func openTray(paper: Bool) {
        guard previews.enabled, source != nil, !cropping, mode == .photo else { return }
        if let tray {
            if tray.paper == paper { return }
            endTray(keep: true)
        }
        // A slide is scanned: there's no paper to choose. Qlick Lab: nor a film with no film.
        if paper, state.params["io.scan_film"].bool { return }
        if !paper, state.params["io.no_film"].bool { return }
        tray = TrayVisit(paper: paper, before: state)
        if paper { previews.paperOpen = true } else { previews.filmOpen = true }
        pumpPreviews()
    }
    /// A click on a name: opens its tray, or closes it keeping the stock.
    func toggleTray(paper: Bool) {
        if tray?.paper == paper { endTray(keep: true) } else { openTray(paper: paper) }
    }

    /// Tries a stock on the photograph; the tray stays open. Tries aren't
    /// undo steps: keeping one is (`endTray`).
    func tryStock(_ id: String) {
        guard let tray, let source else { return }
        // Only the tray's own kind: a film is never printed on as a paper.
        guard stocks.contains(where: { $0.paper == tray.paper && $0.id == id }) else { return }
        let next = PreviewRules.choosing(id, paper: tray.paper, keepPaper: previews.keepPaper, in: state, stocks: stocks)
        guard next != state else { return }
        replaceState(next)
        // The tile shows exactly this edit if it was made from the request
        // it would be made from now.
        guard !previewCurrent, let stock = stocks.first(where: { $0.paper == tray.paper && $0.id == id }),
              let tile = previews.tile(id, paper: tray.paper), let image = tile.image else { return }
        let wanted = PreviewTile.Key(generation: sourceGeneration, request: PreviewRules.request(
            for: stock, keepPaper: previews.keepPaper, state: renderState, stocks: stocks, source: source, generation: sourceGeneration))
        if tile.shown == wanted { trialImage = image }
    }

    /// ← →: the previous or next stock, in the tray's order, through the
    /// favourites and on into the groups; among the matches while searching.
    func stepTray(by offset: Int) {
        guard let tray else { return }
        let sections = StockTrayRules.sections(tray.paper ? paperGroups : filmGroups,
                                               favorites: previews.favorites(in: tray.paper ? listedPapers : listedFilms, paper: tray.paper), query: tray.query)
        guard let place = StockTrayRules.step(from: tray.paper ? paper : film, inFavourites: tray.inFavourites, by: offset,
                                              in: StockTrayRules.places(sections)) else { return }
        tray.inFavourites = place.favourite
        tryStock(place.stock)
    }

    /// Return, Done or a click outside keeps the stock being tried, as one
    /// undo step from the stock before the tray opened; Esc puts that one
    /// back (§5.1). Either closes the tray. Undo while it's open keeps first
    /// (`EditorWindowController`), so it undoes the visit.
    func endTray(keep: Bool) {
        guard let tray else { return }
        self.tray = nil
        previews.filmOpen = false; previews.paperOpen = false
        let before = withPreferences(tray.before)
        if keep {
            if state != before { registerUndo(restoring: tray.before, action: tray.action) }
        } else if state != before {
            replaceState(tray.before)
        }
        pumpPreviews()
    }
    /// The state with the app's preferences that travel in it.
    func withPreferences(_ state: EditState) -> EditState {
        var state = state; state.limitPreview = limitsPreview; return state
    }
    func border<Value>(_ setting: WritableKeyPath<BorderSettings, Value>) -> Binding<Value> {
        Binding(get: { self.border[keyPath: setting] }, set: {
            var next = self.state; next.border[keyPath: setting] = $0; self.apply(next, action: "Change Border")
        })
    }
    /// A border width as a percentage of the long edge, stepped like the
    /// adjustment sliders. Back at the default it stores the default exactly,
    /// so exports match ones made before widths could change.
    func borderPercent(_ setting: WritableKeyPath<BorderSettings, Double>, range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(get: { self.border[keyPath: setting] * 100 }, set: {
            let fraction = Self.snap($0, to: range, step: step) / 100, initial = BorderSettings()[keyPath: setting]
            self.border(setting).wrappedValue = abs(fraction - initial) < 1e-9 ? initial : fraction
        })
    }
    /// The colour panel sends a stream of colours while one is dragged, so
    /// one undo step covers each run of changes to the same colour.
    func borderColor(_ setting: WritableKeyPath<BorderSettings, BorderColor>) -> Binding<CGColor> {
        Binding(get: { self.border[keyPath: setting].cgColor }, set: {
            var next = self.state; next.border[keyPath: setting] = BorderColor($0)
            guard next != self.state else { return }
            if let last = self.lastColorEdit, last.setting == setting, last.state == self.state, Date().timeIntervalSince(last.at) < 1 {
                self.replaceState(next)
            } else {
                self.apply(next, action: "Change Border Color")
            }
            self.lastColorEdit = (setting, next, Date())
        })
    }
    /// Keeps the border, crop, and Image Size's Longest side, like the film,
    /// paper, and rotation.
    func reset() {
        guard !cropping else { return }
        var next = state; next.params = defaults
        next.brightnessMatch = autoPlaceNewImages ? BrightnessMatch() : nil
        next.params["io.rotate_cw"] = state.params["io.rotate_cw"]
        next.params[ImageSize.targetPath] = state.params[ImageSize.targetPath]
        next.params["io.scan_film"] = .bool(films.first(where: { $0.id == next.film })?.positive ?? false)
        customFilmFormat = false
        apply(next, action: "Reset Adjustments")
    }
    /// Puts the controls `targets` name back to their defaults, in one undo
    /// step (the ↺ on a tab's list of edits, and Reset on the tab).
    func resetEdits(_ targets: [ResetTarget], action: String) {
        guard !cropping, !targets.isEmpty else { return }
        var next = state
        var lanes: [String: [Int]] = [:]
        var space = false
        // Exposure first: turning matching on after it sets Exposure to 0.
        if targets.contains(.exposure) { next.params["prep.exposure_ev"] = .number(matchedEV) }
        for target in targets {
            switch target {
            case .param(let path): next.params[path] = defaults[path]
            case .stock(let path, let index): lanes[path, default: []].append(index)
            case .exposure: break
            case .matchBrightness:
                if autoPlaceNewImages {
                    next.brightnessMatch = BrightnessMatch()
                    next.params["prep.exposure_ev"] = .number(0)
                } else {
                    next.brightnessMatch = nil
                }
            case .scanFilm: next.params["io.scan_film"] = .bool(films.first(where: { $0.id == next.film })?.positive ?? false)
            case .previewSpace: space = true
            case .border: next.border = BorderSettings()
            case .filmFormat:
                next.params[FilmFormatPicker.path] = defaults[FilmFormatPicker.path]
                customFilmFormat = false
            }
        }
        for (path, indices) in lanes {
            var values = stockValues(path)
            for index in indices where values.indices.contains(index) { values[index] = stockDefault(path, index) }
            let preset = stockDefaults(path)
            let atPreset = values.count == preset.count && zip(values, preset).allSatisfy { abs($0 - $1) <= 1e-6 * max(1, abs($1)) }
            next.params[path] = atPreset ? .null : .array(values.map(JSONValue.number))
        }
        apply(next, action: action)
        if space { choosePreviewSpace(SaveSettings.colorSpaces[0]) }
    }
    /// Reset on one tab: every control the tab's count stands for.
    func resetEdits(tab: InspectorTab) {
        resetEdits(InspectorEdits.edits(tab, self).map(\.target), action: "Reset \(tab.rawValue)")
    }
    /// A lane of a grain array, the film's preset while it is untouched.
    func stockValue(_ path: String, _ index: Int) -> Double {
        let values = stockValues(path)
        return values.indices.contains(index) ? values[index] : 0
    }
    func apply(_ next: EditState, action: String) {
        guard next != state else { return }
        // Any other edit keeps the stock being tried and closes the tray, so
        // the visit stays one undo step before it.
        endTray(keep: true)
        if !interacting { registerUndo(restoring: state, action: action) }
        replaceState(next)
    }
    /// A border, crop, or rotation change only redraws the canvas; anything
    /// else re-renders.
    func replaceState(_ next: EditState) {
        guard !closing else { return }
        let next = withPreferences(next)
        let render = next.rendered != state.rendered
        // The enlarged tile was of the edit before.
        if render { trialImage = nil }
        state = next
        // A crop doesn't re-render the preview, but it changes the thumbnails.
        if render { changed() } else { pumpPreviews() }
        reconcileBrightnessMatch()
        scheduleSidecarWrite()
    }
    func registerUndo(restoring previous: EditState, action: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            let previous = model.withPreferences(previous)
            guard previous != model.state else { return }
            model.registerUndo(restoring: model.state, action: action)
            model.replaceState(previous)
        }
        undoManager?.setActionName(action)
    }
    func rotate() {
        let turned = JSONValue.number(Double((Int(value("io.rotate_cw").double) + 1) % 4))
        if cropping {
            // Turns with the crop: one undo step on Done, undone by Cancel.
            var next = state; next.params["io.rotate_cw"] = turned; replaceState(next)
        } else {
            set("io.rotate_cw", turned)
            zoom(fit: true)
        }
    }
    func zoom(fit: Bool) { fitImage = fit; zoomCommand = UUID() }

    /// Double-clicking the photograph: a zoomed one fits
    /// the window, a fitted one shows the grid. Cropping has its own.
    func doubleClickPhotograph(zoomed: Bool) {
        guard mode == .photo, !cropping else { return }
        if zoomed { zoom(fit: true) } else { showGrid() }
    }
}
