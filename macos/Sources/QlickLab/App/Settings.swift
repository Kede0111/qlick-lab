import AppKit
import SwiftUI

// Settings: the title band over a row of tabs, each a pictogram over its word (Photographs, Lab, Upkeep,
// Shortcuts, About), each page a few sections of the inspector's rows with a line saying what each does.
// The window fits its page's height.

/// Settings' pages, in the order of their tabs.
enum SettingsTab: String, CaseIterable {
    /// What a new photograph starts with, and how edits are kept.
    case photographs = "Photographs"
    /// The lab around the photograph: surfaces, the viewer, Rolls.
    case lab = "Lab"
    /// What the lab prepares by itself and the room it takes.
    case upkeep = "Upkeep"
    /// Every key, in one list.
    case shortcuts = "Shortcuts"
    /// The version, updates, the lab's pages.
    case about = "About"

    var symbol: String {
        switch self {
        case .photographs: "photo.on.rectangle"
        case .lab: "slider.horizontal.3"
        case .upkeep: "externaldrive"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}

/// A Settings tab: its pictogram over its word, red when chosen.
private struct SettingsTabButton: View {
    let tab: SettingsTab
    let chosen: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 16, weight: .regular)).frame(height: 20)
                Text(tab.rawValue.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
            }
            .foregroundStyle(chosen ? Theme.accent : hovered ? Theme.paper : Theme.dim)
            .frame(width: 84, height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(chosen ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
    }
}

/// The Settings window: Newsreader's title in the 38 pt band over the tabs,
/// no toolbar, and the keyboard focus box rather than the system's ring.
@MainActor final class SettingsWindowController: NSWindowController {
    static let width: CGFloat = 520
    private let band = TitleBand()
    private let host: NSHostingView<SettingsView>

    init(updates: UpdateController, model: EditorModel) {
        host = NSHostingView(rootView: SettingsView(updates: updates, model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.identifier = InkKeyLoop.inspectorIdentifier
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // As in the editing window: an empty compact toolbar puts the
        // traffic lights in the middle of the 38 pt band.
        let toolbar = NSToolbar(identifier: "settings-title")
        toolbar.allowsUserCustomization = false
        if #available(macOS 15, *) { toolbar.allowsDisplayModeCustomization = false }
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = Theme.NS.panel
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        band.title = "Settings"
        let frame = EditorFrameView(band: band, content: host)
        frame.layer?.backgroundColor = Theme.NS.panel.cgColor
        frame.addSubview(host)
        frame.addSubview(band)
        window.contentView = frame
        super.init(window: window)
        host.rootView.resize = { [weak self] height in self?.fit(contentHeight: height) }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sizes the window to the page under the band, keeping its top edge
    /// where it is, as the system's Settings windows do between panes.
    private func fit(contentHeight: CGFloat) {
        guard let window else { return }
        let content = NSSize(width: Self.width, height: ceil(contentHeight) + Theme.Size.titleBar)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// Notes keyboard use for the focus box, and Tab from nothing focused
/// moves to the page's first control (⇧Tab its last), as in the inspector.
@MainActor final class SettingsWindow: NSWindow {
    /// Opens with nothing focused: AppKit would give the first tab the keys,
    /// and with them the focus box, before anyone pressed Tab.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let opening = !isVisible
        super.makeKeyAndOrderFront(sender)
        if opening { makeFirstResponder(nil) }
    }

    override func sendEvent(_ event: NSEvent) {
        InputMode.shared.note(event)
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
           !(firstResponder is NSText), (firstResponder as? NSView).flatMap(InkKeyLoop.root(of:)) == nil,
           let root = (contentView as? EditorFrameView)?.content,
           InkKeyLoop.advance(in: root, from: nil, forward: !event.modifierFlags.contains(.shift)) { return }
        super.sendEvent(event)
    }
}

struct SettingsView: View {
    @AppStorage("qlick.scrollZoom") private var scrollZoom = CanvasScale.ScrollZoom.always.rawValue
    @AppStorage(SidecarStorage.defaultsKey) private var dngStorage = SidecarStorage.insideDNG.rawValue
    @ObservedObject var updates: UpdateController
    var model: EditorModel
    /// Called with the page's height, for the window to fit it.
    var resize: (CGFloat) -> Void = { _ in }
    @AppStorage("settingsTab") private var tab = SettingsTab.photographs
    @AppStorage(ViewerSheet.key) private var sheet = ViewerSheet.darkroom
    @AppStorage(Theme.solidKey) private var solid = false
    @AppStorage(LabState.oneStockKey) private var oneStock = false
    @State private var thumbnailBytes: Int?
    @State private var emptyingThumbnails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    SettingsTabButton(tab: item, chosen: tab == item) { tab = item }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { InkRule() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings tabs")
            switch tab {
            case .photographs: photographs
            case .lab: labPage
            case .upkeep: upkeep
            case .shortcuts: ShortcutSettings(keys: model.lab.keys, menus: .shared)
            case .about: about
            }
        }
        .frame(width: SettingsWindowController.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { resize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Photographs: what a new photograph starts with, and what it lies on

    @ViewBuilder private var photographs: some View {
        let slide = model.films.first { $0.id == model.newPhotoFilm }?.positive ?? false
        InkSection(title: "New photographs") {
            ChoiceRow(title: "Film", items: Self.items(StockGroup.films(model.listedFilms(keeping: [model.newPhotoFilm]), papers: model.papers)),
                      selection: model.newPhotoFilm) { model.setNewPhotoFilm($0) }
                .inkDisabled(model.films.isEmpty)
            if slide {
                // A slide is scanned, without a paper: struck through, as under the photograph.
                StruckRow(title: "Paper", value: model.papers.first { $0.id == model.newPhotoPaper }?.name ?? model.newPhotoPaper)
                HintText("not printed — scanning the film")
            } else {
                ChoiceRow(title: "Paper", items: Self.items(model.paperGroups), selection: model.newPhotoPaper) { model.setNewPhotoPaper($0) }
                    .inkDisabled(model.papers.isEmpty)
            }
            HintText("For photographs you haven’t edited yet.")
            TickRow(title: "Match to camera brightness", isOn: Binding(
                get: { model.autoPlaceNewImages }, set: { model.autoPlaceNewImages = $0 }))
            HintText("Starts each photograph about as bright as the camera’s own preview.")
        }
        InkSection(title: "Changing film") {
            TickRow(title: "Keep paper when changing film", isOn: Binding(
                get: { model.previews.keepPaper }, set: { model.setKeepPaper($0) }))
        }
        InkSection(title: "Edits") {
            TickRow(title: "Save ratings and edits next to photos", isOn: Binding(
                get: { model.sidecarsEnabled }, set: { model.sidecarsEnabled = $0 }))
            HintText(model.sidecarsEnabled
                     ? "In a small .qlick file beside each photograph."
                     : "Ratings and edits won’t be saved.")
            if model.sidecarsEnabled {
                ChoiceRow(title: "DNG photos", items: SidecarStorage.allCases.map { .option($0.title, tag: $0.rawValue) },
                          selection: dngStorage) { dngStorage = $0 }
                HintText(dngStorage == SidecarStorage.insideDNG.rawValue
                         ? "In the DNG’s own metadata, where other apps read the stars and marks. The image itself is never changed."
                         : "In a .qlick file beside the DNG, like every other photograph.")
            }
        }
        if ColorLabel.inInterface { InkSection(title: "Colour labels") {
            ForEach(ColorLabel.allCases) { label in LabelNameRow(label: label) }
            HintText("Your own name for each colour (“To print”, “For the client”). Empty, the colour’s name. Photographs keep the colour, not the name.")
        } }
    }

    // MARK: Lab: the lab around the photograph

    @ViewBuilder private var labPage: some View {
        InkSection(title: "Rolls") {
            TickRow(title: "One film stock per Roll", isOn: $oneStock,
                    help: "A Roll keeps the film or recipe loaded from its menu, and every photograph put in it later takes it, as on a real roll.")
            HintText("Right-click a Roll to load a film or a recipe on it. For a second look, put the photographs in another Roll.")
        }
        InkSection(title: "Interface") {
            TickRow(title: "Solid surfaces", isOn: $solid,
                    help: "The panels, the selector and the sidebar on black, without transparency.")
            HintText("Nothing shows through the panels, the selector or the sidebar: they sit on the lab’s black.")
        }
        InkSection(title: "Viewer") {
            ChoiceRow(title: "Sheet", items: ViewerSheet.allCases.map { .option($0.title, tag: $0.rawValue) },
                      selection: sheet.rawValue) { sheet = ViewerSheet(rawValue: $0) ?? .darkroom }
            HintText("The colour behind the photograph.")
            // Qlick Lab: what scrolling over the photograph does.
            ChoiceRow(title: "Scrolling", items: [.option("Zooms", tag: CanvasScale.ScrollZoom.always.rawValue),
                                                  .option("Zooms with a mouse wheel", tag: CanvasScale.ScrollZoom.wheel.rawValue),
                                                  .option("Moves the photograph", tag: CanvasScale.ScrollZoom.option.rawValue)],
                      selection: scrollZoom) { scrollZoom = $0; CanvasScale.scrollZoom = CanvasScale.ScrollZoom(rawValue: $0) ?? .always }
            HintText("⌥ always zooms.")
        }
    }

    // MARK: Upkeep: what the lab prepares by itself, the room it takes, updates

    @ViewBuilder private var upkeep: some View {
        InkSection(title: "Previews") {
            TickRow(title: "Build previews ahead", isOn: Binding(
                get: { model.lab.previewBuilder.automatic }, set: { model.lab.previewBuilder.automatic = $0 }))
            HintText("Developed in the background, so photographs open at once.")
            TickRow(title: "Film, paper and recipe previews", isOn: Binding(
                get: { model.previews.enabled }, set: { model.setPreviews($0) }))
            HintText("Shown on your own photograph. Turn off on a slower computer.")
            TickRow(title: "Limit preview to 12 MP", isOn: Binding(
                get: { model.limitsPreview }, set: { model.limitsPreview = $0 }))
            HintText("Faster and lighter on large photographs. Export keeps the full size.")
        }
        InkSection(title: "Export") {
            TickRow(title: "Use less memory for export", isOn: Binding(
                get: { model.lowMemoryExport }, set: { model.lowMemoryExport = $0 }))
            HintText("Same result, longer export.")
        }
        InkSection(title: "Thumbnails") {
            TickRow(title: "Develop thumbnails ahead", isOn: Binding(
                get: { model.thumbnailsAhead }, set: { model.thumbnailsAhead = $0 }))
            HintText("Off, only the frames on screen are developed; the others show the camera's picture until they're shown.")
            ButtonRow {
                FigureText(figure: thumbnailBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…", trail: "of 1 GB")
            } button: {
                Button("Empty Thumbnail Cache") {
                    Task {
                        emptyingThumbnails = true
                        await model.emptyThumbnailCache()
                        thumbnailBytes = await model.thumbnailCacheSize()
                        emptyingThumbnails = false
                    }
                }
                .buttonStyle(OutlinedButtonStyle())
                .inkDisabled(emptyingThumbnails || thumbnailBytes == 0)
            }
            ButtonRow {
                Text(model.editedThumbnails.directory.path).font(.system(size: 11)).foregroundStyle(Theme.dim)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            } button: {
                Button("Show in Finder") {
                    let folder = model.editedThumbnails.directory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(OutlinedButtonStyle())
            }
        }
        .task { thumbnailBytes = await model.thumbnailCacheSize() }
        // Qlick Lab: the previews built ahead: where, how much room, emptied.
        PreviewStorageSection(model: model)
    }

    // MARK: About: the version, updates, the lab's pages

    @ViewBuilder private var about: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text(info["CFBundleName"] as? String ?? "Qlick Lab").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.paper)
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "–") (\(info["CFBundleVersion"] as? String ?? "–"))")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim).textSelection(.enabled)
            Text("Develops digital photographs as a film lab would, by the spectral simulation of real stocks.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.label).multilineTextAlignment(.center).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        InkRule()
        InkSection(title: "Updates") {
            if updates.configured {
                TickRow(title: "Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                ButtonRow {
                    if let lastCheck = updates.lastCheck {
                        FigureText(lead: "Last checked", figure: lastCheck.formatted(date: .abbreviated, time: .shortened))
                    }
                } button: {
                    Button("Check for Updates…", action: updates.check).buttonStyle(OutlinedButtonStyle())
                        .inkDisabled(!updates.canCheck)
                }
                if let error = updates.configurationError { HintText(error, warning: true) }
            } else {
                ReadoutRow(title: "Updates are not configured for this build.", value: "")
                HintText("Install a release build to receive updates.")
            }
        }
        InkSection(title: "The lab") {
            ButtonRow {
                Text("Its source, its versions, a problem to report").font(Theme.serif(14.5)).foregroundStyle(Theme.label)
            } button: {
                Button("Open the Lab’s Page") { NSWorkspace.shared.open(Support.repositoryURL) }.buttonStyle(OutlinedButtonStyle())
            }
            HintText("Qlick Lab is free and open source (GPL-3.0). Support Qlick Lab… in the app’s menu, if you’d like to.")
        }
    }

    /// A stock menu's items, one section per group.
    static func items(_ groups: [StockGroup]) -> [ChoiceItem] {
        groups.flatMap { group in [ChoiceItem.header(group.title)] + group.stocks.map { .option($0.name, tag: $0.id) } }
    }
}

/// A row whose value can't be chosen now: struck through in pencil, in `dim`.
private struct StruckRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(title: title)
            Spacer(minLength: 8)
            Text(value).font(Theme.serif(14.5)).foregroundStyle(Theme.dim).lineLimit(1)
                .overlay { PencilStroke().pencil().frame(height: 5).offset(y: 1) }
        }
        .padding(.horizontal, Theme.Size.gutter)
        .frame(height: Theme.Size.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), not printed, scanning the film")
    }
}

/// Something to read at the row's start and an outlined button at its end.
struct ButtonRow<Lead: View, Trailing: View>: View {
    @ViewBuilder let lead: Lead
    @ViewBuilder let button: Trailing

    var body: some View {
        HStack(spacing: 8) {
            lead
            Spacer(minLength: 8)
            button
        }
        .padding(.horizontal, Theme.Size.gutter)
        .frame(minHeight: Theme.Size.row)
    }
}

/// A figure in the serif, with words before or after it in `dim` italic:
/// "*Last checked* 10 Nov 2026, 21:14", "4,9 MB *of 1 GB*".
struct FigureText: View {
    var lead: String? = nil
    let figure: String
    var trail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let lead { Text(lead).font(Theme.serif(14.5, italic: true)).foregroundStyle(Theme.dim) }
            Text(figure).font(Theme.serif(14.5)).foregroundStyle(Theme.paper)
            if let trail { Text(trail).font(Theme.serif(14.5, italic: true)).foregroundStyle(Theme.dim) }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// A colour label's own name, in Settings: its sticker, then the name typed, the colour's name until one is.
private struct LabelNameRow: View {
    let label: ColorLabel
    @State private var name = ""

    var body: some View {
        ButtonRow {
            LabelDot(label: label, size: 12)
            Text(label.standardName).font(Theme.serif(14.5)).foregroundStyle(Theme.label).frame(width: 70, alignment: .leading)
        } button: {
            TextField(label.standardName, text: $name)
                .textFieldStyle(.plain).font(Theme.serif(14.5)).foregroundStyle(Theme.paper)
                .padding(.horizontal, 8).frame(width: 220, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                .onSubmit { LabelNames.set(name, for: label) }
                .onChange(of: name) { _, new in LabelNames.set(new, for: label) }
        }
        .onAppear { name = LabelNames.own(label) }
    }
}
