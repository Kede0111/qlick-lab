// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Settings › Shortcuts: the sorting keys, each changed by clicking it and pressing the new key.
struct ShortcutSettings: View {
    let keys: ShortcutStore
    @State private var recording: SheetAction?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Click a key, then press the new one.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            ForEach(SheetAction.shown) { action in
                HStack {
                    Text(action.title).font(Theme.ui(12.5)).foregroundStyle(Theme.label)
                    Spacer()
                    KeyCap(key: keys.key(action), recording: recording == action, changed: keys.key(action) != action.standard) {
                        recording = recording == action ? nil : action; problem = nil
                    }
                }
                .frame(height: 30)
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.warn).padding(.top, 8)
            }
            HStack {
                Text("Fixed: arrows move, ⇧ extends, 1–5 rate, 0 clears.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Defaults") { keys.reset(); recording = nil; problem = nil }
                    .buttonStyle(QPillButtonStyle()).disabled(keys.isStandard)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, Theme.Size.gutter)
        .padding(.vertical, 16)
        .background(KeyCatcher(active: recording != nil) { key in
            guard let action = recording else { return }
            if key == "\u{1b}" { recording = nil; problem = nil; return }
            if let reason = keys.problem(key.lowercased(), for: action) { problem = reason; return }
            keys.set(key, for: action)
            recording = nil; problem = nil
        })
    }
}

private struct KeyCap: View {
    let key: String
    let recording: Bool
    let changed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(recording ? "Press a key…" : ShortcutStore.display(key))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(recording ? Color.white : Theme.paper)
                .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(recording ? Theme.accent : Color.white.opacity(changed ? 0.16 : 0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Waiting for a key" : "Key \(ShortcutStore.display(key))")
    }
}

/// Takes the next key press while a shortcut is being recorded.
private struct KeyCatcher: NSViewRepresentable {
    let active: Bool
    let pressed: (String) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.pressed = pressed
        view.set(active: active)
    }

    final class Catcher: NSView {
        var pressed: (String) -> Void = { _ in }
        private var monitor: Any?

        func set(active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                          let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return event }
                    self.pressed(typed == "\u{3}" ? "\r" : typed)
                    return nil
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
