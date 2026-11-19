// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

// The user's own presets of one section of Develop: Grain and Halation. Each holds that section's settings under a
// name; picking one changes those settings alone, on the open photograph or on every one selected. The lab ships none.

/// A section of Develop that keeps presets of its own.
enum PresetSection: String, CaseIterable, Codable, Sendable {
    case grain, halation

    var title: String { self == .grain ? "Grain" : "Halation" }

    /// The settings a preset of the section holds, as parameter paths.
    var paths: [String] {
        switch self {
        case .grain:
            ["active", "rms_granularity", "uniformity", "particle_scale_sublayers", "density_min", "blur", "blur_dye_clouds_um",
             "mult_usm_amount", "mult_usm_sigma", "micro_structure", "luminance_only"].map { "film_render.grain.\($0)" }
        case .halation:
            ["active", "halation_amount", "halation_spatial_scale", "halation_strength", "halation_first_sigma_um", "halation_n_bounces",
             "halation_bounce_decay", "halation_renormalize", "highlights_only", "threshold_ev", "softness_ev", "gain_ev", "scatter_amount", "scatter_spatial_scale", "scatter_core_um",
             "scatter_tail_um", "scatter_tail_weight"].map { "film_render.halation.\($0)" }
        }
    }
}

/// One preset: a name, and the section's settings.
struct SectionPreset: Codable, Equatable, Sendable {
    var name: String
    var values: [String: JSONValue]

    /// The settings to set, in the section's order.
    func settings(_ section: PresetSection) -> [(String, JSONValue)] {
        section.paths.compactMap { path in values[path].map { (path, $0) } }
    }

    /// Whether `params` hold exactly these settings (numbers to a millionth).
    func matches(_ params: JSONValue, _ section: PresetSection) -> Bool {
        section.paths.allSatisfy { path in values[path].map { SectionPreset.same($0, params[path]) } ?? true }
    }

    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): abs(x - y) <= 1e-6 * max(1, abs(x))
        case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy(same)
        default: a == b
        }
    }
}

/// The presets of every section, kept in the app's support folder (`section-presets.json`).
@MainActor @Observable final class SectionPresets {
    static let shared = SectionPresets(file: AppDataLocations.supportDirectory.appendingPathComponent("section-presets.json"))

    private(set) var presets: [PresetSection: [SectionPreset]] = [:]
    @ObservationIgnored private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [SectionPreset]].self, from: data) {
            for (key, list) in saved { if let section = PresetSection(rawValue: key) { presets[section] = list } }
        }
    }

    func list(_ section: PresetSection) -> [SectionPreset] { presets[section] ?? [] }

    /// Saves `values` as `name`, replacing a preset of that name.
    func save(_ name: String, values: [String: JSONValue], in section: PresetSection) {
        var list = self.list(section)
        let preset = SectionPreset(name: name, values: values)
        if let index = list.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) { list[index] = preset } else { list.append(preset) }
        presets[section] = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        write()
    }

    func rename(_ name: String, to new: String, in section: PresetSection) {
        guard name != new, var preset = list(section).first(where: { $0.name == name }) else { return }
        var list = self.list(section).filter { $0.name != name && $0.name.lowercased() != new.lowercased() }
        preset.name = new
        list.append(preset)
        presets[section] = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        write()
    }

    func delete(_ name: String, in section: PresetSection) {
        presets[section] = list(section).filter { $0.name != name }
        write()
    }

    private func write() {
        let saved = Dictionary(uniqueKeysWithValues: presets.map { ($0.key.rawValue, $0.value) })
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("section presets: \(error.localizedDescription)\n".utf8))
        }
    }
}

extension EditorModel {
    /// The open photograph's settings of `section`, as a preset holds them.
    func sectionValues(_ section: PresetSection) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: section.paths.map { ($0, state.params[$0]) })
    }

    /// Asks for a name and saves the section's settings under it.
    func saveSectionPreset(_ section: PresetSection) {
        let values = sectionValues(section)
        let taken = Set(SectionPresets.shared.list(section).map { $0.name.lowercased() })
        var suggested = "\(section.title) 1"
        for n in 1... where !taken.contains("\(section.title) \(n)".lowercased()) { suggested = "\(section.title) \(n)"; break }
        askSectionName(title: "Save \(section.title) Preset", suggested: suggested) { name in
            guard let name else { return }
            SectionPresets.shared.save(name, values: values, in: section)
        }
    }

    func renameSectionPreset(_ name: String, _ section: PresetSection) {
        askSectionName(title: "Rename “\(name)”", suggested: name) { new in
            guard let new else { return }
            SectionPresets.shared.rename(name, to: new, in: section)
        }
    }

    func deleteSectionPreset(_ name: String, _ section: PresetSection) {
        Task {
            let answer = await ask(AppAlert(title: "Delete the \(section.title.lowercased()) preset “\(name)”?",
                                            buttons: [.init(title: "Delete", role: .destructive), .init(title: "Cancel", role: .cancel)]))
            guard answer.button == 0 else { return }
            SectionPresets.shared.delete(name, in: section)
        }
    }

    /// A name over the window, the suggestion selected; nil if cancelled or empty.
    private func askSectionName(title: String, suggested: String, _ done: @escaping (String?) -> Void) {
        guard NSClassFromString("XCTestCase") == nil else { return done(suggested) }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.window.appearance = NSAppearance(named: .darkAqua)
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            done(response == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
        if let window = NSApp.windows.first(where: { $0 is EditorWindow }) {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }
}

/// The section's preset list in Develop: the one in use, the others a click away, and saving, renaming and
/// deleting. Picking one applies it to the photographs selected.
struct SectionPresetRow: View {
    let model: EditorModel
    let section: PresetSection
    private var store: SectionPresets { .shared }

    var body: some View {
        let list = store.list(section)
        let current = list.first { $0.matches(model.state.params, section) }
        let edited = section.paths.contains(where: model.isModified)
        let count = model.editTargets.count
        var items: [ChoiceItem] = list.map { .option($0.name, tag: "p:" + $0.name) }
        if count > 1, !list.isEmpty { items.insert(.header("Applies to \(count) photographs"), at: 0) }
        if !list.isEmpty { items.append(.divider) }
        items.append(.option("Save Current Settings…", tag: "save"))
        if let current {
            items.append(.option("Rename “\(current.name)”…", tag: "rename"))
            items.append(.option("Delete “\(current.name)”", tag: "delete"))
        }
        // No preset in use: the row says what the settings are instead (ChoiceRow shows the selection itself).
        let selection = current.map { "p:" + $0.name } ?? (edited ? "Custom" : "As the film")
        return ChoiceRow(title: "Preset", items: items, selection: selection, changed: current != nil,
                         help: "Your own \(section.title.lowercased()) settings, saved by name. Picking one changes only the \(section.title.lowercased()), on every photograph selected.") { tag in
            switch tag {
            case "save": model.saveSectionPreset(section)
            case "rename": if let current { model.renameSectionPreset(current.name, section) }
            case "delete": if let current { model.deleteSectionPreset(current.name, section) }
            default:
                guard tag.hasPrefix("p:"), let preset = list.first(where: { $0.name == String(tag.dropFirst(2)) }) else { return }
                model.labApplySection(preset, section, to: model.editTargets)
            }
        }
    }
}
