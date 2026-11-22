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
