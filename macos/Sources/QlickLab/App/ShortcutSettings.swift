// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Settings › Shortcuts: every key the lab answers to, in one list. The contact sheet's single keys first (the
/// sorting keys), then each menu's commands. A key is changed by clicking it and pressing the new one; a key another
/// command has is said before anything changes, with the choice to take it. A red dot marks what differs from the
/// lab's own keys, and each row's menu adds, removes or puts back its key.
struct ShortcutSettings: View {
    let keys: ShortcutStore
    let menus: MenuShortcuts
    @State private var query = ""
    /// What's being recorded: a sheet action's id, or a menu command's.
    @State private var recording: Target?
    /// A key that another command has, waiting for "Take It" or "Cancel".
    @State private var clash: Clash?
    @State private var problem: String?

    enum Target: Hashable { case sheet(SheetAction), menu(String) }

    struct Clash {
        let target: Target
        let shortcut: MenuShortcuts.Shortcut
        let other: MenuShortcuts.Command
    }

    var body: some View {
        let _ = menus.version
        let sheetActions = SheetAction.shown.filter { matches($0.title, ShortcutStore.display(keys.key($0))) }
        let commands = menus.commands().filter { matches($0.menu + " " + $0.title, menus.current($0).display) }
        let menuNames = commands.reduce(into: [String]()) { if !$0.contains($1.menu) { $0.append($1.menu) } }
        let changes = SheetAction.shown.filter { keys.key($0) != $0.standard }.count + menus.overrides.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SearchField(text: $query)
                Button(changes == 1 ? "Undo 1 Change" : "Undo \(changes) Changes") {
                    keys.reset(); menus.resetAll(); recording = nil; clash = nil; problem = nil
                }
                .buttonStyle(QPillButtonStyle())
                .opacity(changes == 0 ? 0 : 1)
                .disabled(changes == 0)
                .help("Puts every key back to the lab’s own")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !sheetActions.isEmpty {
                        Section {
                            ForEach(sheetActions) { sheetRow($0) }
                        } header: {
                            header("Contact Sheet", note: "Single keys, wherever you aren’t typing")
                        }
                    }
                    ForEach(menuNames, id: \.self) { menu in
                        Section {
                            ForEach(commands.filter { $0.menu == menu }) { menuRow($0) }
                        } header: {
                            header(menu, note: nil)
                        }
                    }
                    if sheetActions.isEmpty && menuNames.isEmpty {
                        Text("No command or key matches “\(query)”.").font(Theme.ui(12)).foregroundStyle(Theme.dim).padding(.vertical, 20)
                    }
                }
            }
            .frame(height: 400)
            Text("Click a key, then press the new one; esc leaves it as it was, ⌫ removes it. Menu keys need ⌘, ⌥ or ⌃. Fixed: the arrows move, ⇧ extends, 1–5 rate, 0 clears.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Size.gutter)
        .padding(.vertical, 14)
        .background(KeyRecorder(active: recording != nil && clash == nil) { key, flags in record(key, flags) })
    }

    private func matches(_ title: String, _ key: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || (!key.isEmpty && key.localizedStandardContains(query))
    }

    private func header(_ title: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).font(Theme.serif(11, weight: 700)).tracking(11 * 0.13).foregroundStyle(Theme.label)
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.dim) }
            Spacer(minLength: 0)
        }
        .padding(.top, 12).padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { InkRule() }
    }

    // MARK: Rows

    private func sheetRow(_ action: SheetAction) -> some View {
        let key = keys.key(action)
        return row(title: action.title, changed: key != action.standard, target: .sheet(action), caps: [ShortcutStore.display(key)], removable: false) {
            keys.set(action.standard, for: action)
        }
    }

    private func menuRow(_ command: MenuShortcuts.Command) -> some View {
        let shortcut = menus.current(command)
        return row(title: command.title, changed: menus.isChanged(command), target: .menu(command.id),
                   caps: shortcut.isNone ? [] : KeyCaps.parts(shortcut.display), removable: !shortcut.isNone) {
            menus.reset(command)
        } remove: {
            menus.set(.none, for: command)
        }
    }

    private func row(title: String, changed: Bool, target: Target, caps: [String], removable: Bool,
                     reset: @escaping () -> Void, remove: @escaping () -> Void = {}) -> some View {
        let on = recording == target
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.label).lineLimit(1)
                if changed { EditDot().help("Not the lab’s own key") }
                Spacer(minLength: 8)
                Button {
                    recording = on ? nil : target; clash = nil; problem = nil
                } label: {
                    if on {
                        Text("Press a key…").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 10).frame(minHeight: 22)
                            .background(Capsule().fill(Theme.accent))
                    } else if caps.isEmpty {
                        Text("Add Key").font(.system(size: 11.5)).foregroundStyle(Theme.dim).frame(minHeight: 22)
                    } else {
                        KeyCaps(caps: caps)
                    }
                }
                .buttonStyle(.plain)
                .help(on ? "Press the new key, or esc" : "Click, then press the new key")
                Menu {
                    Button("Record a Key") { recording = target; clash = nil; problem = nil }
                    if removable { Button("Remove the Key") { remove() } }
                    if changed { Button("Back to the Lab’s Key") { reset() } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Record, remove or put back the key")
            }
            if on, let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if let clash, clash.target == target {
                HStack(spacing: 8) {
                    Text("\(clash.shortcut.display) is \(clash.other.menu) › \(clash.other.title)’s.").font(.system(size: 11)).foregroundStyle(Theme.warn)
                    Spacer(minLength: 4)
                    Button("Take It") { take(clash) }.buttonStyle(QPillButtonStyle())
                    Button("Cancel") { self.clash = nil; recording = nil }.buttonStyle(QPillButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }

    // MARK: Recording

    private func record(_ key: String, _ flags: NSEvent.ModifierFlags) {
        guard let target = recording else { return }
        if key == "\u{1b}" && flags.isEmpty { recording = nil; problem = nil; return }
        switch target {
        case .sheet(let action):
            guard flags.isDisjoint(with: [.command, .control, .option]) else { problem = "A contact sheet key is a single key; ⌘ keys belong to the menus."; return }
            let typed = key == "\u{3}" ? "\r" : key.lowercased()
            if let reason = keys.problem(typed, for: action) { problem = reason; return }
            keys.set(typed, for: action)
            recording = nil; problem = nil
        case .menu(let id):
            guard let command = menus.commands().first(where: { $0.id == id }) else { recording = nil; return }
            let shortcut: MenuShortcuts.Shortcut = (key == "\u{7f}" || key == "\u{8}") && flags.isEmpty ? .none
                : MenuShortcuts.Shortcut(key: key.lowercased(), modifiers: flags.rawValue)
            if !shortcut.isNone, flags.isDisjoint(with: [.command, .control, .option]), !["\u{F704}", "\u{F705}", "\u{F706}", "\u{F707}"].contains(key) {
                problem = "A menu key needs ⌘, ⌥ or ⌃: single keys are the contact sheet’s, and typing’s."
                return
            }
            if let other = menus.conflict(shortcut, for: command) {
                clash = Clash(target: target, shortcut: shortcut, other: other)
                return
            }
            menus.set(shortcut, for: command)
            recording = nil; problem = nil
        }
    }

    /// The key goes to the command recorded; the other is left without one.
    private func take(_ clash: Clash) {
        guard case .menu(let id) = clash.target, let command = menus.commands().first(where: { $0.id == id }) else { return }
        menus.set(.none, for: clash.other)
        menus.set(clash.shortcut, for: command)
        self.clash = nil; recording = nil; problem = nil
    }
}

/// A key as caps, one per modifier and one for the key: ⌥ ⇧ ⌘ M.
struct KeyCaps: View {
    let caps: [String]

    /// "⌥⇧⌘M" as ["⌥", "⇧", "⌘", "M"].
    static func parts(_ display: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = [], rest = Substring(display)
        while let first = rest.first, modifiers.contains(first) { parts.append(String(first)); rest = rest.dropFirst() }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.paper)
                    .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined(separator: " "))
    }
}

/// The search field: actions or keys.
private struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.dim)
            TextField("Search commands or keys", text: $text).textFieldStyle(.plain).font(Theme.ui(12.5))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// Takes the next key press, with its modifiers, while a key is being recorded.
private struct KeyRecorder: NSViewRepresentable {
    let active: Bool
    let pressed: (String, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.pressed = pressed; view.set(active: active) }

    final class Catcher: NSView {
        var pressed: (String, NSEvent.ModifierFlags) -> Void = { _, _ in }
        private var monitor: Any?
        func set(active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return event }
                    self.pressed(typed, event.modifierFlags.intersection([.command, .option, .control, .shift]))
                    return nil
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor); self.monitor = nil
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
