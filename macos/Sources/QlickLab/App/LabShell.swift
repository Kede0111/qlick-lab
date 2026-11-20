// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The rooms laid over NEgs's editor. Développement is the editor itself, so nothing is drawn for it.
struct WorkspaceOverlay: View {
    let model: EditorModel

    var body: some View {
        let lab = model.lab
        Group {
            switch lab.workspace {
            case .develop: EmptyView()
            case .library: LibraryHome(model: model)
            case .contactSheet: ContactSheetWorkspace(model: model)
            case .compare: CompareWorkspace(model: model)
            case .recipes: RecipesWorkspace(model: model)
            case .films: StockLibrary(model: model, papers: false)
            case .papers: StockLibrary(model: model, papers: true)
            case .importer: ImportWorkspace(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: Binding(get: { lab.naming }, set: { lab.naming = $0 })) { naming in
            NamingSheet(lab: lab, naming: naming)
        }
        .sheet(item: Binding(get: { lab.smartRollDraft }, set: { lab.smartRollDraft = $0 })) { draft in
            SmartRollEditor(lab: lab, draft: draft)
        }
        .sheet(isPresented: Binding(get: { lab.printing }, set: { lab.printing = $0 })) {
            SheetPrintDialog(model: model)
        }
    }
}

/// The window's two columns: the lab's sidebar, and NEgs's editor with the rooms laid over it.
///
/// The sidebar is a real sidebar item, so macOS 26 draws it as a floating pane of Liquid Glass with the traffic
/// lights in it, and it collapses, resizes and restores as any Mac sidebar does.
@MainActor final class LabShellController: NSSplitViewController {
    let model: EditorModel
    let editor: NSViewController
    /// The title band over the editor's columns, with its trail of links.
    var editorBand: TitleBand? { (editor as? EditorFrame)?.band }
    private let sidebarItem: NSSplitViewItem
    private let overlay: NSHostingView<WorkspaceOverlay>
    private var collapsing: NSKeyValueObservation?
    static let sidebarWidth: CGFloat = 216

    /// `editorContent` is the editor's columns, under its title band: the rooms cover them and leave the band.
    init(model: EditorModel, editor: NSViewController, editorContent: NSView) {
        self.model = model
        self.editor = editor
        let sidebar = NSHostingController(rootView: LabSidebar(model: model))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 300
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !model.lab.sidebarVisible
        if #available(macOS 26.0, *) { sidebarItem.titlebarSeparatorStyle = .none }
        overlay = NSHostingView(rootView: WorkspaceOverlay(model: model))
        overlay.sizingOptions = []
        overlay.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: editor)
        content.minimumThickness = 640
        addSplitViewItem(content)
        splitView.autosaveName = "qlick.shell"
        overlay.frame = editorContent.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        editorContent.addSubview(overlay, positioned: .above, relativeTo: nil)
        collapsing = sidebarItem.observe(\.isCollapsed) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated {
                guard let self, self.model.lab.sidebarVisible == collapsed else { return }
                self.model.lab.sidebarVisible = !collapsed
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var sidebarWidthNow: CGFloat { sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width }

    /// Brings the window to the lab's state: the sidebar shown or not, the room's view over the editor or not.
    func update() {
        let lab = model.lab
        if sidebarItem.isCollapsed == lab.sidebarVisible { sidebarItem.animator().isCollapsed = !lab.sidebarVisible }
        // The contact sheet's Grid is NEgs's own sheet, under the room: nothing covers it.
        let covered = lab.workspace != .develop && !(lab.workspace == .contactSheet && lab.sheet.style == .grid && model.source != nil)
        model.canvasScale.covered = covered
        if overlay.isHidden == covered {
            overlay.isHidden = !covered
            if covered {
                // The room's own view takes the keys (the sheet, the comparison).
                DispatchQueue.main.async { [weak self] in self?.focusRoom() }
            } else if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: overlay) {
                view.window?.makeFirstResponder(nil)
            }
        }
    }

    /// Gives the keys to the room's main view.
    func focusRoom() {
        guard let window = view.window, !overlay.isHidden else { return }
        if window.firstResponder is NSText { return }
        if model.lab.workspace == .contactSheet, let sheet = model.lab.sheetView, sheet.window === window { window.makeFirstResponder(sheet) }
        else if model.lab.workspace == .compare, let canvas = model.lab.compareModel.canvas, canvas.window === window { window.makeFirstResponder(canvas) }
    }

    /// The room is the one that shows: the editor's own keys (its strip's arrows, its crop) wait.
    var roomCoversEditor: Bool { !overlay.isHidden }

    @objc func toggleLabSidebar(_ sender: Any?) { model.lab.sidebarVisible.toggle() }
}
