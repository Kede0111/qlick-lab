// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Where the photographs go and how: the import's choices, each in its own section, with the folders they'll make
/// shown before anything is written.
struct ImportPanel: View {
    let model: EditorModel
    @State private var profileName = ""
    @State private var naming = false
    /// Custom chosen while its text is still one of the ready-made forms.
    @State private var customFolders = false
    @State private var customNames = false

    static let inPlaceLine = "The photographs stay where they are: nothing is copied or renamed."

    var body: some View {
        @Bindable var session = model.lab.importer
        let options = session.options
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // The decision that matters most comes first, in three words.
                ImportModeChoice(session: session, card: session.source?.kind == .card)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

                PanelSection("Saved Settings") {
                    HStack(spacing: 6) {
                        Menu {
                            if session.profiles.isEmpty { Text("No saved settings yet") }
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
                            .help("Keeps every choice of this panel under a name (destination, folders, recipe, Archive, words), to use them again in one click. They are kept in this catalog.")
                    }
                    if naming {
                        HStack(spacing: 6) {
                            PanelField("Name, e.g. Leica trip", text: $profileName)
                            Button("Save") { session.saveProfile(named: profileName); naming = false }.buttonStyle(QPillButtonStyle())
                                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                PanelSection("Archive") {
                    ArchiveChooser(model: model, session: session)
                }

                if options.mode != .add {
                    PanelSection("Destination") {
                        if options.mode == .move, session.source?.kind == .card {
                            PanelHint("Move isn’t offered for memory cards. Copy, check, then format the card in the camera.", warn: true)
                        }
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
                    }
                }

                // The structure is always in sight; leaving the photographs where they are greys it, and says why.
                PanelSection("Folders") {
                    if options.mode == .add { PanelHint(Self.inPlaceLine) }
                    VStack(alignment: .leading, spacing: 8) {
                        ChoiceList(choices: ImportStructure.allCases.map { ($0, $0.title, $0.example) }, selection: Binding(
                            get: { customFolders ? .custom : ImportStructure(template: options.folders) },
                            set: { choice in
                                customFolders = choice == .custom
                                if let template = choice.template { session.options.folders = template }
                            }))
                        if customFolders || ImportStructure(template: options.folders) == .custom {
                            TemplateEditor(template: $session.options.folders, files: false, placeholder: "e.g. {yyyy}/{month}")
                        }
                        if options.folders.contains("{job}") || options.rename.contains("{job}") {
                            PanelField("Job name", text: $session.options.job)
                        }
                        Stepper(value: Binding(get: { options.clockOffset / 60 }, set: { session.options.clockOffset = $0 * 60 }), in: -23...23) {
                            Text(options.clockOffset == 0 ? "Camera clock as it is" : "Camera clock \(options.clockOffset > 0 ? "+" : "−")\(abs(options.clockOffset) / 60) h")
                                .font(.system(size: 11.5)).foregroundStyle(options.clockOffset == 0 ? Theme.dim : Theme.paper)
                        }
                        .controlSize(.small)
                        .help("Shifts every capture time before filing: a camera left on another time zone")
                        Stepper(value: $session.options.dayStart, in: 0...8) {
                            Text(options.dayStart == 0 ? "A day starts at midnight" : "A day starts at 0\(options.dayStart):00")
                                .font(.system(size: 11.5)).foregroundStyle(options.dayStart == 0 ? Theme.dim : Theme.paper)
                        }
                        .controlSize(.small)
                        .help("Frames taken before this hour are filed with the evening before, so a night stays in one folder")
                        if options.mode != .add { PlanTree(session: session) }
                    }
                    .disabled(options.mode == .add)
                    .opacity(options.mode == .add ? 0.4 : 1)
                }

                PanelSection("File Names") {
                    VStack(alignment: .leading, spacing: 8) {
                        ChoiceList(choices: ImportNaming.allCases.map { ($0, $0.title, $0.example) }, selection: Binding(
                            get: { customNames ? .custom : ImportNaming(template: options.rename) },
                            set: { choice in
                                customNames = choice == .custom
                                if let template = choice.template { session.options.rename = template }
                            }))
                        if customNames || ImportNaming(template: options.rename) == .custom {
                            TemplateEditor(template: $session.options.rename, files: true, placeholder: "e.g. {date}_{camera}_{seq:4}")
                        }
                    }
                    .disabled(options.mode == .add)
                    .opacity(options.mode == .add ? 0.4 : 1)
                    if options.mode != .add, let example = session.exampleLine {
                        Text(example).font(Theme.value(10.5)).foregroundStyle(Theme.label)
                            .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25)))
                            .help("Where the photograph in view goes, and its new name")
                    }
                }

                PanelSection("Folder Card") {
                    PanelField("Film loaded, e.g. Portra 400 pushed +1", text: optional($session.options.film))
                    PanelField("Camera", text: optional($session.options.camera))
                    PanelField("Notes", text: optional($session.options.notes))
                    PanelHint(options.mode == .add ? "Written on the card of the Folder the photographs are added from: it travels with the folder."
                                                   : "Written on the card of each Folder the import makes: it travels with the folder.")
                }

                PanelSection("Recipe") { RecipeChooser(model: model) }

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
                    PanelToggle("Stack the bursts", isOn: Binding(get: { options.stackBursts == true }, set: { session.options.stackBursts = $0 ? true : nil }),
                                help: "Frames taken less than 2 seconds apart with the same camera become a stack, shown as its first frame with how many it holds")
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

    /// An optional text as a field's text: empty is nil.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
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

/// The Archive the import's folders join (required): one that's there, or a new one, pre-named after the card or
/// the folder and the day. Under it, a Box or a Roll the photographs also go in, if wanted.
private struct ArchiveChooser: View {
    let model: EditorModel
    @Bindable var session: ImportSession

    var body: some View {
        let projects = model.lab.projects
        let chosen = session.chosenProject
        let typed = session.options.project.trimmingCharacters(in: .whitespaces)
        let isNew = chosen == nil && !typed.isEmpty
        let suggested = session.suggestedArchiveName
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("New Archive “\(suggested)”") { session.chooseNewArchive(named: suggested) }
                if !projects.projects.isEmpty {
                    Divider()
                    ForEach(recent(projects)) { project in Button(project.name) { session.choose(project: project) } }
                }
            } label: {
                PanelRowLabel(symbol: "archivebox", text: chosen?.name ?? (isNew ? typed : "Choose an Archive…"), placeholder: chosen == nil && !isNew,
                              trailing: isNew ? "NEW" : nil)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("The Archive the import’s folders join: one that’s there, or a new one")
            if isNew {
                PanelField("Name of the new Archive", text: Binding(get: { session.options.project }, set: { session.chooseNewArchive(named: $0) }))
            }
            PanelHint(chosen.map { "The folders join “\($0.name)”, as they are on the disk." }
                      ?? (isNew ? "A new Archive, made when the import starts." : "Required: every import goes in an Archive."),
                      warn: chosen == nil && !isNew)

            HStack(spacing: 8) {
                Text("Also in").font(.system(size: 11.5)).foregroundStyle(Theme.dim).frame(width: 46, alignment: .leading)
                Menu {
                    Button("No Box") { setHolder(nil) }
                    if !projects.boxes.isEmpty { Divider() }
                    ImportBoxItems(boxes: projects.boxes, choose: setHolder)
                } label: {
                    PanelRowLabel(symbol: session.chosenHolder.map { if case .roll = $0 { "film" } else { "shippingbox" } } ?? "shippingbox",
                                  text: session.chosenHolder.flatMap(projects.name(of:)) ?? "No Box", placeholder: session.chosenHolder == nil, quiet: true)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .disabled(projects.boxes.isEmpty)
                .help(projects.boxes.isEmpty ? "No Box yet: make one in the sidebar to put imports in it" : "A Box or a Roll the imported photographs are also put in")
            }
        }
    }

    private func setHolder(_ holder: Holder?) {
        switch holder {
        case .box(let id): session.options.boxID = id; session.options.boxRollID = nil
        case .roll(let id, let box): session.options.boxID = box; session.options.boxRollID = id
        case nil: session.options.boxID = nil; session.options.boxRollID = nil
        }
    }

    /// The Archives most recently added to first.
    private func recent(_ projects: ProjectStore) -> [LabProject] {
        projects.projects.sorted { ($0.rolls.map(\.addedAt).max() ?? $0.createdAt) > ($1.rolls.map(\.addedAt).max() ?? $1.createdAt) }
    }
}

/// The Boxes as nested menus: each Box itself, its Rolls (not the Smart ones: rules fill them), the Boxes inside.
private struct ImportBoxItems: View {
    let boxes: [LabBox]
    let choose: (Holder?) -> Void

    var body: some View {
        ForEach(boxes) { box in
            let rolls = box.rolls.filter { !$0.isSmart }
            if rolls.isEmpty && box.boxes.isEmpty {
                Button(box.name) { choose(.box(box.id)) }
            } else {
                Menu(box.name) {
                    Button("In “\(box.name)” Itself") { choose(.box(box.id)) }
                    Divider()
                    ForEach(rolls) { roll in Button(roll.name) { choose(.roll(roll.id, box: box.id)) } }
                    AnyView(ImportBoxItems(boxes: box.boxes, choose: choose))
                }
            }
        }
    }
}

/// What a menu row of the panel shows: a symbol, its text, and a short word at the end.
private struct PanelRowLabel: View {
    let symbol: String
    let text: String
    var placeholder = false
    var trailing: String? = nil
    var quiet = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.dim)
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
        }
        .foregroundStyle(placeholder ? (quiet ? Theme.dim : Theme.accent) : Theme.paper)
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
    }
}

/// A list of choices, one line each: a red dot for the one chosen, its name, and an example of what it makes.
private struct ChoiceList<T: Hashable>: View {
    let choices: [(value: T, title: String, example: String)]
    @Binding var selection: T

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                let on = choice.value == selection
                Button { selection = choice.value } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().strokeBorder(on ? Theme.accent : Color.white.opacity(0.28), lineWidth: 1.2)
                            if on { Circle().fill(Theme.accent).padding(3) }
                        }
                        .frame(width: 12, height: 12)
                        Text(choice.title).font(.system(size: 12)).foregroundStyle(on ? Theme.paper : Color(white: 0.8))
                        Spacer(minLength: 6)
                        Text(choice.example).font(Theme.value(10.5)).foregroundStyle(on ? Theme.label : Theme.dim).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Color.white.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One's own template: the text, small buttons that put a tag where the cursor is, and a line when a tag is unknown.
private struct TemplateEditor: View {
    @Binding var template: String
    let files: Bool
    let placeholder: String
    @State private var handle = TemplateFieldHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TemplateField(text: $template, placeholder: placeholder, handle: handle)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
            FlowLayout(spacing: 4) {
                ForEach(ImportTemplate.tags(forFiles: files), id: \.token) { tag in
                    Button { handle.insert(tag.token, into: $template) } label: {
                        Text(tag.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.label)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Puts \(tag.token) where the cursor is")
                }
            }
            if let problem = ImportTemplate.problem(template, folders: !files) { PanelHint(problem, warn: true) }
        }
    }
}

/// The text field of a template, which keeps where its cursor was so a tag button can insert there.
@MainActor final class TemplateFieldHandle {
    weak var field: NSTextField?
    /// The selection when the field last changed or lost the keyboard.
    var range: NSRange?

    func insert(_ token: String, into text: Binding<String>) {
        let editor = field?.currentEditor() as? NSTextView
        let at = editor?.selectedRange() ?? range ?? NSRange(location: (text.wrappedValue as NSString).length, length: 0)
        let (new, caret) = ImportTemplate.insert(token, into: text.wrappedValue, at: at)
        text.wrappedValue = new
        field?.stringValue = new
        range = NSRange(location: caret, length: 0)
        // The keyboard back in the field, the cursor after the tag, to go on typing.
        if let field, field.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: caret, length: 0)
        }
    }
}

private struct TemplateField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let handle: TemplateFieldHandle

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.textColor = Theme.NS.paper
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Theme.NS.faint, .font: NSFont.systemFont(ofSize: 11.5)])
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        handle.field = field
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TemplateField
        init(parent: TemplateField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.handle.range = (field.currentEditor() as? NSTextView)?.selectedRange()
        }
        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.handle.range = (field.currentEditor() as? NSTextView)?.selectedRange() ?? parent.handle.range
            parent.text = field.stringValue
        }
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
        let favourites = Set(model.listedPresets.filter(model.lab.isFavourite(recipe:)).map(\.name))
        let presets = model.listedPresets.sorted { (favourites.contains($0.name) ? 0 : 1, $0.name.lowercased()) < (favourites.contains($1.name) ? 0 : 1, $1.name.lowercased()) }
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

/// The counter's first question: copy the photographs to this Mac, move them, or leave them where they are. One
/// segmented choice, with a line under it saying what the chosen one does; the rest of the panel follows from it.
struct ImportModeChoice: View {
    @Bindable var session: ImportSession
    let card: Bool

    var body: some View {
        let mode = session.options.mode
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("The Photographs")
            QSegmented(options: (card ? [ImportMode.copy] : ImportMode.allCases).map { ($0, $0.short, $0.help) },
                       selection: $session.options.mode)
            Text(card ? "A card's photographs are copied. Format the card in the camera afterwards." : mode.help)
                .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
