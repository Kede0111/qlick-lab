// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// What Comparaison lays side by side.
struct CompareSetup: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Neighbouring frames: which of these takes is the one?
        case photographs
        /// One photograph on several films.
        case films
        /// One photograph under several recipes.
        case recipes
        /// One photograph's versions (its virtual copies).
        case versions
        /// The file as it came, and its development, split by a line.
        case beforeAfter

        var title: String {
            switch self {
            case .photographs: "Photographs"
            case .films: "Films"
            case .recipes: "Recipes"
            case .versions: "Versions"
            case .beforeAfter: "Before / After"
            }
        }
        var help: String {
            switch self {
            case .photographs: "Several close frames side by side, to choose the right one"
            case .films: "The same photograph developed on several films"
            case .recipes: "The same photograph under several recipes"
            case .versions: "A photograph's versions (virtual copies)"
            case .beforeAfter: "The original file and its development, split by a line to drag"
            }
        }
    }

    var kind = Kind.photographs
    /// The photographs compared (`photographs`), else the one photograph everything is tried on.
    var items: [URL] = []
    var films: [String] = []
    var recipes: [URL] = []
    static let most = 4
}

/// One pane of the comparison: what it shows and how it's named.
struct ComparePane: Identifiable, Equatable {
    var id: String
    var request: LabDeveloper.Request
    var item: URL
    var title: String
    var subtitle = ""
    var film: String?
    var recipe: URL?
}

/// The comparison's panes and their images, developed as they're needed.
@MainActor @Observable final class CompareModel {
    @ObservationIgnored unowned let model: EditorModel
    @ObservationIgnored let developer: LabDeveloper
    private(set) var panes: [ComparePane] = []
    private(set) var images: [String: CGImage] = [:]
    private(set) var standIns: [String: CGImage] = [:]
    private(set) var busy: Set<String> = []
    var focused = 0
    var linked = true
    var split: CGFloat = 0.5
    var magnification: CGFloat = 1
    /// The focused pane's zoom, as a multiple of its fitted size.
    var zoom: CGFloat = 1
    @ObservationIgnored weak var canvas: CompareCanvas?
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    /// Long side developed, in pixels: enough to judge sharpness at 100 % without developing the whole frame.
    /// The engine's largest for a lab develop: sharper than a screen's pane, so 100 % shows real pixels.
    static let longSide = 4096

    init(model: EditorModel) {
        self.model = model
        developer = LabDeveloper(model: model)
    }

    private var lab: LabState { model.lab }

    /// The photograph the films, recipes and versions are tried on.
    var subject: URL? {
        let setup = lab.compare
        if setup.kind != .photographs, let first = setup.items.first { return first }
        return model.selection.current ?? model.sourceItem ?? setup.items.first
    }

    /// Builds the panes from the setup, keeping the images already made.
    func refresh() {
        let setup = lab.compare
        var next: [ComparePane] = []
        let library = model.library
        func name(_ item: URL) -> String { library.name(of: item) }
        switch setup.kind {
        case .photographs:
            for item in setup.items.prefix(CompareSetup.most) {
                next.append(ComparePane(id: "p|" + item.absoluteString, request: .init(item: item, longSide: Self.longSide), item: item, title: name(item)))
            }
        case .films:
            guard let subject else { break }
            for film in setup.films.prefix(CompareSetup.most) {
                let stock = model.films.first { $0.id == film }
                next.append(ComparePane(id: "f|\(film)|" + subject.absoluteString, request: .init(item: subject, film: film, longSide: Self.longSide), item: subject,
                                        title: stock?.name ?? film, subtitle: name(subject), film: film))
            }
        case .recipes:
            guard let subject else { break }
            for recipe in setup.recipes.prefix(CompareSetup.most) {
                guard let file = model.presets.first(where: { $0.url == recipe }) else { continue }
                next.append(ComparePane(id: "r|\(recipe.path)|" + subject.absoluteString, request: .init(item: subject, recipe: recipe, longSide: Self.longSide), item: subject,
                                        title: file.name, subtitle: name(subject), recipe: recipe))
            }
        case .versions:
            guard let subject else { break }
            let photo = subject.photoFile
            let versions = [photo] + (library.duplicates[photo] ?? []).map { photo.variant($0) }
            for (index, version) in versions.prefix(CompareSetup.most).enumerated() {
                next.append(ComparePane(id: "v|" + version.absoluteString, request: .init(item: version, longSide: Self.longSide), item: version,
                                        title: index == 0 ? "Version 1" : "Version \(index + 1)", subtitle: name(photo)))
            }
        case .beforeAfter:
            guard let subject else { break }
            next.append(ComparePane(id: "o|" + subject.absoluteString, request: .init(item: subject, original: true, longSide: Self.longSide), item: subject, title: "Before", subtitle: "Original file"))
            next.append(ComparePane(id: "d|" + subject.absoluteString, request: .init(item: subject, longSide: Self.longSide), item: subject, title: "After", subtitle: name(subject)))
        }
        let kept = Set(next.map(\.id))
        for (id, load) in loads where !kept.contains(id) { load.cancel(); loads[id] = nil }
        images = images.filter { kept.contains($0.key) }
        standIns = standIns.filter { kept.contains($0.key) }
        busy = busy.intersection(kept)
        if next != panes { panes = next }
        if focused >= next.count { focused = max(next.count - 1, 0) }
        for pane in next { load(pane) }
        push()
    }

    /// Develops again what an edit made stale (called when the open photograph's development changes).
    func invalidate() {
        for pane in panes where developer.cached(pane.request) == nil && loads[pane.id] == nil {
            images[pane.id] = nil
            load(pane)
        }
        push()
    }

    private func load(_ pane: ComparePane) {
        if let cached = developer.cached(pane.request) {
            if images[pane.id] !== cached { images[pane.id] = cached }
            return
        }
        guard loads[pane.id] == nil else { return }
        busy.insert(pane.id)
        let file = PhotoFile(url: pane.item.photoFile)
        let edited = pane.request.original || pane.film != nil || pane.recipe != nil ? nil : model.editedThumbnail(for: pane.item)
        loads[pane.id] = Task { [weak self] in
            // The thumbnail at once, then the development at the size it's looked at.
            if pane.film == nil, pane.recipe == nil, !pane.request.original, self?.standIns[pane.id] == nil {
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    await PhotoThumbnails.shared.image(for: file, size: .large, look: edited?.look, edited: edited?.store)
                }.value
                if let thumbnail, let self, !Task.isCancelled, self.images[pane.id] == nil { self.standIns[pane.id] = thumbnail; self.push() }
            }
            let image = await self?.developer.image(pane.request)
            guard let self, !Task.isCancelled else { return }
            self.loads[pane.id] = nil
            self.busy.remove(pane.id)
            if let image { self.images[pane.id] = image }
            self.push()
        }
    }

    /// Hands the canvas what it draws.
    func push() {
        guard let canvas else { return }
        canvas.split = lab.compare.kind == .beforeAfter
        canvas.linked = linked
        canvas.splitPosition = split
        canvas.focused = focused
        canvas.panes = panes.map { CompareCanvas.Pane(image: images[$0.id], standIn: standIns[$0.id], busy: busy.contains($0.id)) }
        magnification = canvas.magnification
        zoom = canvas.viewport.zoom
    }

    // MARK: Changing what's compared

    func setKind(_ kind: CompareSetup.Kind) {
        var setup = lab.compare
        let subject = subject
        setup.kind = kind
        switch kind {
        case .photographs:
            if setup.items.count < 2 { setup.items = defaultPhotographs(around: subject) }
        case .films:
            if let subject { setup.items = [subject] }
            if setup.films.isEmpty { setup.films = defaultFilms(for: subject) }
        case .recipes:
            if let subject { setup.items = [subject] }
            if setup.recipes.isEmpty { setup.recipes = model.listedPresets.prefix(3).map(\.url) }
        case .versions, .beforeAfter:
            if let subject { setup.items = [subject] }
        }
        lab.compare = setup
        refresh()
        canvas?.zoomToFit()
    }

    private func defaultPhotographs(around subject: URL?) -> [URL] {
        let order = model.shownPhotos.map(\.url)
        guard let subject, let index = order.firstIndex(of: subject) else { return Array(order.prefix(2)) }
        return Array(order[index..<min(index + 2, order.count)])
    }

    /// The film the photograph is on, then the favourites, then two classics of other families.
    private func defaultFilms(for subject: URL?) -> [String] {
        var films: [String] = []
        if let subject { films.append(model.labEdits(for: subject).state.film) }
        let known = Set(model.films.map(\.id))
        for film in lab.shelf.favouriteIDs(.film) + ["kodak_portra_400", "kodak_ektar_100", "fujifilm_velvia_50", "kodak_gold_200"]
        where known.contains(film) && !films.contains(film) && films.count < 3 {
            films.append(film)
        }
        return films
    }

    func setFilm(_ film: String, pane index: Int) {
        guard lab.compare.films.indices.contains(index) else { return }
        lab.compare.films[index] = film
        refresh()
    }

    func setRecipe(_ recipe: URL, pane index: Int) {
        guard lab.compare.recipes.indices.contains(index) else { return }
        lab.compare.recipes[index] = recipe
        refresh()
    }

    var canAddPane: Bool {
        let setup = lab.compare
        switch setup.kind {
        case .films: return setup.films.count < CompareSetup.most
        case .recipes: return setup.recipes.count < min(CompareSetup.most, model.listedPresets.count)
        case .photographs: return setup.items.count < CompareSetup.most
        case .versions: return panes.count < CompareSetup.most && model.canChangeEdits
        case .beforeAfter: return false
        }
    }

    func addPane() {
        var setup = lab.compare
        switch setup.kind {
        case .films:
            let used = Set(setup.films)
            if let next = (lab.shelf.favouriteIDs(.film) + model.films.map(\.id)).first(where: { !used.contains($0) && model.films.map(\.id).contains($0) }) { setup.films.append(next) }
        case .recipes:
            let used = Set(setup.recipes)
            if let next = model.listedPresets.first(where: { !used.contains($0.url) }) { setup.recipes.append(next.url) }
        case .photographs:
            let order = model.shownPhotos.map(\.url)
            if let last = setup.items.last, let index = order.firstIndex(of: last), order.indices.contains(index + 1), !setup.items.contains(order[index + 1]) {
                setup.items.append(order[index + 1])
            } else if let next = order.first(where: { !setup.items.contains($0) }) { setup.items.append(next) }
        case .versions:
            // A new version of the photograph: a virtual copy, which starts as the version it's made from.
            if let subject { model.duplicate([panes.indices.contains(focused) ? panes[focused].item : subject]) }
            lab.compare = setup
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(150)); self?.refresh() }
            return
        case .beforeAfter: break
        }
        lab.compare = setup
        refresh()
    }

    func removePane(_ index: Int) {
        var setup = lab.compare
        switch setup.kind {
        case .films: if setup.films.count > 2, setup.films.indices.contains(index) { setup.films.remove(at: index) }
        case .recipes: if setup.recipes.count > 2, setup.recipes.indices.contains(index) { setup.recipes.remove(at: index) }
        case .photographs: if setup.items.count > 2, setup.items.indices.contains(index) { setup.items.remove(at: index) }
        default: break
        }
        lab.compare = setup
        refresh()
    }

    /// In `photographs`, steps the focused pane to the frame before or after, to walk a series against a fixed one.
    func step(by offset: Int) {
        var setup = lab.compare
        guard setup.kind == .photographs, setup.items.indices.contains(focused) else {
            // One subject: the comparison moves to the next photograph.
            let order = model.shownPhotos.map(\.url)
            guard let subject, let index = order.firstIndex(of: subject.photoFile) ?? order.firstIndex(of: subject), order.indices.contains(index + offset) else { return }
            setup.items = [order[index + offset]]
            lab.compare = setup
            model.click(order[index + offset])
            refresh()
            return
        }
        let order = model.shownPhotos.map(\.url)
        guard let index = order.firstIndex(of: setup.items[focused]) else { return }
        var target = index + offset
        while order.indices.contains(target), setup.items.contains(order[target]) { target += offset }
        guard order.indices.contains(target) else { return }
        setup.items[focused] = order[target]
        lab.compare = setup
        refresh()
    }

    // MARK: Deciding

    /// Marks the focused photograph: the comparison's point is the choice.
    func mark(_ flag: PhotoSidecar.Flag?) {
        guard panes.indices.contains(focused) else { return }
        let item = panes[focused].item
        let now = model.library.summary(for: item).flag
        model.setFlag(flag != nil && now == flag ? nil : flag, targets: [item])
    }

    /// Develops the photograph for good as the focused pane shows it.
    func adopt(_ pane: ComparePane) {
        if model.sourceItem != pane.item { model.open(pane.item) }
        if let film = pane.film { model.chooseFilm(film) }
        if let recipe = pane.recipe, let file = model.presets.first(where: { $0.url == recipe }) { model.applyPreset(file) }
        lab.show(.develop)
    }
}

// MARK: The room

struct CompareWorkspace: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        let compare = lab.compareModel
        VStack(spacing: 0) {
            CompareToolbar(model: model, compare: compare)
            ZStack {
                CompareCanvasHost(model: model, compare: compare)
                GeometryReader { geometry in
                    let split = lab.compare.kind == .beforeAfter
                    let rects = CompareGeometry.panes(split ? 1 : compare.panes.count, in: CGRect(origin: .zero, size: geometry.size))
                    if split, compare.panes.count == 2 {
                        HStack {
                            PaneTag(title: "Before", subtitle: compare.panes[0].subtitle, busy: compare.busy.contains(compare.panes[0].id))
                            Spacer()
                            PaneTag(title: "After", subtitle: compare.panes[1].subtitle, busy: compare.busy.contains(compare.panes[1].id))
                        }
                        .padding(12)
                    } else {
                        ForEach(Array(compare.panes.enumerated()), id: \.element.id) { index, pane in
                            if rects.indices.contains(index) {
                                PaneLabel(model: model, compare: compare, pane: pane, index: index)
                                    .frame(width: rects[index].width, height: rects[index].height, alignment: .topLeading)
                                    .offset(x: rects[index].minX, y: rects[index].minY)
                            }
                        }
                    }
                }
                if compare.panes.isEmpty { CompareEmpty(model: model, compare: compare) }
            }
            // Qlick Lab: the film strip, the parts' shared way through the photographs: ⌘-click or ⇧-click frames in
            // it and they're laid side by side; one chosen is the subject of Films, Recipes and Versions.
            // Shown and hidden as in Develop: the leader's arrow and ⌥⌘F (`filmstripVisible`).
            if !model.library.items.isEmpty {
                VStack(spacing: 0) {
                    if model.filmstripVisible { PhotoBrowser(model: model) }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    StripLeader(model: model).offset(y: -StripLeader.raised)
                }
            }
        }
        .background(Color(white: 0.035))
        .environment(\.colorScheme, .dark)
        .onAppear { compare.refresh() }
        .onChange(of: lab.compare) { _, _ in compare.refresh() }
        .onChange(of: model.selection.selected) { _, selected in
            if lab.compare.kind == .photographs {
                if selected.count >= 2 { lab.compare.items = lab.comparedSelection() }
            } else {
                compare.refresh()
            }
        }
        .onChange(of: model.thumbnailVersions) { _, _ in compare.invalidate() }
        .onChange(of: model.library.summaries) { _, _ in compare.push() }
    }
}

private struct CompareToolbar: View {
    let model: EditorModel
    let compare: CompareModel
    private var lab: LabState { model.lab }

    var body: some View {
        HStack(spacing: 10) {
            QSegmented(options: CompareSetup.Kind.allCases.map { ($0, $0.title, $0.help) },
                       selection: Binding(get: { lab.compare.kind }, set: { compare.setKind($0) }))
            Spacer(minLength: 8)
            // Qlick Lab: the background work, here as in the other rooms.
            BackgroundActivity(model: model)
            if lab.compare.kind == .photographs || lab.compare.kind == .versions { FileNamesMenu(lab: lab) }
            if lab.compare.kind != .beforeAfter {
                QIconButton(symbol: compare.linked ? "link" : "link.badge.plus", help: "Zoom and pan linked across the panes", active: compare.linked) {
                    compare.linked.toggle(); compare.push()
                }
            }
            Button("Fit") { compare.canvas?.zoomToFit() }.buttonStyle(QPillButtonStyle(active: abs((compare.canvas?.viewport.zoom ?? 1) - 1) < 0.001))
                .help("The whole photographs (double-click a photograph to go back to Develop)")
            Button("100 %") { compare.canvas?.zoomToActual() }.buttonStyle(QPillButtonStyle(active: abs(compare.magnification - 1) < 0.01))
                .help("One pixel of the develop for one pixel of the screen")
            // Zoom out below fitting, or in, from the middle; the wheel and a pinch zoom about the pointer.
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { log2(Double(compare.zoom)) }, set: { compare.canvas?.setZoom(CGFloat(pow(2, $0))) }), in: -2...5)
                    .controlSize(.mini).tint(Color(white: 0.75)).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            .help("Zoom: from a quarter of the fitted size to 32 times it")
            Text("\(Int((compare.magnification * 100).rounded())) %").font(Theme.value(11.5)).foregroundStyle(Theme.dim).frame(width: 46, alignment: .trailing)
            if compare.canAddPane {
                QIconButton(symbol: "plus.rectangle.on.rectangle", help: lab.compare.kind == .versions ? "New version of this photograph" : "Add a pane") { compare.addPane() }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(white: 0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

/// A pane's name, on glass at its corner, with what can be decided from here.
private struct PaneLabel: View {
    let model: EditorModel
    let compare: CompareModel
    let pane: ComparePane
    let index: Int
    private var lab: LabState { model.lab }

    var body: some View {
        let kind = lab.compare.kind
        let summary = model.library.summary(for: pane.item)
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                switch kind {
                case .films:
                    Menu {
                        ForEach(model.filmGroups) { group in
                            Section(group.title) {
                                ForEach(group.stocks) { stock in Button(stock.name) { compare.setFilm(stock.id, pane: index) } }
                            }
                        }
                    } label: { tagText(pane.title, chevron: true) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                case .recipes:
                    Menu {
                        ForEach(model.listedPresets) { preset in Button(preset.name) { compare.setRecipe(preset.url, pane: index) } }
                    } label: { tagText(pane.title, chevron: true) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                default:
                    // File Names Off: a photograph's pane shows its marks alone.
                    if lab.sheet.fileNames != .off || !(kind == .photographs || kind == .versions) { tagText(pane.title, chevron: false) }
                }
                if compare.busy.contains(pane.id) { ProgressView().controlSize(.mini) }
                if kind == .photographs || kind == .versions {
                    if let flag = summary.flag { MarkGlyph(flag: flag).frame(width: 17, height: 13) }
                    if summary.rating > 0 { Text(String(repeating: "★", count: summary.rating)).font(.system(size: 10)).foregroundStyle(Theme.paper) }
                    if ColorLabel.inInterface, let label = summary.label { LabelDot(label: label, size: 9).help(LabelNames.name(label)) }
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .glass(Capsule())
            // Names off and nothing marked: no empty tag.
            .opacity(emptyTag(kind, summary: summary) ? 0 : 1)
            Spacer()
            HStack(spacing: 6) {
                if kind == .photographs {
                    Button { compare.focused = index; compare.mark(.pick); compare.push() } label: { MarkGlyph(flag: .pick).frame(width: 18, height: 14) }
                        .buttonStyle(QPillButtonStyle()).help("Pick this frame (\(ShortcutStore.display(lab.keys.key(.pick))))")
                    Button { compare.focused = index; compare.mark(.reject); compare.push() } label: { MarkGlyph(flag: .reject).frame(width: 16, height: 14) }
                        .buttonStyle(QPillButtonStyle()).help("Reject this frame (\(ShortcutStore.display(lab.keys.key(.reject))))")
                    if lab.compare.items.count > 2 {
                        Button { compare.removePane(index) } label: { Image(systemName: "minus") }.buttonStyle(QPillButtonStyle()).help("Remove from the comparison")
                    }
                }
                Spacer()
                switch kind {
                case .films: Button("Develop on This Film") { compare.adopt(pane) }.buttonStyle(QPillButtonStyle())
                case .recipes: Button("Apply this recipe") { compare.adopt(pane) }.buttonStyle(QPillButtonStyle())
                case .photographs, .versions: Button("Develop") { compare.adopt(pane) }.buttonStyle(QPillButtonStyle())
                case .beforeAfter: EmptyView()
                }
            }
            .opacity(compare.focused == index || kind == .films || kind == .recipes ? 1 : 0.55)
        }
        .padding(12)
    }

    private func emptyTag(_ kind: CompareSetup.Kind, summary: LibrarySummary) -> Bool {
        (kind == .photographs || kind == .versions) && lab.sheet.fileNames == .off && summary.flag == nil && summary.rating == 0
            && summary.label == nil && !compare.busy.contains(pane.id)
    }

    private func tagText(_ title: String, chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title).font(Theme.caps(12, weight: .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim) }
        }
    }
}

private struct PaneTag: View {
    let title: String
    let subtitle: String
    let busy: Bool
    var body: some View {
        VStack {
            HStack(spacing: 7) {
                CapsLabel(title, size: 10.5, color: Theme.paper)
                if !subtitle.isEmpty { Text(subtitle).font(Theme.caps(11)).foregroundStyle(Theme.dim).lineLimit(1) }
                if busy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 11).frame(height: 28)
            .glass(Capsule())
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

private struct CompareEmpty: View {
    let model: EditorModel
    let compare: CompareModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.faint)
            Text(model.lab.compare.kind == .recipes && model.presets.isEmpty ? "No recipes to compare" : "Nothing to compare yet")
                .font(Theme.title(17)).foregroundStyle(Theme.paper)
            Text(model.lab.compare.kind == .recipes && model.presets.isEmpty
                 ? "First save a development as a recipe, in Develop or Recipes."
                 : "Open a folder or a Box, select frames on the contact sheet, then come back here.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            if model.source != nil { Button("Contact Sheet") { model.lab.show(.contactSheet) }.buttonStyle(QPillButtonStyle()) }
        }
        .padding(30)
    }
}

struct CompareCanvasHost: NSViewRepresentable {
    let model: EditorModel
    let compare: CompareModel

    func makeNSView(context: Context) -> CompareCanvas {
        let canvas = CompareCanvas()
        compare.canvas = canvas
        canvas.onFocus = { [weak compare] in compare?.focused = $0 }
        canvas.onOpen = { [weak compare, weak model] pane in
            guard let compare, let model, compare.panes.indices.contains(pane) else { return }
            let item = compare.panes[pane].item
            if model.sourceItem != item { model.open(item) }
            model.lab.show(.develop)
        }
        canvas.onViewport = { [weak compare, weak canvas] viewport in compare?.magnification = canvas?.magnification ?? 1; compare?.zoom = viewport.zoom }
        canvas.onSplit = { [weak compare] in compare?.split = $0 }
        canvas.onKey = { [weak compare, weak model] event in
            guard let compare, let model else { return false }
            return Self.key(event, compare: compare, model: model)
        }
        compare.push()
        DispatchQueue.main.async { canvas.window?.makeFirstResponder(canvas) }
        return canvas
    }

    func updateNSView(_ canvas: CompareCanvas, context: Context) {}

    /// ← → move the focus between panes; ⌥← ⌥→ walk the focused pane through the roll; the pencil's keys mark it.
    @MainActor static func key(_ event: NSEvent, compare: CompareModel, model: EditorModel) -> Bool {
        let modifiers = event.modifierFlags
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        switch event.keyCode {
        case 123, 124:
            let offset = event.keyCode == 123 ? -1 : 1
            if modifiers.contains(.option) || model.lab.compare.kind != .photographs { compare.step(by: offset) }
            else { compare.focused = min(max(compare.focused + offset, 0), max(compare.panes.count - 1, 0)); compare.push() }
            return true
        case 53: model.lab.show(model.mode == .grid ? .contactSheet : .develop); return true
        default: break
        }
        guard let action = model.lab.keys.action(for: event) else { return false }
        switch action {
        case .pick: compare.mark(.pick)
        case .reject: compare.mark(.reject)
        case .unmark: compare.mark(nil)
        case .develop: if compare.panes.indices.contains(compare.focused) { compare.adopt(compare.panes[compare.focused]) }
        case .loupe: (compare.canvas?.viewport.zoom ?? 1) <= 1.001 ? compare.canvas?.zoomToActual() : compare.canvas?.zoomToFit()
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: model.lab.menuLabel(action.label)
        default: return false
        }
        compare.push()
        return true
    }
}
