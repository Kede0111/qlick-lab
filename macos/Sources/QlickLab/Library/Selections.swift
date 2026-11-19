// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Selections: frames chosen from any rolls, shown on one contact sheet (`ProjectStore.viewFolder`). The photographs
/// stay in their rolls, with their marks and developments; a selection only lists them.
extension LabState {
    /// The selection open on the sheet, if one is.
    var openSelection: LabProject? { wholeProject.flatMap { $0.isSelection ? $0 : nil } }

    /// The frames a command acts on: the sheet's selection, or the frame under the pointer.
    var selectionTargets: [URL] { model.ratingTargets.map(\.photoFile) }

    func newSelection(with frames: [URL]) {
        naming = ProjectNaming(name: frames.isEmpty ? "New Selection" : "Selection", frames: frames)
    }

    func addToSelection(_ id: UUID, frames: [URL]) {
        guard !frames.isEmpty else { return }
        projects.addFrames(frames, to: id)
        selectionChanged(id)
    }

    func removeFromOpenSelection(_ frames: [URL]) {
        guard let selection = openSelection, !frames.isEmpty else { return }
        projects.removeFrames(frames, from: selection.id)
        if projects.projects.first(where: { $0.id == selection.id })?.frames?.isEmpty ?? true {
            model.closeFolder()
            show(.library)
            return
        }
        selectionChanged(selection.id)
    }

    /// A selection's frames changed: shown, it's listed again.
    func selectionChanged(_ id: UUID) {
        guard let selection = projects.projects.first(where: { $0.id == id }) else { return }
        let list = projects.viewFolder(for: selection)
        if model.library.directory?.standardizedFileURL.path == list.standardizedFileURL.path { model.library.refreshNow() }
    }

    func removeSelection(_ selection: LabProject) {
        Task {
            let answer = await model.ask(AppAlert(
                title: "Remove the selection “\(selection.name)”?",
                detail: "Its photographs stay in their rolls, with their marks and developments.",
                buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Remove", role: .destructive)]))
            guard answer.button == 1 else { return }
            let showing = openSelection?.id == selection.id
            projects.remove(selection.id)
            if showing { model.closeFolder(); show(.library) }
        }
    }

    /// Add to Selection, and Remove from the Selection when one is open: the frames' menus in the contact sheet and in
    /// Develop (AppKit menus).
    func selectionItems(for frames: [URL]) -> [NSMenuItem] {
        let several = frames.count > 1 ? " (\(frames.count) frames)" : ""
        let menu = NSMenu()
        for selection in projects.selections where selection.id != openSelection?.id {
            menu.addItem(ClosureMenuItem(selection.name) { [weak self] in self?.addToSelection(selection.id, frames: frames) })
        }
        if !projects.selections.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Selection…") { [weak self] in self?.newSelection(with: frames) })
        let add = NSMenuItem(title: "Add to Selection" + several, action: nil, keyEquivalent: "")
        add.submenu = menu
        var items = [add]
        if let open = openSelection {
            items.append(ClosureMenuItem("Remove from “\(open.name)”" + several) { [weak self] in self?.removeFromOpenSelection(frames) })
        }
        return items
    }
}

/// The same, for SwiftUI menus (the grid and the film strip).
struct SelectionMenuItems: View {
    let lab: LabState
    let frames: [URL]

    var body: some View {
        let several = frames.count > 1 ? " (\(frames.count) frames)" : ""
        Menu("Add to Selection" + several) {
            ForEach(lab.projects.selections.filter { $0.id != lab.openSelection?.id }) { selection in
                Button(selection.name) { lab.addToSelection(selection.id, frames: frames) }
            }
            if !lab.projects.selections.isEmpty { Divider() }
            Button("New Selection…") { lab.newSelection(with: frames) }
        }
        if let open = lab.openSelection {
            Button("Remove from “\(open.name)”" + several) { lab.removeFromOpenSelection(frames) }
        }
    }
}
