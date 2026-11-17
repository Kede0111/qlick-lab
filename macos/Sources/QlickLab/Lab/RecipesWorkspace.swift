// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The recipes: NEgs's presets (spektrafilm's own format, so they open in NEgs and in spektrafilm), shown as
/// developments of the open photograph, to apply to it or to every selected frame, to duplicate into a new version,
/// to compare, to import and export.
struct RecipesWorkspace: View {
    let model: EditorModel
    @State private var selected: URL?
    @State private var favouritesOnly = false
    @State private var renaming: URL?
    @State private var name = ""

    private var lab: LabState { model.lab }

    var body: some View {
        let presets = model.presets.filter { !favouritesOnly || lab.favouriteRecipes.contains($0.name) }
        let current = selected.flatMap { url in model.presets.first { $0.url == url } } ?? model.appliedPreset.flatMap { url in model.presets.first { $0.url == url } } ?? presets.first
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                QSegmented(options: [(false, "All", "All recipes"), (true, "Favourites", "Recipes marked with a star")], selection: $favouritesOnly)
                Spacer()
                if let item = model.sourceItem {
                    Text("Previews developed on \(model.library.name(of: item))").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                }
                Button { model.importPresetsPanel() } label: { Label("Import…", systemImage: "square.and.arrow.down") }.buttonStyle(QPillButtonStyle())
                    .help("Recipes from Qlick Lab or spektrafilm (its interface's state files)")
                Button { model.newPreset() } label: { Label("Save the Development", systemImage: "plus") }
                    .buttonStyle(QPrimaryButtonStyle()).disabled(model.source == nil || !model.canChangePresets)
                    .help("Saves the open photograph's film, paper and settings as a new recipe")
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

            if model.presets.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "flask").font(.system(size: 36, weight: .light)).foregroundStyle(Q.faint)
                    Text("No recipes yet").font(Q.title(18)).foregroundStyle(Q.text)
                    Text("A recipe keeps a film, a paper and their settings, to use them on other photographs.\nDevelop a picture and save it as a recipe, or import spektrafilm's.")
                        .font(.system(size: 12.5)).foregroundStyle(Q.dim).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                            ForEach(presets) { preset in
                                RecipeCard(model: model, preset: preset, selected: current?.url == preset.url, applied: model.appliedPreset == preset.url,
                                           renaming: renaming == preset.url, name: $name) {
                                    selected = preset.url
                                } rename: {
                                    model.renamePreset(preset, to: name); renaming = nil
                                }
                                .contextMenu { menu(preset) }
                            }
                        }
                        .padding(20)
                    }
                    if let current {
                        RecipeDetail(model: model, preset: current) { name = current.name; renaming = current.url }
                            .frame(width: 330)
                            .background(Color(white: 0.06))
                            .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                    }
                }
            }
        }
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        .task { await model.refreshPresets() }
    }

    @ViewBuilder private func menu(_ preset: PresetFile) -> some View {
        Button("Apply to the Open Photograph") { model.labApply(preset, to: model.sourceItem.map { [$0] } ?? []) }.disabled(model.source == nil)
        Button("Rename") { name = preset.name; renaming = preset.url }
        Button("Duplicate as a New Version") { model.labDuplicate(preset) }
        Button(lab.favouriteRecipes.contains(preset.name) ? "Remove from Favourites" : "Add to Favourites") { lab.toggleFavouriteRecipe(preset.name) }
        Divider()
        Button("Export…") { model.exportPresetPanel(preset) }
        Button("Show the Recipes Folder") { model.showPresetsFolder() }
        Divider()
        Button("Delete…") { model.deletePreset(preset) }
    }
}

private struct RecipeCard: View {
    let model: EditorModel
    let preset: PresetFile
    let selected: Bool
    let applied: Bool
    let renaming: Bool
    @Binding var name: String
    let select: () -> Void
    let rename: () -> Void
    @State private var image: CGImage?
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let lab = model.lab
        let favourite = lab.favouriteRecipes.contains(preset.name)
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color(white: 0.09)
                if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "flask").font(.system(size: 22, weight: .light)).foregroundStyle(Q.faint) }
            }
            .aspectRatio(1.5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(selected ? Q.text : Color.white.opacity(hovered ? 0.3 : 0.08), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                Button { lab.toggleFavouriteRecipe(preset.name) } label: {
                    Image(systemName: favourite ? "star.fill" : "star").font(.system(size: 11.5)).foregroundStyle(favourite ? Q.text : Color.white.opacity(0.7))
                        .frame(width: 26, height: 26).contentShape(Rectangle()).shadow(color: .black.opacity(0.7), radius: 2)
                }
                .buttonStyle(.plain).opacity(favourite || hovered ? 1 : 0)
            }
            if renaming {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12.5)).focused($focused)
                    .onSubmit(rename).onAppear { focused = true }
            } else {
                HStack(spacing: 6) {
                    if applied { Circle().fill(Q.red).frame(width: 5, height: 5).help("Applied to the open photograph") }
                    Text(preset.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Q.text).lineLimit(1)
                }
            }
            Text(RecipeFacts.line(model, preset)).font(.system(size: 11)).foregroundStyle(Q.dim).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .task(id: "\(model.sourceItem?.absoluteString ?? "")|\(preset.modified.timeIntervalSince1970)") {
            image = nil
            guard let item = model.sourceItem, model.labPresetText(preset) != nil else { return }
            image = await model.lab.compareModel.developer.image(.init(item: item, recipe: preset.url, longSide: 480))
        }
    }
}

enum RecipeFacts {
    @MainActor static func line(_ model: EditorModel, _ preset: PresetFile) -> String {
        switch model.presetStatus[preset] {
        case .valid(let film, let paper, let scan):
            let filmName = model.films.first { $0.id == film }?.name ?? film
            return scan ? "\(filmName) · scanned" : "\(filmName) · \(model.papers.first { $0.id == paper }?.name ?? paper)"
        case .invalid(let reason): return reason
        default: return " "
        }
    }
}

private struct RecipeDetail: View {
    let model: EditorModel
    let preset: PresetFile
    let rename: () -> Void
    @State private var image: CGImage?

    var body: some View {
        let lab = model.lab
        let targets = model.mode == .grid ? model.selection.ordered(model.shownPhotos.map(\.url)) : (model.sourceItem.map { [$0] } ?? [])
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name).font(Q.title(18)).foregroundStyle(Q.text).fixedSize(horizontal: false, vertical: true)
                    Text("Changed \(preset.modified.formatted(.dateTime.day().month(.wide).year()))").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                }
                if case .valid(let film, let paper, let scan) = model.presetStatus[preset] {
                    VStack(alignment: .leading, spacing: 7) {
                        fact("Film", model.films.first { $0.id == film }?.name ?? film)
                        fact("Print", scan ? "Film scanned directly" : (model.papers.first { $0.id == paper }?.name ?? paper))
                        fact("Carries", "Film, paper, grain, halation, couplers, print, scan")
                        fact("Kept", "Each photograph's white balance, crop, lens corrections and size")
                    }
                } else if case .invalid(let reason) = model.presetStatus[preset] {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    Button(targets.count > 1 ? "Apply to the \(targets.count) Selected Frames" : "Apply to the Photograph") {
                        model.labApply(preset, to: targets)
                    }
                    .buttonStyle(QPrimaryButtonStyle()).disabled(targets.isEmpty || !model.canChangePresets)
                    .help("One undo puts every photograph back as it was")
                    Button("With Auto White Balance and Exposure") { model.labApply(preset, to: targets, adapting: true) }
                        .buttonStyle(QPillButtonStyle()).disabled(targets.isEmpty || !model.canChangePresets)
                        .help("The recipe's look, with each photograph's own white balance and exposure, for photographs taken in different light")
                    Button("Compare with Other Recipes") {
                        var recipes = [preset.url]
                        for other in model.presets where recipes.count < 3 && other.url != preset.url { recipes.append(other.url) }
                        lab.compare.recipes = recipes
                        lab.show(.compare); lab.compareModel.setKind(.recipes)
                    }
                    .buttonStyle(QPillButtonStyle()).disabled(model.source == nil || model.presets.count < 2)
                    HStack(spacing: 8) {
                        Button("Rename", action: rename).buttonStyle(QPillButtonStyle())
                        Button("Duplicate") { model.labDuplicate(preset) }.buttonStyle(QPillButtonStyle()).help("A new version of the recipe, to change without losing this one")
                        Button("Export…") { model.exportPresetPanel(preset) }.buttonStyle(QPillButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("spektrafilm format: the recipe opens in spektrafilm too. To change it, apply it, adjust the development, then save that as a new recipe.")
                    .font(.system(size: 10.5)).foregroundStyle(Q.faint).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .task(id: "\(preset.url.path)|\(model.sourceItem?.absoluteString ?? "")") {
            image = nil
            guard let item = model.sourceItem, model.labPresetText(preset) != nil else { return }
            image = await model.lab.compareModel.developer.image(.init(item: item, recipe: preset.url, longSide: 900))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CapsLabel(label, size: 9.5).frame(width: 80, alignment: .leading)
            Text(value).font(Q.value(12)).foregroundStyle(Color(white: 0.86)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
