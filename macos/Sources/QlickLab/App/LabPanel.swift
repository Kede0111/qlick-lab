// Qlick Lab — GPL-3.0-only.
import AppKit

/// The lab's open and save panels (Export, Save Preview, Open, Import, a catalogue, a folder to choose…).
///
/// Each one comes down as a sheet on the lab's window, the window in front when the lab is, so it can't open behind
/// it: a free panel shown while the lab was busy on a slow disk could open behind the window, unseen, and a click on
/// Export then did nothing, the panel being open already. One panel at a time: asking again while one is open brings
/// that one forward instead.
@MainActor enum LabPanel {
    private static weak var open: NSSavePanel?

    /// Whether a lab panel is open; brought forward, with its window and the lab, if so.
    @discardableResult
    static func bringForward() -> Bool {
        guard let panel = open, panel.isVisible || panel.sheetParent != nil else { open = nil; return false }
        if !LabAutomation.offscreen { NSApp.activate() }
        panel.sheetParent?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    /// Shows `panel` as a sheet on the lab's window and calls `done` with the answer. While another lab panel is
    /// open, that one comes forward and `panel` isn't shown.
    static func begin(_ panel: NSSavePanel, _ done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if bringForward() { return }
        open = panel
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                if open === panel { open = nil }
                done(response)
            }
        }
        if let window = host() {
            if !LabAutomation.offscreen { NSApp.activate() }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: answer)
        } else {
            // No lab window to hang it on: a panel of its own, in front.
            if !LabAutomation.offscreen { NSApp.activate() }
            panel.begin(completionHandler: answer)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Where the open lab panel is: "none", "sheet on <window title>" or "free" (for the lab's automation).
    static var whereShown: String {
        guard let panel = open else { return "none" }
        if let parent = panel.sheetParent { return "sheet on \(parent.title)" + (parent.attachedSheet === panel ? "" : " (queued)") }
        return panel.isVisible ? "free" : "none"
    }

    /// Cancels the open lab panel, as its Cancel button would.
    static func cancel() { open?.cancel(nil) }

    /// The window the sheet comes down on: the lab's key window (the lab's own, or Settings when asked from there),
    /// else the lab's window.
    private static func host() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible, !(key is NSPanel), key.sheetParent == nil { return key }
        return NSApp.windows.first { $0 is EditorWindow && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }
}
