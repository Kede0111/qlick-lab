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
    // MARK: Parameters

    func value(_ path: String) -> JSONValue {
        if let parameter = parameters[path] { return parameter.value }
        let parameter = ObservedParameter(state.params[path])
        parameters[path] = parameter
        return parameter.value
    }
    func publish() {
        for (path, parameter) in parameters {
            let current = state.params[path]
            if parameter.value != current { parameter.value = current }
        }
        if film != state.film { film = state.film }
        if paper != state.paper { paper = state.paper }
        if border != state.border { border = state.border }
        if crop != state.crop { crop = state.crop; updateHistogram() }
        let rotation = Int(state.params["io.rotate_cw"].double)
        if imageRotation != rotation {
            imageRotation = rotation
            updateHistogram()
            cropSession?.update(photo: shownImageSize, rotation: rotation)
        }
        updateFilmStrip()
    }
    func defaultValue(_ path: String) -> JSONValue { defaults[path] }
    func isModified(_ path: String) -> Bool {
        let (current, original) = (value(path), defaults[path])
        if case .number(let a) = current, case .number(let b) = original {
            // Rust defaults arrive as widened f32 values; slider edits are decimal.
            return abs(a - b) > 1e-6 * max(1, abs(b))
        }
        return current != original
    }
    func set(_ path: String, _ value: JSONValue) {
        var next = state; next.params[path] = value
        apply(next, action: "Change Adjustment")
    }
    func resetValue(_ path: String) { set(path, defaults[path]) }
    /// Qlick Lab: an edit of several parameters at once (`setParams`).
    func labApplyState(_ next: EditState) { apply(next, action: "Change Adjustment") }
    func number(_ path: String, range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(get: { self.value(path).double }, set: { self.set(path, .number(Self.snap($0, to: range, step: step))) })
    }
    /// The enlarger's magenta or yellow shift, moving the other as Shifts
    /// move says; both change in one step. Reset stays per slider.
    func filterShift(_ path: String, step: Double) -> Binding<Double> {
        Binding(get: { self.value(path).double }, set: { newValue in
            let snapped = Self.snap(newValue, to: FilterLink.range, step: step)
            guard self.filterLink != .separate else { return self.set(path, .number(snapped)) }
            let (m, y) = self.filterLink.shifts(moving: path, to: snapped,
                                                magenta: self.value(FilterLink.magenta).double, yellow: self.value(FilterLink.yellow).double)
            var next = self.state
            next.params[FilterLink.magenta] = .number(m)
            next.params[FilterLink.yellow] = .number(y)
            self.apply(next, action: "Change Adjustment")
        })
    }
    /// Resets a shift; linked (Together, Opposite ways), both reset, as
    /// they move, in one step.
    func resetFilterShift(_ path: String) {
        guard filterLink != .separate else { return resetValue(path) }
        var next = state
        for shift in [FilterLink.magenta, FilterLink.yellow] { next.params[shift] = defaults[shift] }
        apply(next, action: "Change Adjustment")
    }
    /// A double-click on a shift's track. Its first click moved the shift to
    /// the pointer, and a linked one with it: that click is undone first,
    /// exactly, so the reset is one step from before it.
    func resetFilterShiftAfterClick(_ path: String) {
        if let last = lastInteraction, last.end == state, undoManager?.canUndo == true {
            undoManager?.undo()
        }
        lastInteraction = nil
        resetFilterShift(path)
    }
    /// Grain arrays (`film_render.grain.<field>`) are null until edited: the
    /// engine then uses the film's preset, which the catalog resolves.
    var filmIsBW: Bool { films.first { $0.id == film }?.bw ?? false }
    func stockDefaults(_ path: String) -> [Double] {
        let field = path.split(separator: ".").last.map(String.init) ?? path
        return films.first { $0.id == film }?.grain[field].array.map(\.double) ?? []
    }
    func stockDefault(_ path: String, _ index: Int) -> Double {
        let preset = stockDefaults(path)
        return preset.indices.contains(index) ? preset[index] : 0
    }
    func stockValues(_ path: String) -> [Double] {
        let saved = value(path).array.map(\.double)
        return saved.isEmpty ? stockDefaults(path) : saved
    }
    func stockNumber(_ path: String, _ index: Int, range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(get: {
            let values = self.stockValues(path)
            return values.indices.contains(index) ? values[index] : 0
        }, set: { self.setStock(path, index, Self.snap($0, to: range, step: step)) })
    }
    func isStockModified(_ path: String, _ index: Int) -> Bool {
        let values = stockValues(path)
        guard values.indices.contains(index) else { return false }
        let preset = stockDefault(path, index)
        return abs(values[index] - preset) > 1e-6 * max(1, abs(preset))
    }
    func resetStock(_ path: String, _ index: Int) { setStock(path, index, stockDefault(path, index)) }
    /// Back at the preset in every lane, the array returns to null so a
    /// later film change applies that film's preset.
    func setStock(_ path: String, _ index: Int, _ newValue: Double) {
        var values = stockValues(path)
        guard values.indices.contains(index) else { return }
        values[index] = newValue
        let preset = stockDefaults(path)
        let atPreset = values.count == preset.count
            && zip(values, preset).allSatisfy { abs($0 - $1) <= 1e-6 * max(1, abs($1)) }
        set(path, atPreset ? .null : .array(values.map(JSONValue.number)))
    }
    /// The input colour pop-up: "auto", "manual", or "assume:" and the
    /// colour space (`io.input_interpretation`).
    var inputInterpretation: Binding<String> {
        Binding(get: {
            let mode = self.value("io.input_interpretation.mode").string
            return mode == "assume" ? "assume:" + self.value("io.input_interpretation.color_space").string : mode.isEmpty ? "auto" : mode
        }, set: { tag in
            var next = self.state
            if tag.hasPrefix("assume:") {
                next.params["io.input_interpretation.mode"] = .string("assume")
                next.params["io.input_interpretation.color_space"] = .string(String(tag.dropFirst("assume:".count)))
            } else {
                next.params["io.input_interpretation.mode"] = .string(tag)
            }
            self.apply(next, action: "Change Input Colour")
        })
    }
    func toggle(_ path: String) -> Binding<Bool> {
        Binding(get: { self.value(path).bool }, set: { self.set(path, .bool($0)) })
    }
    func choice(_ path: String) -> Binding<String> {
        Binding(get: { self.value(path).string }, set: { self.set(path, .string($0)) })
    }

    /// Sliders are continuous to avoid AppKit tick marks; the engine expects
    /// the stepped value (integer fields reject fractions).
    nonisolated static func snap(_ value: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let decimals = max(0, Int(-log10(step).rounded(.down)) + 1)
        let scale = pow(10, Double(decimals))
        return min(((range.lowerBound + steps * step) * scale).rounded() / scale, range.upperBound)
    }

    func beginInteraction() {
        if interactionStart == nil { interactionStart = state }
        hideActivity()
    }
    func endInteraction(action: String = "Change Adjustment") {
        guard let start = interactionStart else { return }
        interactionStart = nil
        lastInteraction = start != state ? (start, state) : nil
        if start != state { registerUndo(restoring: start, action: action) }
        // The drag frames were canvas-size already: letting go settles.
        quickStep = FrameID(revision: revision, generation: sourceGeneration)
        if showingInteractiveFrame, ready, source != nil, !closing { scheduleRender() }
        if !previewCurrent { scheduleActivity() }
        pumpPreviews()
    }

    func chooseFilm(_ stock: String) {
        apply(PreviewRules.choosing(stock, paper: false, keepPaper: previews.keepPaper, in: state, stocks: stocks), action: "Change Film")
    }
    func choosePaper(_ stock: String) {
        apply(PreviewRules.choosing(stock, paper: true, keepPaper: previews.keepPaper, in: state, stocks: stocks), action: "Change Paper")
    }
}
