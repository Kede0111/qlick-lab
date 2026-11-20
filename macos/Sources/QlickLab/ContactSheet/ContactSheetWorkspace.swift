// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The contact sheet's room: the sheet, a bar of tools over it and, floating at its foot, the counts that filter it.
struct ContactSheetWorkspace: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        let library = model.library
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                SheetToolbar(model: model)
                if model.source == nil && library.directory == nil {
                    SheetEmpty(model: model)
                } else {
                    ContactSheetHost(model: model)
                        .overlay {
                            if library.loading || library.filtering { ProgressView().controlSize(.small) }
                            else if library.failed { SheetMessage(text: "This folder can't be read.") }
                            else if library.files.isEmpty { SheetMessage(text: "No readable photographs in this folder.") }
                            else if lab.frames.isEmpty { SheetMessage(text: "No frame matches this filter.") }
                        }
                }
            }
            if library.directory != nil, lab.filterBarVisible {
                LibraryFilterBar(model: model).padding(.bottom, 14)
            }
            if lab.sheet.showInfo, lab.loupe == nil, let current = model.selection.current {
                FrameInfoPanel(model: model, item: current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 58).padding(.trailing, 16)
                    .allowsHitTesting(false)
            }
            if let loupe = lab.loupe {
                SheetLoupe(model: model, item: loupe)
                    .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: lab.loupe)
        .background(lab.sheet.lightTable ? Color(white: 0.9) : Color(white: 0.058))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Tools

/// The contact sheet's bar. The four views share it, Grid included (`GridSheet`), so the view switcher and the
/// tools never move.
struct SheetToolbar: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        @Bindable var lab = model.lab
        HStack(spacing: 10) {
            // The pointer selects, the pencil marks at a click, the loupe looks closer.
            QSegmented(options: [(SheetOptions.Tool.pointer, "Pointer", "Click selects; the keys mark (\(ShortcutStore.display(lab.keys.key(.pencil))) switches to the pencil)"),
                                 (SheetOptions.Tool.pencil, "Pencil", "Click draws the mark chosen beside it, ⌥-click the other one; drag across frames to mark a run"),
                                 (SheetOptions.Tool.loupe, "Loupe", "A glass over the frame under the pointer, three times as large (\(ShortcutStore.display(lab.keys.key(.loupeTool))))")],
                       selection: $lab.sheet.tool)
            if lab.sheet.tool == .pencil {
                HStack(spacing: 2) {
                    markButton(.ring, flag: .pick, help: "The pencil rings: picks")
                    markButton(.cross, flag: .reject, help: "The pencil crosses out: rejects")
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            Spacer(minLength: 8)
            BackgroundActivity(model: model)
            SheetStylePicker(lab: lab)
            // Always in its place, so the view switcher never moves; only the strips have film to hide.
            let strips = lab.sheet.style == .classic || lab.sheet.style == .compact
            QIconButton(symbol: "film", help: lab.sheet.showFilm ? "Hide the film: the photographs alone" : "Show the film under the photographs", active: strips && lab.sheet.showFilm) { lab.sheet.showFilm.toggle() }
                .disabled(!strips).opacity(strips ? 1 : 0.35)
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Theme.dim)
                Slider(value: $lab.sheet.frameWidth, in: SheetOptions.widths)
                    .controlSize(.mini).tint(Color(white: 0.75)).frame(width: 110)
                    .help("Frame size (pinch on the trackpad)")
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Theme.dim)
            }
            Divider().frame(height: 16).overlay(Color.white.opacity(0.12))
            QIconButton(symbol: lab.sheet.lightTable ? "lightbulb.fill" : "lightbulb", help: "Light table", active: lab.sheet.lightTable) { lab.sheet.lightTable.toggle() }
            QIconButton(symbol: "rectangle.portrait.rotate", help: "Upright frames on their side, as on the film", active: lab.sheet.sidewaysVerticals) { lab.sheet.sidewaysVerticals.toggle() }
            FileNamesMenu(lab: lab)
            QIconButton(symbol: "info.circle", help: "Frame information", active: lab.sheet.showInfo) { lab.sheet.showInfo.toggle() }
            QIconButton(symbol: "line.3.horizontal.decrease.circle", help: "Filters and sorting (\\)", active: lab.filterBarVisible) { lab.filterBarVisible.toggle() }
            Divider().frame(height: 16).overlay(Color.white.opacity(0.12))
            QIconButton(symbol: "rectangle.split.2x1", help: "Compare the selection (\(ShortcutStore.display(lab.keys.key(.compare))))") { lab.compareSelection() }
            Button { lab.printing = true } label: {
                Label("Print…", systemImage: "printer").labelStyle(.titleAndIcon)
            }
            .buttonStyle(QPillButtonStyle())
            .disabled(model.library.files.isEmpty)
            .help("A printable contact sheet: PDF or printer (⌘P)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(white: 0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

extension SheetToolbar {
    fileprivate func markButton(_ mark: SheetOptions.Mark, flag: PhotoSidecar.Flag, help: String) -> some View {
        let on = model.lab.sheet.pencilMark == mark
        return Button { model.lab.sheet.pencilMark = mark } label: {
            MarkGlyph(flag: flag).frame(width: 16, height: 12).opacity(on ? 1 : 0.45)
                .frame(width: 30, height: 22)
                .background(Capsule().fill(on ? Color.white.opacity(0.14) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The sheet's four views: strips of film, tight strips, large frames with their facts, and NEgs's grid.
struct SheetStylePicker: View {
    let lab: LabState
    var body: some View {
        @Bindable var lab = lab
        QSegmented(options: [(SheetOptions.Style.classic, "Classic", "Strips of film, with perforations, numbers and names"),
                             (SheetOptions.Style.compact, "Compact", "Tight strips, no names"),
                             (SheetOptions.Style.detail, "Detail", "Large frames with date and exposure"),
                             (SheetOptions.Style.grid, "Grid", "Every photograph side by side at its own proportions")],
                   selection: $lab.sheet.style)
    }
}

// MARK: Filters

/// The pencil's two marks, small: for filters, menus and legends.
struct MarkGlyph: View {
    let flag: PhotoSidecar.Flag
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let strokes = flag == .pick ? GreasePencil.ring(in: rect, seed: "glyph", weight: 1.7) : GreasePencil.cross(in: rect.insetBy(dx: -2, dy: -1), seed: "glyph", weight: 1.9)
            for stroke in strokes { context.fill(Path(stroke.path()), with: .color(Theme.accent.opacity(stroke.opacity))) }
        }
        .accessibilityHidden(true)
    }
}

private struct SheetMessage: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(Theme.dim) }
}

private struct SheetEmpty: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 16) {
            QMark(size: 54)
            Text("No contact sheet open").font(Theme.title(19)).foregroundStyle(Theme.paper)
            Text("Drop a folder of photographs on the window,\nor open a folder of an Archive.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            Button("Import a Folder…") { model.lab.importPanel() }.buttonStyle(QPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Information

/// What the file says of the current frame, on glass at the sheet's corner.
struct FrameInfoPanel: View {
    let model: EditorModel
    let item: URL

    var body: some View {
        let facts = model.lab.facts.get(item)
        let summary = model.library.summary(for: item)
        VStack(alignment: .leading, spacing: 7) {
            Text(model.library.name(of: item)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
            if let facts {
                if let date = facts.dateLine { row("Date", date) }
                if let camera = facts.camera { row("Camera", camera) }
                if let lens = facts.lens { row("Lens", lens) }
                if !facts.exposureLine.isEmpty { row("Exposure", facts.exposureLine) }
                if let pixels = facts.pixels { row("Pixels", "\(Int(pixels.width)) × \(Int(pixels.height))") }
            }
            row("Film", summary.edited ? filmName : "\(model.films.first { $0.id == model.newPhotoFilm }?.name ?? model.newPhotoFilm) (default)")
            if summary.rating > 0 { row("Rating", String(repeating: "★", count: summary.rating)) }
            if let problem = summary.problem { Text(problem).font(.system(size: 11)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The film an edited frame was developed on, from its sidecar.
    private var filmName: String {
        let state = model.labEdits(for: item).state
        return model.films.first { $0.id == state.film }?.name ?? state.film
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CapsLabel(label, size: 9.5).frame(width: 74, alignment: .leading)
            Text(value).font(Theme.value(11.5)).foregroundStyle(Color(white: 0.86)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// File Names: Off, On the Edge (printed on the film, like a frame's number) or Under the Frame (on the sheet). One
/// setting for every view that shows the photographs: the contact sheet's four, Develop's film strip, Compare, and
/// Import's grid and comparison. Where a view has no film edge (the Grid, Import) the edge's name is the fainter one.
struct FileNamesMenu: View {
    let lab: LabState
    var body: some View {
        Menu {
            ForEach(SheetOptions.FileNames.allCases, id: \.self) { choice in
                Button { lab.sheet.fileNames = choice } label: {
                    if lab.sheet.fileNames == choice { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                }
            }
        } label: {
            Image(systemName: "textformat.size.smaller")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(lab.sheet.fileNames != .off ? Theme.accent : Color(white: 0.72))
                .frame(width: 28, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("File Names: \(lab.sheet.fileNames.title)")
    }
}
