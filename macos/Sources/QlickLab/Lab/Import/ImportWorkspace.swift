// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The import room: on the left where photographs come from, in the middle the source's frames to look through and
/// mark, on the right where they go and how, and at the foot one sentence that says what Import will do.
/// While an import runs, the middle shows it instead.
struct ImportWorkspace: View {
    let model: EditorModel
    private var session: ImportSession { model.lab.importer }

    var body: some View {
        let session = session
        VStack(spacing: 0) {
            if let run = session.run {
                ImportProgressView(model: model, run: run)
            } else {
                HStack(spacing: 0) {
                    ImportSources(session: session)
                        .frame(width: 208)
                        .background(Color(white: 0.045))
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                    VStack(spacing: 0) {
                        if session.source == nil {
                            ImportEmpty(session: session)
                        } else {
                            ImportToolbar(model: model)
                            ImportBrowser(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ImportPanel(model: model)
                        .frame(width: 316)
                        .background(Color(white: 0.06))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                }
                ImportFoot(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.058))
        .environment(\.colorScheme, .dark)
        .onAppear { session.refreshVolumes() }
    }
}

// MARK: Sources

private struct ImportSources: View {
    let session: ImportSession
    @State private var dropping = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                if let journal = session.unfinished {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("An import was interrupted").font(Q.label(12, weight: .semibold)).foregroundStyle(Q.text)
                        Text("\(journal.remaining) of \(journal.items.count) photographs from “\(journal.sourceName)” are still to copy. Nothing copied is lost.")
                            .font(.system(size: 11)).foregroundStyle(Q.dim).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button("Resume") { session.resume() }.buttonStyle(QPrimaryButtonStyle())
                            Button("Forget") { session.discardUnfinished() }.buttonStyle(QPillButtonStyle())
                                .help("Forgets what was left to copy. What was already copied stays where it is.")
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                    .padding(.bottom, 10)
                }
                heading("Cards")
                let cards = session.volumes.filter { $0.kind == .card }
                if cards.isEmpty {
                    Text("No memory card. One appears here when it’s put in.").font(.system(size: 11)).foregroundStyle(Q.dim)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.bottom, 6)
                }
                ForEach(cards) { card in row(card) { session.open(card) } }
                heading("Disks")
                let disks = session.volumes.filter { $0.kind == .disk }
                ForEach(disks) { disk in row(disk, trailing: "…") { session.chooseFolder(startingAt: disk.root) } }
                RoomButton(symbol: "folder.badge.plus", title: "Choose a Folder…", on: false) { session.chooseFolder() }
                if !session.recent.isEmpty {
                    heading("Recent")
                    ForEach(session.recent, id: \.self) { folder in
                        row(ImportVolumes.folder(folder)) { session.open(ImportVolumes.folder(folder)) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Q.red, lineWidth: 2).padding(5).allowsHitTesting(false) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            LabDrop.load(providers) { urls in
                guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) else { return }
                session.open(ImportVolumes.folder(folder))
            }
        }
    }

    private func heading(_ text: String) -> some View {
        CapsLabel(text).padding(.leading, 10).padding(.top, 12).padding(.bottom, 5)
    }

    private func row(_ source: ImportSource, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        RoomButton(symbol: source.symbol, title: source.name, on: session.source?.root == source.root, trailing: trailing, action: action)
            .help(source.kind == .disk ? "Choose a folder of “\(source.name)”" : source.root.path)
            .contextMenu {
                if source.volume != nil {
                    Button("Eject “\(source.name)”") { try? NSWorkspace.shared.unmountAndEjectDevice(at: source.volume!) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.root]) }
            }
    }
}

private struct ImportEmpty: View {
    let session: ImportSession
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sdcard").font(.system(size: 38, weight: .light)).foregroundStyle(Q.faint)
            Text("Put in a card, or choose a folder").font(Q.title(19)).foregroundStyle(Q.text)
            Text("Its photographs show here at once, as the camera rendered them. Look through them, mark them,\nchoose a recipe and where they go. Nothing is copied, and nothing on the source is ever changed, until you press Import.")
                .font(.system(size: 12.5)).foregroundStyle(Q.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(session.cards) { card in
                    Button { session.open(card) } label: { Label(card.name, systemImage: "sdcard") }.buttonStyle(QPrimaryButtonStyle())
                }
                Button { session.chooseFolder() } label: { Label("Choose a Folder…", systemImage: "folder") }.buttonStyle(QPillButtonStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: The bar over the frames

private struct ImportToolbar: View {
    let model: EditorModel

    var body: some View {
        @Bindable var session = model.lab.importer
        HStack(spacing: 10) {
            QSegmented(options: [(ImportView.grid, "Grid", "Every frame of the source (G)"),
                                 (ImportView.loupe, "Loupe", "One frame large, under its recipe when it has one (Space)"),
                                 (ImportView.compare, "Compare", "The selected frames side by side (C)")], selection: $session.view)
                .fixedSize()
            Menu {
                ForEach(ImportFilter.allCases, id: \.self) { filter in
                    Button { session.filter = filter } label: {
                        if session.filter == filter { Label(filter.title, systemImage: "checkmark") } else { Text(filter.title) }
                    }
                    .help(filter.help)
                }
            } label: {
                Label("Show: \(session.filter.title)", systemImage: "line.3.horizontal.decrease").font(Q.label(12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Which frames are shown")
            Text(counts(session)).font(Q.value(11.5)).foregroundStyle(Q.dim).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            if !session.datesReady, !session.scanning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Reading dates \(session.factsRead) / \(session.frames.count)").font(Q.value(11)).foregroundStyle(Q.dim)
                }
            }
            Spacer(minLength: 8)
            QIconButton(symbol: "checkmark.circle", help: "Check all: every frame shown is imported") { session.setIncluded(true, session.shown.map(\.id)) }
            QIconButton(symbol: "circle", help: "Uncheck all: no frame shown is imported, check those you want") { session.setIncluded(false, session.shown.map(\.id)) }
            if !session.bursts.isEmpty {
                QIconButton(symbol: "square.stack.3d.down.right", help: "Firsts of bursts: keeps the first frame of every burst checked and unchecks the others") { session.keepFirstOfBursts() }
            }
            Divider().frame(height: 16).overlay(Color.white.opacity(0.12))
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Q.dim)
                Slider(value: $session.cellSize, in: 110...420).controlSize(.mini).tint(Color(white: 0.75)).frame(width: 96).help("Frame size")
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Q.dim)
            }
            if session.source?.volume != nil {
                QIconButton(symbol: "eject", help: "Eject “\(session.source?.name ?? "")”") { session.eject() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(white: 0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func counts(_ session: ImportSession) -> String {
        if session.scanning { return "Reading “\(session.source?.name ?? "")”…" }
        var parts = ["\(session.frames.count) photographs"]
        if session.shown.count != session.frames.count { parts.append("\(session.shown.count) shown") }
        if !session.known.isEmpty { parts.append("\(session.known.count) already imported") }
        if !session.selected.isEmpty { parts.append("\(session.selected.count) selected") }
        return parts.joined(separator: " · ")
    }
}

// MARK: The frames

/// The middle of the room: the grid, the loupe or the comparison, with the keys of the sort.
struct ImportBrowser: View {
    let model: EditorModel
    @FocusState private var focused: Bool
    @State private var columns = 4

    private var session: ImportSession { model.lab.importer }

    var body: some View {
        let session = session
        ZStack {
            switch session.view {
            case .grid: grid
            case .loupe: ImportLoupe(model: model)
            case .compare: ImportCompare(model: model)
            }
            if session.scanning { ProgressView().controlSize(.small) }
            else if session.frames.isEmpty { Text("No readable photographs in “\(session.source?.name ?? "")”.").font(.system(size: 12.5)).foregroundStyle(Q.dim) }
            else if session.shown.isEmpty { Text("No frame matches this filter.").font(.system(size: 12.5)).foregroundStyle(Q.dim) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: session.source) { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in ImportKeys.handle(press, model: model, columns: columns) ? .handled : .ignored }
        .simultaneousGesture(TapGesture().onEnded { focused = true })
    }

    private var grid: some View { ImportGrid(session: session, columns: $columns) }
}

/// The source's frames, laid out as they were taken.
private struct ImportGrid: View {
    let session: ImportSession
    @Binding var columns: Int

    var body: some View {
        let size = CGFloat(session.cellSize)
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) { cells(size) }
                    .onChange(of: session.current) { _, current in
                        if let current { withAnimation(Q.quick) { proxy.scrollTo(current) } }
                    }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in columns = Self.count(width, size) }
            .onChange(of: size) { _, size in columns = Self.count(geometry.size.width, size) }
        }
    }

    private static func count(_ width: CGFloat, _ size: CGFloat) -> Int { max(Int((width - 18) / (size + 10)), 1) }

    private func cells(_ size: CGFloat) -> some View {
        let columns = [GridItem(.adaptive(minimum: size, maximum: size * 1.6), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(session.shown) { frame in cell(frame, size) }
        }
        .padding(14)
    }

    private func cell(_ frame: ImportFrame, _ size: CGFloat) -> some View {
        ImportCell(session: session, frame: frame, side: size)
            .id(frame.id)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                session.click(frame.id, command: flags.contains(.command), shift: flags.contains(.shift))
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { session.view = .loupe })
    }
}

/// The room's keys: the lab's own for the marks, the arrows, and a few of the import's.
enum ImportKeys {
    @MainActor static func handle(_ press: KeyPress, model: EditorModel, columns: Int) -> Bool {
        let session = model.lab.importer, keys = model.lab.keys
        let shift = press.modifiers.contains(.shift)
        if press.modifiers.contains(.command) {
            if press.characters == "a" { session.selectAll(); return true }
            if press.characters == "d" { session.selectNone(); return true }
            return false
        }
        switch press.key {
        case .leftArrow: session.move(by: -1, extend: shift); return true
        case .rightArrow: session.move(by: 1, extend: shift); return true
        case .upArrow: session.move(by: session.view == .grid ? -columns : -1, extend: shift); return true
        case .downArrow: session.move(by: session.view == .grid ? columns : 1, extend: shift); return true
        case .space, .return: session.view = session.view == .loupe ? .grid : .loupe; return true
        case .escape:
            if session.view != .grid { session.view = .grid; return true }
            if !session.selected.isEmpty { session.selectNone(); return true }
            return false
        default: break
        }
        let character = press.characters.lowercased()
        if character == keys.key(.pick) { session.toggle(flag: "pick"); return true }
        if character == keys.key(.reject) { session.toggle(flag: "reject"); return true }
        if character == keys.key(.unmark) { session.unmark(); return true }
        switch character {
        case "0", "1", "2", "3", "4", "5": session.rate(Int(character) ?? 0); return true
        case "i": session.toggleIncluded(); return true
        case "g": session.view = .grid; return true
        case "c": session.view = session.view == .compare ? .grid : .compare; return true
        case "]": session.rotate(by: 1); return true
        case "[": session.rotate(by: -1); return true
        case "\\": session.splitBefore.toggle(); return true
        default: return false
        }
    }
}

/// One frame of the grid: the camera's own preview, never a development, with what the import will do with it.
struct ImportCell: View {
    let session: ImportSession
    let frame: ImportFrame
    let side: CGFloat
    @State private var image: CGImage?

    var body: some View {
        let id = frame.id
        let marks = session.marks(for: id)
        let included = session.included(id), known = session.known.contains(id)
        let selected = session.selected.contains(id), current = session.current == id
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(white: current ? 0.13 : 0.085))
                if let image {
                    TurnedPicture(image: image, rotation: marks.rotation)
                        .padding(7)
                        .opacity(included ? (marks.flag == "reject" ? 0.45 : 1) : 0.28)
                        .overlay {
                            if let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:)) { ImportMark(flag: flag, seed: frame.file.name).padding(7) }
                        }
                }
            }
            .frame(height: side * 0.72)
            .overlay(alignment: .topLeading) {
                Button { session.toggleIncluded([id]) } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(included ? Q.red : Color(white: 0.5), .white)
                        .symbolRenderingMode(included ? .palette : .monochrome)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(included ? "Imported. Click to leave it out (I)" : known ? "Already imported by this catalog. Click to import it again (I)" : "Left out. Click to import it (I)")
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if frame.companion != nil { badge("R+J", help: "A RAW with its JPEG: one photograph") }
                    if session.bursts[id] != nil { badge("BURST", help: "Taken within two seconds of another") }
                    if known { badge("IMPORTED", help: "This catalog imported it before") }
                }
                .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if marks.rating > 0 {
                    Text(String(repeating: "★", count: marks.rating)).font(.system(size: 10)).foregroundStyle(Q.text)
                        .shadow(color: .black, radius: 1.5).padding(.leading, 8).padding(.bottom, 6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let recipe = marks.recipe {
                    Label(recipe, systemImage: "flask").font(.system(size: 9.5, weight: .medium)).labelStyle(.titleAndIcon).lineLimit(1)
                        .foregroundStyle(Q.text).padding(.horizontal, 6).frame(height: 17)
                        .background(Capsule().fill(Color.black.opacity(0.62))).padding(5)
                        .frame(maxWidth: side * 0.7, alignment: .trailing)
                        .help("Developed with the recipe “\(recipe)” once it’s imported")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(selected ? Color.white : current ? Color.white.opacity(0.45) : .clear, lineWidth: selected ? 2 : 1)
            }
            Text(frame.file.name).font(Q.value(10.5)).foregroundStyle(current || selected ? Q.text : Q.dim).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help(tooltip)
        .task(id: id) {
            let file = PhotoFile(url: id)
            let large = side > 190
            let loaded = await PhotoThumbnails.shared.image(for: file, size: large ? .large : .medium)
            if !Task.isCancelled { image = loaded }
        }
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text).font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(Color(white: 0.9))
            .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(Color.black.opacity(0.62))).help(help)
    }

    private var tooltip: String {
        var lines = [frame.file.name]
        if let time = frame.time { lines.append(time.text + (frame.dateFromFile ? " (the file’s date: the photograph says none)" : "")) } else { lines.append("No date") }
        if let camera = frame.camera { lines.append([camera, frame.lens].compactMap { $0 }.joined(separator: " · ")) }
        if let planned = session.plan.frames.first(where: { $0.id == frame.id }) {
            switch planned.status {
            case .new: lines.append("→ " + planned.files.map(\.destination.path).joined(separator: "\n→ "))
            case .duplicate: lines.append("Already imported: \(planned.earlier ?? "")")
            case .present: lines.append("Already at the destination")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A picture turned by quarter turns, fitted to the room it's given whichever way it stands.
struct TurnedPicture: View {
    let image: CGImage
    /// Clockwise quarter turns.
    let rotation: Int
    var interpolation = Image.Interpolation.medium

    var body: some View {
        GeometryReader { geometry in
            let turned = rotation % 2 != 0
            let box = turned ? CGSize(width: geometry.size.height, height: geometry.size.width) : geometry.size
            Image(decorative: image, scale: 1).resizable().interpolation(interpolation).aspectRatio(contentMode: .fit)
                .frame(width: box.width, height: box.height)
                .rotationEffect(.degrees(Double(rotation) * 90))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// The grease pencil's ring or cross over a frame.
struct ImportMark: View {
    let flag: PhotoSidecar.Flag
    let seed: String
    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.07, dy: size.height * 0.09)
            let weight = GreasePencil.weight(forFrameWidth: frame.width) * 1.3
            let strokes = flag == .pick ? GreasePencil.ring(in: frame, seed: seed, weight: weight) : GreasePencil.cross(in: frame, seed: seed, weight: weight)
            for stroke in strokes { context.fill(Path(stroke.path()), with: .color(Q.red.opacity(stroke.opacity))) }
        }
        .allowsHitTesting(false)
    }
}

// MARK: The foot

/// One sentence for what Import will do, and the room's one red button.
private struct ImportFoot: View {
    let session: ImportSession

    var body: some View {
        let blocker = session.blocker
        HStack(spacing: 12) {
            if session.source != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentence).font(Q.value(12)).foregroundStyle(Q.text).lineLimit(1).truncationMode(.middle)
                    if let blocker { Text(blocker).font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1) }
                    else if let note { Text(note).font(.system(size: 11)).foregroundStyle(Q.dim).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            Button { session.start() } label: {
                Label(session.options.mode == .add ? "Add" : "Import", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
            }
            .buttonStyle(QPrimaryButtonStyle())
            .disabled(blocker != nil)
            .keyboardShortcut(.return, modifiers: .command)
            .help(blocker ?? "Starts the import (⌘↩)")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color(white: 0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private var sentence: String {
        let plan = session.plan, options = session.options
        var parts = ["\(plan.toCopy.count) of \(session.frames.count) photographs"]
        if options.mode != .add { parts.append(ByteCountFormatter.string(fromByteCount: Int64(plan.bytes), countStyle: .file)) }
        switch options.mode {
        case .add: parts.append("Added where they are")
        case .copy, .move:
            if let destination = options.destination {
                let first = plan.folders.first.map { " › " + $0.path.replacingOccurrences(of: "/", with: " › ") } ?? ""
                parts.append("\(options.mode.title) to \(destination.lastPathComponent)\(plan.folders.count == 1 ? first : "")")
            }
        }
        if plan.folders.count > 1 { parts.append("\(plan.folders.count) folders") }
        return parts.joined(separator: " · ")
    }

    private var note: String? {
        var parts: [String] = []
        if session.plan.duplicates > 0 { parts.append("\(session.plan.duplicates) already imported, left out") }
        let recipes = session.recipesInUse
        if !recipes.isEmpty { parts.append(recipes.count == 1 ? "recipe “\(recipes.keys.first!)”" : "\(recipes.count) recipes") }
        if session.options.secondCopy != nil { parts.append("with a second copy") }
        if !session.options.verify { parts.append("copies not checked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
