// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Where the photographs go and how: the import's choices, each in its own section, with the folders they'll make
/// shown before anything is written.
struct ImportPanel: View {
    let model: EditorModel
    @State private var profileName = ""
    @State private var naming = false

    var body: some View {
        @Bindable var session = model.lab.importer
        let options = session.options
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection("Profile") {
                    HStack(spacing: 6) {
                        Menu {
                            if session.profiles.isEmpty { Text("No profile yet") }
                            ForEach(session.profiles.keys.sorted(), id: \.self) { name in
                                Button(name) { session.apply(profile: name) }
                            }
                            if !session.profiles.isEmpty {
                                Divider()
                                Menu("Delete") {
                                    ForEach(session.profiles.keys.sorted(), id: \.self) { name in Button(name) { session.deleteProfile(name) } }
                                }
                            }
                        } label: { Label(currentProfile(session) ?? "Choose…", systemImage: "chevron.down").font(Theme.caps(12)).labelStyle(.titleAndIcon) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        Spacer()
                        Button("Save…") { profileName = currentProfile(session) ?? ""; naming = true }.buttonStyle(QPillButtonStyle())
                            .help("Keeps these choices under a name, to use them again in one click")
                    }
                    if naming {
                        HStack(spacing: 6) {
                            PanelField("Profile name", text: $profileName)
                            Button("Save") { session.saveProfile(named: profileName); naming = false }.buttonStyle(QPillButtonStyle())
                                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                PanelSection("Destination") {
                    QSegmented(options: ImportMode.allCases.map { ($0, $0.title, $0.help) }, selection: $session.options.mode)
                    if options.mode == .move, session.source?.kind == .card {
                        PanelHint("Move isn’t offered for memory cards. Copy, check, then format the card in the camera.", warn: true)
                    }
                    if options.mode != .add {
                        FolderRow(title: "To", url: options.destination, placeholder: "Choose a folder…") { session.options.destination = $0 }
                        if let free = session.freeSpace {
                            let need = session.bytesNeeded
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free · this import needs \(ByteCountFormatter.string(fromByteCount: Int64(need), countStyle: .file))")
                                .font(Theme.value(10.5)).foregroundStyle(free < need ? Theme.warn : Theme.dim)
                        }
                        PanelToggle("Second copy", isOn: Binding(get: { options.secondCopy != nil }, set: { on in
                            if on { chooseFolder("Second Copy") { session.options.secondCopy = $0 } } else { session.options.secondCopy = nil }
                        }), help: "A second, untouched copy of every file, under the camera’s own names, on another disk")
                        if let second = options.secondCopy {
                            FolderRow(title: "Also to", url: second, placeholder: "") { session.options.secondCopy = $0 }
                        }
                    } else {
                        PanelHint("Nothing is copied or moved: each folder becomes a roll where it lies.")
                    }
                }

                if options.mode != .add {
                    PanelSection("Folders") {
                        TemplateRow(presets: ImportTemplate.folderPresets, template: $session.options.folders, folders: true, placeholder: "One folder")
                        if options.folders.contains("{job}") || options.rename.contains("{job}") {
                            PanelField("Job name", text: $session.options.job)
                        }
                        HStack(spacing: 8) {
                            Stepper(value: Binding(get: { options.clockOffset / 60 }, set: { session.options.clockOffset = $0 * 60 }), in: -23...23) {
                                Text(options.clockOffset == 0 ? "Camera clock as it is" : "Camera clock \(options.clockOffset > 0 ? "+" : "−")\(abs(options.clockOffset) / 60) h")
                                    .font(.system(size: 11.5)).foregroundStyle(options.clockOffset == 0 ? Theme.dim : Theme.paper)
                            }
                            .controlSize(.small)
                            .help("Shifts every capture time before filing: a camera left on another time zone")
                        }
                        Stepper(value: $session.options.dayStart, in: 0...8) {
                            Text(options.dayStart == 0 ? "A day starts at midnight" : "A day starts at 0\(options.dayStart):00")
                                .font(.system(size: 11.5)).foregroundStyle(options.dayStart == 0 ? Theme.dim : Theme.paper)
                        }
                        .controlSize(.small)
                        .help("Frames taken before this hour are filed with the evening before, so a night stays in one folder")
                        PlanTree(session: session)
                    }

                    PanelSection("File Names") {
                        TemplateRow(presets: ImportTemplate.renamePresets, template: $session.options.rename, folders: false, placeholder: "Camera names")
                        if !options.rename.isEmpty, let first = session.plan.toCopy.first?.files.first {
                            Text("\(first.source.name) → \(first.destination.lastPathComponent)").font(Theme.value(10.5)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }

                PanelSection("Recipe") { RecipeChooser(model: model) }

                PanelSection("Project") {
                    HStack(spacing: 6) {
                        PanelField("No project", text: $session.options.project)
                        Menu {
                            Button("No Project") { session.options.project = "" }
                            Divider()
                            ForEach(model.lab.projects.ordinary) { project in Button(project.name) { session.options.project = project.name } }
                        } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    PanelHint(options.project.trimmingCharacters(in: .whitespaces).isEmpty
                              ? "Name a project and each folder of the import becomes one of its rolls."
                              : "Each folder of the import becomes a roll of “\(options.project)”.")
                }

                PanelSection("Words") {
                    PanelField("Keywords, separated by commas", text: $session.options.keywords)
                    PanelField("Author", text: $session.options.creator)
                    PanelField("Copyright", text: $session.options.copyright)
                    PanelField("Caption", text: $session.options.caption)
                    if !ImportMetadata(options: options).isEmpty {
                        PanelHint("Written in a standard .xmp file beside each photograph, where other programs read them.")
                    }
                }

                PanelSection("Safety") {
                    if options.mode != .add {
                        PanelToggle("Check every copy", isOn: $session.options.verify, help: "Reads each copy back from the disk and compares it with its original (SHA-256). Slower, and the only way to know.")
                    }
                    PanelToggle("Leave out what’s already imported", isOn: $session.options.skipDuplicates, help: "Photographs this catalog imported before, known by name, size and capture time")
                    PanelToggle("Leave out the frames crossed out", isOn: $session.options.skipRejected, help: "A cross here means the frame isn’t imported")
                    if session.frames.contains(where: { $0.companion != nil }) {
                        HStack {
                            Text("RAW + JPEG").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.8))
                            Spacer()
                            Picker("", selection: $session.options.pairs) { ForEach(ImportPairs.allCases, id: \.self) { Text($0.title).tag($0) } }
                                .labelsHidden().controlSize(.small).fixedSize()
                        }
                    }
                    if session.source?.volume != nil, options.mode != .add {
                        PanelToggle("Eject when it’s done", isOn: $session.options.ejectAfter, help: "Ejects the card once every photograph is copied and checked")
                    }
                    HStack {
                        Text("While importing").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.8))
                        Spacer()
                        Picker("", selection: $session.progressStyle) { ForEach(ImportProgressStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
                            .labelsHidden().controlSize(.small).fixedSize()
                            .help("Film Lab shows the roll developing; Compact is a plain list. Automatic chooses Compact above \(ImportProgressStyle.compactAbove) photographs.")
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    private func currentProfile(_ session: ImportSession) -> String? {
        session.profiles.first { $0.value == session.options }?.key
    }
}

/// Asks for a folder.
@MainActor func chooseFolder(_ title: String, then: @escaping @MainActor (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = "Choose"
    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        MainActor.assumeIsolated { then(url) }
    }
}

// MARK: Pieces

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(title)
            content
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

struct PanelField: View {
    let prompt: String
    @Binding var text: String
    init(_ prompt: String, text: Binding<String>) { self.prompt = prompt; _text = text }
    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faint))
            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.paper)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool
    var help: String
    init(_ title: String, isOn: Binding<Bool>, help: String) { self.title = title; _isOn = isOn; self.help = help }
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.8)) }
            .toggleStyle(.checkbox).tint(Theme.accent).help(help)
    }
}

struct PanelHint: View {
    let text: String
    var warn = false
    init(_ text: String, warn: Bool = false) { self.text = text; self.warn = warn }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warn ? Theme.warn : Theme.dim).fixedSize(horizontal: false, vertical: true)
    }
}

/// A folder, with the button that changes it.
private struct FolderRow: View {
    let title: String
    let url: URL?
    let placeholder: String
    let choose: @MainActor (URL) -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.dim).frame(width: 46, alignment: .leading)
            Button { chooseFolder(title == "To" ? "Import To" : "Second Copy", then: choose) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(url.map { $0.lastPathComponent } ?? placeholder).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(url == nil ? Theme.accent : Theme.paper)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url?.path ?? "Choose a folder")
        }
    }
}

/// A template: its ready-made forms, and the text itself for a form of one's own.
private struct TemplateRow: View {
    let presets: [(title: String, template: String)]
    @Binding var template: String
    let folders: Bool
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            PanelField(placeholder, text: $template)
            Menu {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.title) { template = preset.template }
                }
                Divider()
                Menu("Insert") {
                    ForEach(ImportTemplate.tokens, id: \.self) { token in Button("{\(token)}") { template += "{\(token)}" } }
                }
            } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        if let problem = ImportTemplate.problem(template, folders: folders) { PanelHint(problem, warn: true) }
    }
}

/// The folders the import will make or fill, with how many photographs each takes: seen before anything is written.
private struct PlanTree: View {
    let session: ImportSession
    var body: some View {
        let plan = session.plan
        if !plan.folders.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan.folders.prefix(40)) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: folder.isNew ? "folder.badge.plus" : "folder").font(.system(size: 10.5)).foregroundStyle(folder.isNew ? Theme.paper : Theme.dim)
                        Text(folder.path.isEmpty ? (session.options.destination?.lastPathComponent ?? "") : folder.path).font(Theme.value(11)).foregroundStyle(Theme.paper)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        Text("\(folder.count)").font(Theme.value(11)).foregroundStyle(Theme.dim)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(folder.bytes), countStyle: .file)).font(Theme.value(10.5)).foregroundStyle(Theme.faint)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .help(folder.isNew ? "A new folder" : "This folder is already there")
                }
                if plan.folders.count > 40 { Text("and \(plan.folders.count - 40) more folders").font(.system(size: 10.5)).foregroundStyle(Theme.dim) }
                let renamed = plan.frames.filter(\.renamed).count
                if renamed > 0 { PanelHint("\(renamed) \(renamed == 1 ? "name is" : "names are") taken there: numbered, nothing is written over.", warn: true) }
                let undated = session.includedFrames.filter { $0.time == nil }.count, fromFile = session.includedFrames.filter(\.dateFromFile).count
                if undated > 0 { PanelHint("\(undated) without any date: filed under “Undated”.", warn: true) }
                if fromFile > 0 { PanelHint("\(fromFile) say no date themselves: filed by their file’s date.") }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.25)))
        }
    }
}

/// The recipe the photographs are developed with once they're imported: for all that's checked, or for the selection.
private struct RecipeChooser: View {
    let model: EditorModel

    var body: some View {
        @Bindable var session = model.lab.importer
        let favourites = model.lab.favouriteRecipes
        let presets = model.presets.sorted { (favourites.contains($0.name) ? 0 : 1, $0.name.lowercased()) < (favourites.contains($1.name) ? 0 : 1, $1.name.lowercased()) }
        let inUse = session.recipesInUse
        if presets.isEmpty {
            PanelHint("No recipes yet. Save a development as a recipe in Recipes, and it can be given to photographs as they’re imported.")
        } else {
            HStack(spacing: 6) {
                recipeMenu("For All Checked", presets: presets, favourites: favourites) { session.assign(recipe: $0, to: session.includedFrames.map(\.id)) }
                recipeMenu("For the Selection", presets: presets, favourites: favourites) { session.assign(recipe: $0) }
                    .disabled(session.targets.isEmpty)
            }
            if inUse.isEmpty {
                PanelHint("None: the photographs arrive undeveloped, as when a folder is opened.")
            } else {
                ForEach(inUse.keys.sorted(), id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "flask").font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                        Text(name).font(.system(size: 12)).foregroundStyle(Theme.paper).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(inUse[name] ?? 0)").font(Theme.value(11)).foregroundStyle(Theme.dim)
                    }
                }
                // Qlick Lab: the recipes' Develop settings, as wherever a recipe is applied (remembered).
                PanelToggle("Apply Develop settings too", isOn: Binding(get: { model.recipesApplyDevelop }, set: { model.recipesApplyDevelop = $0 }),
                            help: RecipeDevelop.applyHelp)
                PanelToggle("Balance each photograph", isOn: $session.options.balanceEach,
                            help: "Each photograph also gets its own Auto white balance and its exposure matched to the camera’s: the recipe’s look on frames taken in any light. Slower.")
                PanelHint("Open a frame in the Loupe to see it developed with its recipe, beside the camera’s own rendering. A recipe stays a setting: it can be changed after the import.")
            }
        }
    }

    private func recipeMenu(_ title: String, presets: [PresetFile], favourites: Set<String>, assign: @escaping (String?) -> Void) -> some View {
        Menu {
            Button("None") { assign(nil) }
            Divider()
            ForEach(presets) { preset in
                Button { assign(preset.name) } label: {
                    if favourites.contains(preset.name) { Label(preset.name, systemImage: "star.fill") } else { Text(preset.name) }
                }
            }
        } label: { Label(title, systemImage: "flask").font(Theme.caps(11.5)).labelStyle(.titleAndIcon) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
