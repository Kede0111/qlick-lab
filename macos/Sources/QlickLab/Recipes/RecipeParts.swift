// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Qlick Lab: the parts of a development a recipe applies (its Develop groups, chosen one by one wherever a recipe is
/// applied), the Auto White Balance and Auto Exposure of the menus, and Edit Recipe.
enum RecipeParts {
    static let autoWhiteBalanceHelp = "Each RAW photograph's own white balance, as the lab finds it. JPEG and TIFF files keep theirs."
    static let autoExposureHelp = "Each photograph's exposure matched to the camera's own rendering (Match camera brightness, Exposure at 0)."

    /// Whether any of `targets` is a RAW file, the only ones Auto White Balance changes.
    static func hasRaw(_ targets: [URL]) -> Bool {
        targets.contains { EditorModel.rawExtensions.contains($0.photoFile.pathExtension.lowercased()) }
    }

    /// Auto White Balance and Auto Exposure, for the AppKit menus (the contact sheet's, Develop's).
    @MainActor static func autoItems(_ model: EditorModel, targets: [URL], several: String, enabled: Bool) -> [NSMenuItem] {
        let balance = ClosureMenuItem("Auto White Balance" + several) { model.labAuto(whiteBalance: true, exposure: false, to: targets) }
        balance.toolTip = autoWhiteBalanceHelp
        let exposure = ClosureMenuItem("Auto Exposure" + several) { model.labAuto(whiteBalance: false, exposure: true, to: targets) }
        exposure.toolTip = autoExposureHelp
        for (entry, on) in [(balance, enabled && hasRaw(targets)), (exposure, enabled)] where !on {
            entry.action = nil
            entry.isEnabled = false
        }
        return [balance, exposure]
    }

    /// The Develop groups a recipe applies, ticked, at the foot of an AppKit Apply Recipe menu.
    @MainActor static func menuItems(_ model: EditorModel) -> [NSMenuItem] {
        var items: [NSMenuItem] = [.separator(), .sectionHeader(title: "Also Apply from Develop")]
        for group in DevelopGroup.allCases {
            let entry = ClosureMenuItem(group.label, checked: model.recipeApplyGroups.contains(group)) { model.toggleRecipeApplyGroup(group) }
            entry.toolTip = RecipeDevelop.applyHelp
            items.append(entry)
        }
        return items
    }
}

/// The Develop groups a recipe applies, ticked, at the foot of a SwiftUI Apply Recipe menu.
struct RecipePartsMenu: View {
    let model: EditorModel

    var body: some View {
        Divider()
        Section("Also Apply from Develop") {
            ForEach(DevelopGroup.allCases, id: \.self) { group in
                Toggle(group.label, isOn: Binding(get: { model.recipeApplyGroups.contains(group) }, set: { _ in model.toggleRecipeApplyGroup(group) }))
            }
        }
    }
}

/// The Develop groups a recipe applies, as pills: white when applied. With `carried` (what the recipe was saved
/// with), the groups it hasn't are faint: nothing of them to apply.
struct RecipePartChips: View {
    let model: EditorModel
    var carried: Set<DevelopGroup>? = nil

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(DevelopGroup.allCases, id: \.self) { group in
                let on = model.recipeApplyGroups.contains(group)
                let has = carried?.contains(group) ?? true
                Button { model.toggleRecipeApplyGroup(group) } label: {
                    Text(group.label.uppercased())
                        .font(Theme.caps(10.5, weight: on ? .semibold : .regular)).tracking(0.4)
                        .foregroundStyle(on ? Theme.film : Color(white: 0.78))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(on ? Theme.paper : Color.white.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.1), lineWidth: 1))
                        .opacity(has ? 1 : 0.45)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(has ? RecipeDevelop.applyHelp : "This recipe wasn't saved with its \(group.word): the photograph keeps its own")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Edit Recipe: a saved recipe changed in place. Its name; its film, paper and settings, kept or taken again from
/// the open photograph's development; and, group by group, the Develop settings it carries: the recipe's own, the
/// open photograph's, or none. Every other key of the file is kept (QLab's block, `qrecipe`…).
struct RecipeEditor: View {
    let model: EditorModel
    let preset: PresetFile
    let done: () -> Void

    enum Source: Hashable { case off, recipe, photograph }

    @State private var name: String
    @State private var takeLook = false
    @State private var sources: [DevelopGroup: Source]
    private let saved: RecipeDevelop?
    private let photo: RecipeDevelop?
    private let photoState: EditState?
    @FocusState private var naming: Bool

    init(model: EditorModel, preset: PresetFile, done: @escaping () -> Void) {
        self.model = model
        self.preset = preset
        self.done = done
        let saved = model.labPresetText(preset).flatMap(RecipeDevelop.read)
        self.saved = saved
        let state = model.source == nil ? nil : model.state
        photoState = state
        photo = state.map { RecipeDevelop.taking(Set(DevelopGroup.allCases), from: $0, exposureOffset: model.exposureOffset.wrappedValue) }
        _name = State(initialValue: preset.name)
        _sources = State(initialValue: Dictionary(uniqueKeysWithValues: DevelopGroup.allCases.map { ($0, saved?.groups.contains($0) == true ? .recipe : .off) }))
    }

    private var photoName: String { model.sourceItem.map { model.library.name(of: $0) } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "flask").font(.system(size: 15)).foregroundStyle(Theme.accent)
                Text("Edit the Recipe").font(Theme.title(17)).foregroundStyle(Theme.paper)
            }
            Text("Changes “\(preset.name)” in place: photographs developed with it keep their settings until it's applied again. Duplicate it first to keep this version.")
                .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Name").font(.system(size: 12)).foregroundStyle(Theme.dim).frame(width: 52, alignment: .leading)
                TextField("Recipe name", text: $name).textFieldStyle(.roundedBorder).focused($naming)
            }
            Divider().overlay(Theme.line)

            CapsLabel("The look", size: 9.5)
            VStack(alignment: .leading, spacing: 6) {
                if case .valid(let film, let paper, let scan) = model.presetStatus[preset] {
                    Text(look(film: film, paper: paper, scan: scan)).font(Theme.value(12)).foregroundStyle(takeLook ? Theme.dim : Color(white: 0.86))
                        .strikethrough(takeLook, color: Theme.dim)
                }
                Toggle(isOn: $takeLook) {
                    Text(photoState.map { "Take them from \(photoName): " + look(film: $0.film, paper: $0.paper, scan: $0.params["io.scan_film"].bool) }
                         ?? "Take them from the open photograph")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.86)).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox).tint(Theme.accent).disabled(photoState == nil)
                .help("The film, the paper and all their settings (grain, halation, couplers, print, scan) as the open photograph is developed")
            }

            Divider().overlay(Theme.line)
            CapsLabel("Develop settings it carries", size: 9.5)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(DevelopGroup.allCases, id: \.self) { group in row(group) }
            }
            Text("A group it carries is applied with it when ticked under “Also apply from Develop”. A group it doesn't carry stays each photograph's own.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.line)
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(QPillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(QPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || PresetName.problem(name.trimmingCharacters(in: .whitespaces)) != nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ group: DevelopGroup) -> some View {
        let source = sources[group] ?? .off
        let hasSaved = saved?.groups.contains(group) == true
        let on = Binding<Bool>(get: { source != .off }, set: { sources[group] = $0 ? (hasSaved ? .recipe : .photograph) : .off })
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: on) { Text(group.label).font(.system(size: 12)).foregroundStyle(Color(white: 0.86)) }
                .toggleStyle(.checkbox).tint(Theme.accent).frame(width: 130, alignment: .leading)
                .disabled(!hasSaved && photo == nil)
            Text(describe(group, source)).font(Theme.value(11.5)).foregroundStyle(source == .off ? Theme.faint : Theme.dim)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if source != .off, hasSaved, photo != nil {
                QSegmented(options: [(Source.recipe, "Recipe", "Keep what the recipe holds"),
                                     (.photograph, "Photograph", "Take it from \(photoName)")],
                           selection: Binding(get: { source }, set: { sources[group] = $0 }))
                    .fixedSize()
            }
        }
    }

    private func describe(_ group: DevelopGroup, _ source: Source) -> String {
        switch source {
        case .off: return saved?.groups.contains(group) == true ? "Dropped: each photograph keeps its own" : "Not carried"
        case .recipe: return saved?.describe(group) ?? ""
        case .photograph: return photo?.describe(group) ?? ""
        }
    }

    private func look(film: String, paper: String, scan: Bool) -> String {
        let filmName = model.films.first { $0.id == film }?.name ?? film
        return scan ? "\(filmName) · scanned" : "\(filmName) · \(model.papers.first { $0.id == paper }?.name ?? paper)"
    }

    /// The Develop part as chosen, row by row.
    private var develop: RecipeDevelop? {
        var groups: Set<DevelopGroup> = [], values: [String: JSONValue] = [:], match = false
        for group in DevelopGroup.allCases {
            guard let from = sources[group] == .recipe ? saved : sources[group] == .photograph ? photo : nil else { continue }
            groups.insert(group)
            for path in group.paths { if let value = from.values[path] { values[path] = value } }
            if group == .brightness { match = from.matchBrightness }
        }
        return groups.isEmpty ? nil : RecipeDevelop(groups: groups, values: values, matchBrightness: match)
    }

    private func save() {
        model.editRecipe(preset, name: name.trimmingCharacters(in: .whitespaces), develop: develop, look: takeLook ? photoState : nil)
        done()
    }
}

extension EditorModel {
    /// Qlick Lab: Edit Recipe. Writes `preset` again in place with `develop` as its Develop part and, given `look`
    /// (a development), that development's film, paper and settings; then renames it to `name`. Every other key of the
    /// file is kept. The engine reads it back before it's written: a recipe it can't read is never saved.
    func editRecipe(_ preset: PresetFile, name: String, develop: RecipeDevelop?, look: EditState?) {
        guard canChangePresets, let engine else { return }
        Task {
            do {
                let text = try Self.presetText(try await presetLibrary.read(preset))
                var exported: String?
                if let look {
                    let (_, result) = try await engine.request(["command": EngineCommand.presetExport.json, "film": .string(look.film),
                                                                "paper": .string(look.paper), "params": look.params])
                    exported = result["text"].string
                }
                guard let edited = RecipeText.editing(text, develop: develop, look: exported) else {
                    throw EngineError(message: "“\(preset.name)” can’t be read as a recipe.")
                }
                _ = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(edited)])
                let file = try await presetLibrary.replace(preset, with: Data(edited.utf8))
                if name != preset.name, !name.isEmpty { renamePreset(file, to: name) }
                await refreshPresets()
                status = "Saved the recipe “\(name.isEmpty ? preset.name : name)”"
            } catch {
                report(error)
                await refreshPresets()
            }
        }
    }
}
