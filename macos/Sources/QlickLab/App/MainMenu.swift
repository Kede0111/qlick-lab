import AppKit
import SwiftUI

/// The menu bar. The standard items go to the responder chain; the app's own
/// commands go to the model, and are enabled and titled from its state when a
/// menu opens.
@MainActor final class MainMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    let menu = NSMenu()
    private let model: EditorModel
    private let updates: UpdateController
    private let recent = NSMenu(title: "Open Recent")
    private var settings: SettingsWindowController?
    // Qlick Lab
    private lazy var labMenu = LabMenu(model: model)
    private var flagItems: [NSMenuItem] = []
    /// Photo › Add to Box: the Boxes and Rolls, listed as the menu opens.
    private let boxes = NSMenu(title: "Add to Box")
    /// The pencil's keys are the photographer's (Réglages › Raccourcis).
    private func applyShortcuts() {
        let keys = model.lab.keys
        for (item, action) in zip(flagItems, [SheetAction.pick, .reject, .unmark]) { item.keyEquivalent = keys.key(action) }
        for (item, label) in labelItems { if let action = label.action { item.keyEquivalent = keys.key(action) } }
    }
    private var labelItems: [(NSMenuItem, ColorLabel)] = []

    static func dot(_ label: ColorLabel) -> NSImage { MainMenuDots.dot(label) }
    init(model: EditorModel, updates: UpdateController) {
        self.model = model
        self.updates = updates
        super.init()
        let name = "Qlick Lab"
        model.lab.openSettings = { [weak self] in self?.showSettings() }

        let app = submenu(name)
        command(app, "About \(name)", #selector(showAbout), "")
        command(app, "Check for Updates…", #selector(checkForUpdates), "")
        command(app, "Support \(name)…", #selector(supportTheLab), "")
        app.addItem(.separator())
        command(app, "Settings…", #selector(showSettings), ",")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        command(file, "Open…", #selector(openPhotograph), "o")
        // The action only lets validation disable the submenu while it's empty.
        let recentItem = file.addItem(withTitle: "Open Recent", action: #selector(showRecent), keyEquivalent: "")
        recentItem.target = self
        recentItem.submenu = recent
        recent.delegate = self
        file.addItem(.separator())
        // Qlick Lab: the catalogs, in File.
        labMenu.addCatalogItems(to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        command(file, "Save Preview…", #selector(savePreview), "s")
        command(file, "Export Photograph…", #selector(exportPhotograph), "e", [.command, .shift])
        command(file, "Export LUT…", #selector(exportLUT), "l", [.command, .shift])
        file.addItem(.separator())
        command(file, "New Recipe", #selector(newPreset), "s", [.command, .shift])
        command(file, "Import Recipes…", #selector(importPresets), "o", [.command, .shift])
        command(file, "Show Recipes Folder", #selector(showPresetsFolder), "")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        // Without a text field or view taking them, ⌘C and ⌘V copy and paste
        // the photograph's edits: `EditorWindowController.copy(_:)`.
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // The window selects photographs when no text field takes it.
        edit.addItem(withTitle: "Deselect All", action: #selector(EditorWindowController.deselectAll(_:)), keyEquivalent: "a")
            .keyEquivalentModifierMask = [.command, .option]

        let view = submenu("View")
        // Qlick Lab: the window's panels, shown or hidden.
        labMenu.addPanelItems(to: view)
        labMenu.addInformationItems(to: view)
        view.addItem(.separator())
        // Plain keys, behind the same check as the rating keys.
        command(view, "Edit Photograph", #selector(editPhotograph), "e", [])
        hidden(view, #selector(editPhotograph), "\r")
        // G: one key between Develop and the contact sheet, in the part chosen.
        command(view, "Show Contact Sheet", #selector(showGrid), "g", [])
        // Esc shows the grid too: `EditorWindowController.escapeToGrid`.
        command(view, "Larger Thumbnails", #selector(largerThumbnails), "+")
        hidden(view, #selector(largerThumbnails), "=", .command)
        command(view, "Smaller Thumbnails", #selector(smallerThumbnails), "-")
        view.addItem(.separator())
        // A plain key too: the photograph with only its caption and label.
        // Esc leaves it first: `EditorWindowController.escapeToGrid`.
        command(view, "Image Only", #selector(toggleImageOnly), "f", [])
        // Every control in every module, as the Lab's Advanced controls switch did.
        command(view, "Show All Controls", #selector(toggleAllControls), "")
        view.addItem(.separator())
        command(view, "Fit Photograph", #selector(fitPhotograph), "0")
        // ⇧⌘1 (one to one): ⌘1, ⌘2, ⌘3 choose Library, Lab and Print.
        command(view, "Actual Size", #selector(actualSize), "1", [.command, .shift])
        // Rotate lives in cropping (§4.10); from here it starts cropping.
        command(view, "Rotate Clockwise", #selector(rotate), "r")
        command(view, "Rotate Counterclockwise", #selector(rotateLeft), "r", [.command, .option])
        // Qlick Lab: R, as the habit is; ⌘K adds a keyword.
        command(view, "Crop", #selector(crop), "r", [])
        command(view, "Straighten Automatically", #selector(autoStraighten), "")
        view.addItem(.separator())
        // ⇧⌘R is Photo › Reset Edits.
        command(view, "Reset All Adjustments", #selector(resetAdjustments), "")
        view.addItem(.separator())

        // Plain keys. Disabled while text is
        // typed, so a number typed into a field never rates the photograph.
        let photo = submenu("Photo")
        let rating = NSMenu(title: "Rating")
        photo.addItem(withTitle: "Rating", action: nil, keyEquivalent: "").submenu = rating
        for stars in 0...5 {
            let item = rating.addItem(withTitle: stars == 0 ? "None" : String(repeating: "★", count: stars),
                                      action: #selector(rate(_:)), keyEquivalent: "\(stars)")
            item.keyEquivalentModifierMask = []; item.tag = stars; item.target = self
            if stars == 0 { rating.addItem(.separator()) }
        }
        rating.addItem(.separator())
        command(rating, "Raise Rating", #selector(raiseRating), "]", [])
        command(rating, "Lower Rating", #selector(lowerRating), "[", [])
        let flag = NSMenu(title: "Flag")
        photo.addItem(withTitle: "Flag", action: nil, keyEquivalent: "").submenu = flag
        command(flag, "Pick", #selector(pick), "p", [])
        command(flag, "Reject", #selector(reject), "x", [])
        command(flag, "Unflagged", #selector(unflag), "u", [])
        flagItems = Array(flag.items.suffix(3))
        // Qlick Lab: colour labels (6 to 9 by default, purple in the menu only) and keywords.
        let labels = NSMenu(title: "Colour Label")
        if ColorLabel.inInterface { photo.addItem(withTitle: "Colour Label", action: nil, keyEquivalent: "").submenu = labels }
        for (index, label) in ColorLabel.allCases.enumerated() where ColorLabel.inInterface {
            let item = labels.addItem(withTitle: label.standardName, action: #selector(colorLabel(_:)), keyEquivalent: "")
            item.keyEquivalentModifierMask = []; item.tag = index + 1; item.target = self
            item.image = Self.dot(label)
            if label.action != nil { labelItems.append((item, label)) }
        }
        labels.addItem(.separator())
        let none = labels.addItem(withTitle: "None", action: #selector(colorLabel(_:)), keyEquivalent: "")
        none.tag = 0; none.target = self
        let keywords = NSMenu(title: "Keywords")
        photo.addItem(withTitle: "Keywords", action: nil, keyEquivalent: "").submenu = keywords
        // Qlick Lab: the keywords are written in the information card (no keyword set on keys).
        command(keywords, "Add Keyword…", #selector(addKeyword), "k")
        photo.addItem(.separator())
        command(photo, "Copy Edits", #selector(copyEdits), "c", [.command, .shift])
        command(photo, "Copy Edits…", #selector(copyEditsChoosing), "c", [.command, .shift, .option])
        command(photo, "Paste Edits", #selector(pasteEdits), "v", [.command, .shift])
        command(photo, "Paste from Previous", #selector(pasteFromPrevious), "v", [.command, .shift, .option])
        photo.addItem(.separator())
        // Qlick Lab: the Boxes. ⇧⌘B lists them at the pointer; the key comes before the submenu so it's the one found.
        hidden(photo, #selector(chooseBox), "b", [.command, .shift])
        let boxesItem = photo.addItem(withTitle: "Add to Box", action: #selector(showBoxes), keyEquivalent: "")
        boxesItem.target = self
        boxesItem.submenu = boxes
        boxes.delegate = self
        command(photo, "New Box from Selection…", #selector(newBoxFromSelection), "")
        command(photo, "Remove from Box", #selector(removeFromBox), "")
        photo.addItem(.separator())
        // Qlick Lab: stacks (a burst under its first frame).
        command(photo, "Stack", #selector(stackPhotos), "g")
        command(photo, "Unstack", #selector(unstackPhotos), "g", [.command, .shift])
        command(photo, "Open Stack", #selector(toggleStack), "")
        command(photo, "Stack Bursts", #selector(stackBursts), "")
        photo.addItem(.separator())
        command(photo, "Duplicate", #selector(duplicate), "d")
        command(photo, "Reset Edits", #selector(resetEdits), "r", [.command, .shift])
        photo.addItem(.separator())
        // Qlick Lab: ⌫ opens the Remove dialog; nothing is ever deleted without it (and a second question for the disk).
        command(photo, "Remove…", #selector(removePhotos), "\u{8}", [])
        command(photo, "Remove Rejected Photos…", #selector(removeRejected), "")
        photo.addItem(.separator())
        // Qlick Lab: Auto Advance; ⇧ with a mark key does the same once (`EditorWindowController.markAndAdvance`).
        command(photo, "Auto Advance", #selector(toggleAdvance), "")
        photo.addItem(.separator())
        command(photo, "Clear Filter", #selector(clearFilter), "l", [.command, .option])

        // Qlick Lab: its rooms, projects and the contact sheet's commands.
        menu.addItem(withTitle: labMenu.menu.title, action: nil, keyEquivalent: "").submenu = labMenu.menu
        applyShortcuts()
        model.lab.keys.changed = { [weak self] in self?.applyShortcuts() }
        // Qlick Lab: the photographer's own menu shortcuts, once the menu bar is whole.
        DispatchQueue.main.async { MenuShortcuts.shared.apply() }

        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu("Help")
        command(help, "\(name) on GitHub", #selector(openRepository), "")
        command(help, "Report a Problem…", #selector(reportProblem), "")
        help.addItem(.separator())
        command(help, "Support \(name)…", #selector(supportTheLab), "")
        NSApp.helpMenu = help
    }

    private func submenu(_ title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        return submenu
    }

    private func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
    }

    /// A second key for the command above it, not listed in the menu.
    private func hidden(_ menu: NSMenu, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        let item = menu.addItem(withTitle: "", action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    // MARK: Commands

    /// Sparkle when a release feed is set; otherwise the releases page, where each version's DMG is.
    @objc private func checkForUpdates() {
        if updates.configured { updates.check() } else { NSWorkspace.shared.open(Support.releasesURL) }
    }
    @objc private func supportTheLab() { Support.openDonationPage() }
    @objc private func openRepository() { NSWorkspace.shared.open(Support.repositoryURL) }
    @objc private func reportProblem() { NSWorkspace.shared.open(Support.issuesURL) }
    /// About: whose the app is and what develops its photographs, then the works it's built with, as their licences ask.
    @objc private func showAbout() {
        let centred = NSMutableParagraphStyle(); centred.alignment = .center; centred.paragraphSpacing = 6
        func text(_ string: String, size: CGFloat, color: NSColor = .labelColor, weight: NSFont.Weight = .regular) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: centred])
        }
        let credits = NSMutableAttributedString()
        credits.append(text("Designed and developed by Quentin Descotte.\n", size: 12, weight: .medium))
        credits.append(text("Film development by spektrafilm, the spectral film model of Andrea Volpato.\n\n", size: 11.5))
        credits.append(text("ACKNOWLEDGEMENTS\n", size: 9.5, color: .secondaryLabelColor, weight: .semibold))
        credits.append(text("""
            spektrafilm © Andrea Volpato · film and paper profiles under CC BY-SA 4.0
            spektrafilm-rs © turbasvin
            Negs © 2026 Noah Haasis · Qlick Lab is a modified version of Negs
            Prep and waveform © 2026 yosoyelchris
            Fotufilm profiles © MUAStudio Inc. · rawler (dnglab) · Sparkle
            Free software under the GNU General Public License, version 3, without warranty.
            """, size: 10.5, color: .secondaryLabelColor))
        let support = NSMutableAttributedString(string: "\n\nFree and open source. If you like it, offer a coffee · Source on GitHub",
            attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centred])
        let whole = support.string as NSString
        support.addAttribute(.link, value: Support.donationURL, range: whole.range(of: "offer a coffee"))
        support.addAttribute(.link, value: Support.repositoryURL, range: whole.range(of: "Source on GitHub"))
        credits.append(support)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(updates: updates, model: model)
        }
        settings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func openPhotograph() { model.openPanel() }
    @objc private func showRecent() {}
    @objc private func openRecent(_ item: NSMenuItem) { if let url = item.representedObject as? URL { model.open(url) } }
    @objc private func savePreview() { model.savePanel(export: false) }
    @objc private func exportPhotograph() { model.exportPanel() }
    @objc private func exportLUT() { model.exportLUTPanel() }
    @objc private func toggleImageOnly() { model.toggleImageOnly() }
    @objc private func toggleFilmstrip() { model.toggleFilmstrip() }
    @objc private func toggleAdjustments() { model.togglePane(.adjustments) }
    @objc private func newPreset() { model.newPreset() }
    @objc private func importPresets() { model.importPresetsPanel() }
    @objc private func showPresetsFolder() { model.showPresetsFolder() }
    @objc private func toggleAllControls() { AdjustmentInspector.toggleAllControls() }
    @objc private func fitPhotograph() { model.zoom(fit: true) }
    @objc private func actualSize() { model.zoom(fit: false) }
    @objc private func rotate() { model.turn(clockwise: true) }
    @objc private func rotateLeft() { model.turn(clockwise: false) }
    @objc private func crop() { model.cropping ? model.endCrop(apply: true) : model.beginCrop() }
    @objc private func autoStraighten() { model.autoStraighten() }
    @objc private func resetAdjustments() { model.reset() }
    @objc private func rate(_ item: NSMenuItem) { model.lab.menuRate(item.tag) }
    @objc private func raiseRating() { model.changeRating(by: 1) }
    @objc private func lowerRating() { model.changeRating(by: -1) }
    @objc private func pick() { model.lab.menuMark(.pick) }
    @objc private func reject() { model.lab.menuMark(.reject) }
    @objc private func unflag() { model.lab.menuMark(nil) }
    @objc private func toggleAdvance() { model.advanceAfterRating.toggle() }
    @objc private func colorLabel(_ item: NSMenuItem) {
        model.lab.menuLabel(item.tag == 0 ? nil : ColorLabel.allCases[item.tag - 1])
    }
    @objc private func addKeyword() { model.lab.askKeyword() }
    @objc private func clearFilter() { model.library.filter = LibraryFilter() }
    @objc private func editPhotograph() { model.editCurrent() }
    @objc private func copyEdits() { model.copyEdits() }
    @objc private func showBoxes() {}
    @objc private func chooseBox() { model.lab.chooseBox(in: NSApp.keyWindow?.contentView) }
    @objc private func newBoxFromSelection() { model.lab.newBox(with: model.lab.selectionTargets) }
    @objc private func removeFromBox() { model.lab.removeFromOpenHolder(model.lab.selectionTargets) }
    @objc private func stackPhotos() { model.lab.stackSelection() }
    @objc private func unstackPhotos() { model.lab.unstackSelection() }
    @objc private func toggleStack() { model.lab.toggleStackOpen() }
    @objc private func stackBursts() { model.lab.stackBursts() }
    @objc private func pasteEdits() { model.pasteEdits() }
    @objc private func pasteFromPrevious() { model.pasteFromPrevious() }
    @objc private func duplicate() { model.duplicate() }
    @objc private func resetEdits() { model.resetEdits() }
    @objc private func removePhotos() { model.lab.requestRemove() }
    @objc private func removeRejected() { model.lab.requestRemoveRejected() }

    /// Copy Edits…: the groups to copy, in the alert sheet; the choice is remembered.
    @objc private func copyEditsChoosing() {
        guard NSApp.keyWindow is EditorWindow else { return }
        model.copyEditsChoosing()
    }
    @objc private func showGrid() { model.lab.toggleSheet() }
    @objc private func largerThumbnails() { model.changeGridCellSize(larger: true) }
    @objc private func smallerThumbnails() { model.changeGridCellSize(larger: false) }

    /// Rating and flag keys act on the photograph in the editing window,
    /// and not while a text field there (or any other window) has the keys.
    private var rating: Bool { !model.ratingTargets.isEmpty && Self.takesRatingKeys(NSApp.keyWindow) }
    /// On when every photograph a rating command acts on passes `test`,
    /// mixed when some do.
    private func state(_ test: (LibrarySummary) -> Bool) -> NSControl.StateValue {
        let summaries = model.ratingTargets.map { model.library.summary(for: $0) }
        let passing = summaries.filter(test).count
        return passing == 0 ? .off : passing == summaries.count ? .on : .mixed
    }
    /// ⌫ also deletes the selected preset while the presets list has the keys.
    static func takesDeleteKey(_ window: NSWindow?) -> Bool {
        guard takesRatingKeys(window) else { return false }
        var view = window?.firstResponder as? NSView
        while let next = view {
            // A list, or a focused control that deletes its own (a preset tile).
            if next is NSTableView { return false }
            if let anchor = next as? FocusAnchorView, anchor.delete != nil { return false }
            view = next.superview
        }
        return true
    }
    /// The same check as holding \ for the original.
    static func takesRatingKeys(_ window: NSWindow?) -> Bool {
        guard let window, window is EditorWindow else { return false }
        // Qlick Lab: only in the rooms that show a photograph to rate or mark.
        if let controller = window.windowController as? EditorWindowController, !controller.shell.model.lab.takesPhotoKeys { return false }
        return !(window.firstResponder is NSText)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The alert sheet is answered first, as a system alert's would be.
        if model.alert != nil { return false }
        let photo = model.source != nil
        // The grid shows no photograph to adjust, zoom or crop.
        let editing = photo && model.mode == .photo && model.lab.workspace == .develop
        switch item.action {
        case #selector(checkForUpdates): return !updates.configured || updates.canCheck
        case #selector(showRecent): return !model.recentFiles.isEmpty
        case #selector(savePreview): return model.canSave && model.mode == .photo
        case #selector(exportPhotograph):
            item.title = model.exportTitle
            return model.canExport && !model.cropping
        case #selector(exportLUT): return model.canExportLUT && model.mode == .photo
        case #selector(toggleImageOnly):
            item.state = model.imageOnly ? .on : .off
            // In the grid it opens the current photograph in Image Only.
            let shown = model.mode == .grid ? model.selection.current != nil : photo
            return Self.takesRatingKeys(NSApp.keyWindow) && (model.imageOnly || (shown && !model.cropping))
        case #selector(toggleFilmstrip):
            item.title = model.stripShown ? "Hide Film Strip" : "Show Film Strip"
            return model.mode == .photo
        case #selector(toggleAdjustments):
            item.state = model.inspectorShown && model.inspectorPane == .adjustments ? .on : .off; return model.mode == .photo
        case #selector(newPreset): return model.canChangePresets && model.mode == .photo
        case #selector(importPresets): return model.canChangePresets
        case #selector(showPresetsFolder): return true
        case #selector(toggleAllControls):
            item.state = UserDefaults.standard.bool(forKey: AdjustmentInspector.allControlsKey) ? .on : .off
            return model.mode == .photo
        case #selector(fitPhotograph), #selector(actualSize): return editing && !model.cropping
        case #selector(rotate), #selector(rotateLeft): return model.cropping || (editing && model.image != nil)
        case #selector(crop):
            item.title = model.cropping ? "Done Cropping" : "Crop"
            // A plain key: never while a word is typed.
            return Self.takesRatingKeys(NSApp.keyWindow) && (model.cropping || (model.image != nil && model.mode == .photo))
        case #selector(autoStraighten): return model.image != nil && model.mode == .photo && model.lab.workspace == .develop
        case #selector(resetAdjustments): return model.hasCatalog && !model.cropping && model.mode == .photo
        case #selector(editPhotograph): return model.mode == .grid && model.selection.current != nil && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(showGrid):
            let sheet = model.lab.workspace == .contactSheet
            item.title = sheet ? "Show Develop" : "Show Contact Sheet"
            return !model.cropping && Self.takesRatingKeys(NSApp.keyWindow) && (sheet ? model.selection.current != nil || model.source != nil : true)
        case #selector(largerThumbnails): return model.mode == .grid && model.gridCellSize < SheetLayout.sizes.upperBound
        case #selector(smallerThumbnails): return model.mode == .grid && model.gridCellSize > SheetLayout.sizes.lowerBound
        case #selector(copyEdits), #selector(copyEditsChoosing):
            return model.canCopyEdits && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(pasteEdits):
            return model.canPasteEdits && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(showBoxes), #selector(chooseBox), #selector(newBoxFromSelection):
            return !model.lab.selectionTargets.isEmpty && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(removeFromBox):
            let open = model.lab.openHolder.flatMap { model.lab.projects.shortName($0) }
            let count = model.lab.selectionTargets.count
            item.title = open.map { "Remove " + (count > 1 ? "\(count) Photographs " : "") + "from “\($0)”" } ?? "Remove from Box"
            return open != nil && count > 0 && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(stackPhotos):
            let count = model.lab.selectionTargets.count
            item.title = count > 1 ? "Stack \(count) Photographs" : "Stack"
            return count > 1 && model.lab.workspace != .importer && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(unstackPhotos):
            return model.lab.selectionStack != nil && model.lab.workspace != .importer && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(toggleStack):
            let stack = model.lab.selectionStack
            item.title = stack?.open == true ? "Close Stack" : "Open Stack"
            return stack != nil && model.lab.workspace != .importer && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(stackBursts):
            return !model.library.items.isEmpty && model.lab.workspace != .importer && NSApp.keyWindow is EditorWindow
        case #selector(pasteFromPrevious):
            return model.previousEdits != nil && model.canChangeEdits && !model.editTargets.isEmpty && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(duplicate), #selector(resetEdits):
            return model.canChangeEdits && !model.editTargets.isEmpty && Self.takesRatingKeys(NSApp.keyWindow)
        case #selector(removePhotos):
            let count = model.deleteTargets.count
            item.title = count > 1 ? "Remove \(count) Photographs…" : "Remove…"
            return model.canDelete && count > 0 && Self.takesDeleteKey(NSApp.keyWindow)
        case #selector(removeRejected): return model.canDelete && !model.rejected.isEmpty
        case #selector(rate(_:)):
            item.state = state { $0.rating == item.tag }; return rating
        case #selector(raiseRating), #selector(lowerRating): return rating
        case #selector(pick): item.state = state { $0.flag == .pick }; return rating
        case #selector(reject): item.state = state { $0.flag == .reject }; return rating
        case #selector(unflag): item.state = state { $0.flag == nil }; return rating
        case #selector(toggleAdvance): item.state = model.advanceAfterRating ? .on : .off; return true
        case #selector(colorLabel(_:)):
            let label = item.tag == 0 ? nil : ColorLabel.allCases[item.tag - 1]
            if let label { item.title = LabelNames.name(label) }
            item.state = state { $0.label == label }
            return rating && model.lab.workspace != .importer
        case #selector(addKeyword): return !model.ratingTargets.isEmpty && model.lab.workspace != .importer && NSApp.keyWindow is EditorWindow
        case #selector(clearFilter): return model.library.filter.active
        default: return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === boxes {
            let built = model.lab.addToBoxMenu(for: model.lab.selectionTargets)
            for item in built.items { built.removeItem(item); menu.addItem(item) }
            return
        }
        for url in model.recentFiles {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent), keyEquivalent: "")
            item.target = self; item.representedObject = url; item.toolTip = url.path
        }
    }
}
