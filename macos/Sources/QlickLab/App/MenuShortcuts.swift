// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The menus' keyboard shortcuts, which the photographer can change (Settings › Shortcuts). Each command is named by
/// its menu and action, not its title (some titles change as they're used); the shortcuts it was built with are its
/// defaults, and only the changes are kept.
@MainActor @Observable final class MenuShortcuts {
    static let shared = MenuShortcuts()
    private static let key = "qlick.menuShortcuts"

    struct Shortcut: Equatable, Codable {
        var key: String
        var modifiers: UInt
        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }
        static let none = Shortcut(key: "", modifiers: 0)
        var isNone: Bool { key.isEmpty }
        var display: String { isNone ? "" : MenuShortcuts.display(key: key, flags: flags) }
    }

    struct Command: Identifiable {
        let id: String
        let menu: String
        let title: String
        let item: NSMenuItem
    }

    private(set) var overrides: [String: Shortcut]
    @ObservationIgnored private var defaults: [String: Shortcut] = [:]
    /// Moves when the menus change, so the list reads them again.
    private(set) var version = 0

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        overrides = data.flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
    }

    /// Commands the photographer can't change here: their keys are the sorting keys' (the Flag menu), or the system's.
    private static let fixed: Set<String> = ["pick", "reject", "unflag", "colorLabel:", "keywordSlot:", "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
                                              "terminate:", "hide:", "hideOtherApplications:", "performClose:", "performMiniaturize:"]

    nonisolated static func id(menu: String, item: NSMenuItem) -> String? {
        guard let action = item.action else { return nil }
        var id = menu + "|" + NSStringFromSelector(action)
        if item.tag != 0 { id += "#\(item.tag)" }
        if let object = item.representedObject as? String { id += "@" + object }
        return id
    }

    /// Every command of the menu bar, in menu order, under its top-level menu's name.
    func commands(in given: NSMenu? = nil) -> [Command] {
        guard let menu = given ?? NSApp.mainMenu else { return [] }
        var list: [Command] = []
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            walk(sub, top: top.title, path: "", into: &list)
        }
        return list
    }

    private func walk(_ menu: NSMenu, top: String, path: String, into list: inout [Command]) {
        for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty && !item.isHidden {
            if let sub = item.submenu {
                // Open Recent and the like: lists of files, not commands.
                if sub === NSApp.servicesMenu || item.action == nil && sub.items.allSatisfy({ $0.action == nil || $0.representedObject is URL }) { continue }
                walk(sub, top: top, path: path + item.title + " › ", into: &list)
                continue
            }
            guard let action = item.action, !Self.fixed.contains(NSStringFromSelector(action)), !item.isAlternate,
                  let id = Self.id(menu: top + path, item: item) else { continue }
            list.append(Command(id: id, menu: top, title: path + item.title, item: item))
        }
    }

    func current(_ command: Command) -> Shortcut {
        Shortcut(key: command.item.keyEquivalent, modifiers: command.item.keyEquivalent.isEmpty ? 0 : command.item.keyEquivalentModifierMask.rawValue)
    }
    func isChanged(_ command: Command) -> Bool { overrides[command.id] != nil }

    /// Records the menus' own shortcuts as their defaults, then puts the photographer's in.
    func apply(to menu: NSMenu? = nil) {
        for command in commands(in: menu) {
            if defaults[command.id] == nil { defaults[command.id] = current(command) }
            guard let shortcut = overrides[command.id] else { continue }
            command.item.keyEquivalent = shortcut.key
            command.item.keyEquivalentModifierMask = shortcut.flags
        }
        version += 1
    }

    /// The command already using `shortcut`, if any but `command`.
    func conflict(_ shortcut: Shortcut, for command: Command) -> Command? {
        guard !shortcut.isNone else { return nil }
        return commands().first { $0.id != command.id && current($0) == shortcut }
    }

    func set(_ shortcut: Shortcut, for command: Command) {
        if defaults[command.id] == nil { defaults[command.id] = current(command) }
        if defaults[command.id] == shortcut { overrides[command.id] = nil } else { overrides[command.id] = shortcut }
        command.item.keyEquivalent = shortcut.key
        command.item.keyEquivalentModifierMask = shortcut.flags
        save()
    }

    func reset(_ command: Command) {
        guard let original = defaults[command.id] else { return }
        set(original, for: command)
    }

    func resetAll() {
        for command in commands() where overrides[command.id] != nil { reset(command) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Self.key) }
        version += 1
    }

    nonisolated static func display(key: String, flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "esc", "\u{8}": "⌫", "\u{7f}": "⌫",
                                       "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦"]
        if let name = names[key] { return text + name }
        if let scalar = key.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) { return text + "F\(scalar.value - 0xF703)" }
        return text + key.uppercased()
    }
}

/// Settings › Shortcuts: the sorting keys, then every menu command's shortcut, menu by menu.
struct MenuShortcutsList: View {
    let store: MenuShortcuts
    @State private var query = ""
    @State private var recording: String?
    @State private var problem: String?

    var body: some View {
        let _ = store.version
        let commands = store.commands().filter { query.isEmpty || ($0.menu + " " + $0.title).localizedStandardContains(query) }
        let menus = commands.reduce(into: [String]()) { if !$0.contains($1.menu) { $0.append($1.menu) } }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Menu commands").font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.paper)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Button("Reset All") { store.resetAll(); recording = nil; problem = nil }
                    .buttonStyle(QPillButtonStyle()).disabled(store.overrides.isEmpty)
            }
            Text("Click a shortcut, then press the new keys. ⌫ removes it.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
            if let problem { Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.warn) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(menus, id: \.self) { menu in
                        Section {
                            ForEach(commands.filter { $0.menu == menu }) { command in row(command) }
                        } header: {
                            Text(menu.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).background(Theme.panel)
                        }
                    }
                }
            }
            .frame(height: 380)
        }
        .background(MenuKeyCatcher(active: recording != nil) { key, flags in
            guard let id = recording, let command = store.commands().first(where: { $0.id == id }) else { return }
            if key == "\u{1b}" && flags.isEmpty { recording = nil; problem = nil; return }
            let shortcut: MenuShortcuts.Shortcut = (key == "\u{7f}" || key == "\u{8}") && flags.isEmpty ? .none
                : MenuShortcuts.Shortcut(key: key.lowercased(), modifiers: flags.rawValue)
            if !shortcut.isNone, flags.isDisjoint(with: [.command, .control, .option]), !["\u{F704}", "\u{F705}", "\u{F706}", "\u{F707}"].contains(key) {
                // Plain keys belong to the sorting keys above, and to typing.
                problem = "A menu shortcut needs ⌘, ⌥ or ⌃."
                return
            }
            if let other = store.conflict(shortcut, for: command) {
                problem = "\(shortcut.display) is already \(other.menu) › \(other.title)."
                return
            }
            store.set(shortcut, for: command)
            recording = nil; problem = nil
        })
    }

    private func row(_ command: MenuShortcuts.Command) -> some View {
        let shortcut = store.current(command)
        let on = recording == command.id
        return HStack {
            Text(command.title).font(Theme.ui(12)).foregroundStyle(Theme.label).lineLimit(1)
            Spacer()
            if store.isChanged(command) {
                Button { store.reset(command) } label: { Text("↺").font(Theme.ui(12)).foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain).help("Back to the default")
            }
            Button { recording = on ? nil : command.id; problem = nil } label: {
                Text(on ? "Press keys…" : shortcut.isNone ? "—" : shortcut.display)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(on ? Color.white : shortcut.isNone ? Theme.dim : Theme.paper)
                    .padding(.horizontal, 9).frame(minWidth: 70, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent : Color.white.opacity(store.isChanged(command) ? 0.16 : 0.07)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
    }
}

/// Takes the next key press, with its modifiers, while a menu shortcut is recorded.
private struct MenuKeyCatcher: NSViewRepresentable {
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
