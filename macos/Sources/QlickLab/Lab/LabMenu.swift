// Qlick Lab — GPL-3.0-only.
import AppKit

/// The lab's own menu, beside NEgs's: its rooms, projects, the contact sheet's print and tools.
@MainActor final class LabMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let model: EditorModel
    private var lab: LabState { model.lab }
    let menu = NSMenu(title: "Lab")

    init(model: EditorModel) {
        self.model = model
        super.init()
        for room in Workspace.ordered {
            let item = add(room.title, #selector(showRoom(_:)), room.key, [.command, .option])
            item.representedObject = room.rawValue
        }
        menu.addItem(.separator())
        add("New Project…", #selector(newProject), "n", [.command, .shift])
        add("Add Folders in Place…", #selector(importFolder), "i", [.command, .shift])
        menu.addItem(.separator())
        // The catalog's commands, also in File, where their keys are.
        add("New Catalog…", #selector(newCatalog), "")
        add("Open Catalog…", #selector(openCatalog), "")
        add("Save Catalog", #selector(saveCatalog), "")
        add("Save Catalog As…", #selector(saveCatalogAs), "")
        menu.addItem(.separator())
        add("Print Contact Sheet…", #selector(printSheet), "p")
        add("Compare Selection", #selector(compare), "")
        add("Before / After", #selector(beforeAfter), "b", [.command, .option])
        add("See Larger", #selector(loupe), "")
        menu.addItem(.separator())
        add("Build Previews for Selection", #selector(buildSelected), "")
        add("Build All Previews", #selector(buildAll), "")
        menu.addItem(.separator())
        add("Red Pencil", #selector(togglePencil), "")
        add("Light Table", #selector(toggleLightTable), "l", [.command, .shift, .option])
        add("Frame Information", #selector(toggleInfo), "i", [.command, .control])
        menu.addItem(.separator())

    }

    /// File's catalog commands: New, Open, Open Recent, Save and Save As, with their keys.
    func addCatalogItems(to file: NSMenu) {
        for (title, action, key, modifiers) in [("New Catalog…", #selector(newCatalog), "n", NSEvent.ModifierFlags([.command, .option, .shift])),
                                                ("Open Catalog…", #selector(openCatalog), "o", [.command, .option, .shift])] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self
        }
        let recent = file.addItem(withTitle: "Open Recent Catalog", action: nil, keyEquivalent: "")
        recent.submenu = recentCatalogs
        recentCatalogs.delegate = self
        for (title, action, key, modifiers) in [("Save Catalog", #selector(saveCatalog), "s", NSEvent.ModifierFlags([.command, .option])),
                                                ("Save Catalog As…", #selector(saveCatalogAs), "s", [.command, .option, .shift])] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self
        }
    }

    /// View's panels: the toolbar, the sidebar, the film strip and the adjustments.
    func addPanelItems(to view: NSMenu) {
        for (title, action, key, modifiers) in [("Show Toolbar", #selector(toggleToolbar), "t", NSEvent.ModifierFlags([.command, .option])),
                                                ("Show Sidebar", #selector(toggleSidebar), "s", [.command, .control]),
                                                ("Show Film Strip", #selector(toggleStrip), "f", [.command, .option]),
                                                ("Show Adjustments", #selector(toggleAdjustments), "i", [.command, .option]),
                                                ("Show Filter Bar", #selector(toggleFilterBar), "", []),
                                                ("Floating Panel", #selector(toggleFloating), "", [])] {
            let item = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
    }
    /// View's information: the metadata panel, and what the caption over the photograph shows.
    func addInformationItems(to view: NSMenu) {
        let info = view.addItem(withTitle: "Photograph Information", action: #selector(togglePhotoInfo), keyEquivalent: "i")
        info.target = self
        let caption = view.addItem(withTitle: "Caption", action: nil, keyEquivalent: "")
        caption.submenu = lab.captionCommands.makeMenu()
    }
    @objc private func togglePhotoInfo() { lab.infoVisible.toggle() }
    @objc private func toggleToolbar() { lab.toolbarVisible.toggle() }
    @objc private func toggleFloating() { lab.floatingPanel.toggle() }
    @objc private func toggleFilterBar() { lab.filterBarVisible.toggle() }
    @objc private func toggleStrip() { model.toggleFilmstrip() }
    @objc private func toggleAdjustments() { model.togglePane(.adjustments) }

    @discardableResult private func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func showRoom(_ item: NSMenuItem) { if let room = (item.representedObject as? String).flatMap(Workspace.init) { lab.show(room) } }
    @objc private func newProject() { lab.naming = LabState.ProjectNaming(name: lab.projects.uniqueName("New Project")); if lab.workspace == .develop { lab.show(.library) } }
    @objc private func importFolder() { lab.importPanel() }
    @objc private func newCatalog() { lab.newCatalogPanel() }
    @objc private func openCatalog() { lab.openCatalogPanel() }
    @objc private func saveCatalogAs() { lab.saveCatalogAsPanel() }
    @objc private func saveCatalog() { lab.saveCatalog() }
    @objc private func openRecentCatalog(_ item: NSMenuItem) { if let url = item.representedObject as? URL { lab.openCatalog(url) } }
    private let recentCatalogs = NSMenu(title: "Open Recent Catalog")

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentCatalogs else { return }
        menu.removeAllItems()
        let current = lab.projects.directory.standardizedFileURL
        for url in [CatalogList.defaultDirectory] + lab.catalogs.recent {
            let item = menu.addItem(withTitle: CatalogList.name(of: url), action: #selector(openRecentCatalog(_:)), keyEquivalent: "")
            item.representedObject = url; item.target = self
            item.state = url.standardizedFileURL == current ? .on : .off
            item.toolTip = url.path
        }
    }
    @objc private func printSheet() { if lab.workspace != .contactSheet { lab.show(.contactSheet) }; lab.printing = true }
    @objc private func compare() { lab.compareSelection() }
    @objc private func beforeAfter() {
        guard let item = model.selection.current ?? model.sourceItem else { return }
        lab.compare.items = [item]
        lab.show(.compare); lab.compareModel.setKind(.beforeAfter)
    }
    @objc private func buildSelected() { lab.previewBuilder.build(model.ratingTargets) }
    @objc private func buildAll() { lab.previewBuilder.build(model.library.items.map(\.url)) }
    @objc private func loupe() { if let current = model.selection.current { lab.loupe = lab.loupe == nil ? current : nil } }
    @objc private func togglePencil() { lab.sheet.tool = lab.sheet.tool == .pencil ? .pointer : .pencil }
    @objc private func toggleLightTable() { lab.sheet.lightTable.toggle() }
    @objc private func toggleInfo() { lab.sheet.showInfo.toggle() }
    @objc private func toggleSidebar() { lab.sidebarVisible.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard model.alert == nil else { return false }
        let sheet = lab.workspace == .contactSheet, photo = model.source != nil
        switch item.action {
        case #selector(showRoom(_:)):
            let room = (item.representedObject as? String).flatMap(Workspace.init)
            item.state = room == lab.workspace ? .on : .off
            return !model.cropping || room == .develop
        case #selector(printSheet): return photo && !model.library.files.isEmpty
        case #selector(compare), #selector(beforeAfter): return photo && !model.cropping
        case #selector(loupe): return sheet && model.selection.current != nil
        case #selector(togglePencil): item.state = lab.sheet.tool == .pencil ? .on : .off; return sheet
        case #selector(toggleLightTable): item.state = lab.sheet.lightTable ? .on : .off; return sheet
        case #selector(toggleInfo): item.state = lab.sheet.showInfo ? .on : .off; return sheet
        case #selector(toggleSidebar): item.state = lab.sidebarVisible ? .on : .off; return true
        case #selector(togglePhotoInfo):
            item.state = lab.infoVisible ? .on : .off
            return photo && lab.workspace == .develop && model.mode == .photo
        case #selector(toggleToolbar): item.state = lab.toolbarVisible ? .on : .off; return true
        case #selector(toggleFloating): item.state = lab.floatingPanel ? .on : .off; return true
        case #selector(toggleFilterBar): item.state = lab.filterBarVisible ? .on : .off; return true
        case #selector(toggleStrip): item.state = model.filmstripVisible ? .on : .off; return true
        case #selector(toggleAdjustments): item.state = model.inspectorVisible && model.inspectorPane == .adjustments ? .on : .off; return true
        default: return true
        }
    }
}

extension LabState {
    /// The rooms where the photograph's keys (ratings, marks) have a photograph to act on.
    var takesPhotoKeys: Bool { [.develop, .contactSheet, .compare].contains(workspace) }

    /// The Photo menu's Pick, Reject and Unflagged: on the sheet the pencil's key lifts a mark it finds on every
    /// selected frame; in Comparaison it marks the pane the keys are on.
    func menuMark(_ flag: PhotoSidecar.Flag?) {
        switch workspace {
        case .importer: if let flag { importer.toggle(flag: flag.rawValue) } else { importer.unmark() }
        case .compare: compareModel.mark(flag); compareModel.push()
        case .contactSheet: if let flag { toggleMark(flag) } else { model.setFlag(nil) }
        default: model.setFlag(flag)
        }
    }

    func menuRate(_ stars: Int) {
        if workspace == .importer { return importer.rate(stars) }
        if workspace == .compare, compareModel.panes.indices.contains(compareModel.focused) {
            model.setRating(stars, targets: [compareModel.panes[compareModel.focused].item])
        } else {
            model.setRating(stars)
        }
    }
}
