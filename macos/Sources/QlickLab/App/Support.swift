// Qlick Lab — GPL-3.0-only.
import AppKit

/// Qlick Lab is free. Once someone has really used it (50 photographs exported), it asks, once, whether they'd like
/// to offer its author a coffee. The question comes back at most every 90 days and after 50 more photographs, never
/// after "Already Did" or "Don't ask again". The menu's Support Qlick Lab… is always there.
///
/// A batch counts once, however many photographs it holds: 300 exported in one go ask at most one question.
enum Support {
    static let donationURL = URL(string: "https://www.paypal.com/donate/?hosted_button_id=HWP2MECER3PRA")!
    static let repositoryURL = URL(string: "https://github.com/Kede0111/qlick-lab")!
    static let releasesURL = URL(string: "https://github.com/Kede0111/qlick-lab/releases")!
    static let issuesURL = URL(string: "https://github.com/Kede0111/qlick-lab/issues/new/choose")!
    static let threshold = 50
    static let interval: TimeInterval = 90 * 24 * 60 * 60

    enum Key {
        static let exported = "support.exportedPhotographs"
        static let askedAt = "support.askedAt"
        static let exportedWhenAsked = "support.exportedWhenAsked"
        static let stopped = "support.stopped"
    }

    /// Whether the question is due, from what `defaults` holds.
    static func due(_ defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard !defaults.bool(forKey: Key.stopped) else { return false }
        let exported = defaults.integer(forKey: Key.exported)
        guard exported - defaults.integer(forKey: Key.exportedWhenAsked) >= threshold else { return false }
        guard let asked = defaults.object(forKey: Key.askedAt) as? Date else { return true }
        return now.timeIntervalSince(asked) >= interval
    }

    /// Adds an export of `count` photographs (a single export or a whole batch); true when the question is due.
    @discardableResult
    static func record(_ count: Int, in defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard count > 0 else { return false }
        defaults.set(defaults.integer(forKey: Key.exported) + count, forKey: Key.exported)
        return due(defaults, now: now)
    }

    /// Marks the question as asked now, so the next one waits for the interval and 50 more photographs.
    static func markAsked(in defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now, forKey: Key.askedAt)
        defaults.set(defaults.integer(forKey: Key.exported), forKey: Key.exportedWhenAsked)
    }

    @MainActor static func openDonationPage() { NSWorkspace.shared.open(donationURL) }

    /// After an export: counts it, and asks if it's time, once the window is free (no sheet, no export running).
    @MainActor static func exported(_ count: Int, model: EditorModel, defaults: UserDefaults = .standard) {
        guard record(count, in: defaults) else { return }
        askWhenFree(model: model, defaults: defaults, attempts: 20)
    }

    @MainActor private static var asking = false

    @MainActor private static func askWhenFree(model: EditorModel, defaults: UserDefaults, attempts: Int) {
        guard attempts > 0, !asking else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            guard NSApp.isActive, let window, window.attachedSheet == nil, !model.exporting, !model.batchRunning, due(defaults) else {
                // Busy, in the background or no longer due: look again a little later.
                if due(defaults) { askWhenFree(model: model, defaults: defaults, attempts: attempts - 1) }
                return
            }
            ask(in: window, defaults: defaults)
        }
    }

    @MainActor private static func ask(in window: NSWindow, defaults: UserDefaults) {
        asking = true
        markAsked(in: defaults)
        let alert = NSAlert()
        alert.messageText = "Enjoying Qlick Lab?"
        alert.informativeText = "Qlick Lab is free and open source, developed in spare time by Quentin Descotte. "
            + "If it develops photographs you like, you can offer a coffee to say thanks. This question comes rarely."
        alert.addButton(withTitle: "Offer a Coffee…")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Already Did")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                asking = false
                if response == .alertFirstButtonReturn { openDonationPage() }
                if response == .alertThirdButtonReturn || alert.suppressionButton?.state == .on {
                    defaults.set(true, forKey: Key.stopped)
                }
            }
        }
    }
}
