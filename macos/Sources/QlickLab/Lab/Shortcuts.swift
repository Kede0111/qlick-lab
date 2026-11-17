// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation

/// The sorting keys, which the photographer can change (Réglages › Touches). Plain keys, without ⌘, so one hand
/// sorts while the other moves through the roll. The Photo menu's Pick, Reject and Unflagged follow them.
enum SheetAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case pick, reject, unmark, loupe, develop, compare, pencil, nextUnmarked, loupeTool
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pick: "Pick (ring)"
        case .reject: "Reject (cross out)"
        case .unmark: "Clear the mark"
        case .loupe: "See larger"
        case .develop: "Open in Develop"
        case .compare: "Compare the selection"
        case .pencil: "Pencil / pointer"
        case .nextUnmarked: "Next unmarked frame"
        case .loupeTool: "Loupe tool"
        }
    }

    /// NEgs's keys (Lightroom's and Capture One's) where it has one.
    var standard: String {
        switch self {
        case .pick: "p"
        case .reject: "x"
        case .unmark: "u"
        case .loupe: " "
        case .develop: "\r"
        case .compare: "c"
        case .pencil: "b"
        case .nextUnmarked: "n"
        case .loupeTool: "l"
        }
    }
}

@MainActor @Observable final class ShortcutStore {
    static let key = "qlick.shortcuts"
    private(set) var keys: [SheetAction: String]
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    /// Keys the lab and NEgs already use plainly: digits rate, arrows move, and these letters have a menu command.
    static let reserved: Set<String> = ["0", "1", "2", "3", "4", "5", "[", "]", "e", "g", "f", "t", "\\"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var keys: [SheetAction: String] = [:]
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        for action in SheetAction.allCases { keys[action] = saved[action.rawValue] ?? action.standard }
        self.keys = keys
    }

    func key(_ action: SheetAction) -> String { keys[action] ?? action.standard }

    /// The action a plain key press asks for.
    func action(for event: NSEvent) -> SheetAction? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return nil }
        let key = typed == "\u{3}" ? "\r" : typed
        return SheetAction.allCases.first { self.key($0) == key }
    }

    /// Why `key` can't be `action`'s, or nil if it can.
    func problem(_ key: String, for action: SheetAction) -> String? {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return "One key only." }
        if Self.reserved.contains(key) { return "“\(Self.display(key))” already rates or changes the view." }
        // Arrows and function keys.
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return "The arrows already move the frame." }
        if let other = SheetAction.allCases.first(where: { $0 != action && self.key($0) == key }) {
            return "“\(Self.display(key))” is already: \(other.title)."
        }
        return nil
    }

    @discardableResult func set(_ key: String, for action: SheetAction) -> Bool {
        let key = key.lowercased()
        guard problem(key, for: action) == nil else { return false }
        keys[action] = key
        save()
        return true
    }

    func reset() {
        for action in SheetAction.allCases { keys[action] = action.standard }
        save()
    }

    var isStandard: Bool { SheetAction.allCases.allSatisfy { key($0) == $0.standard } }

    private func save() {
        defaults.set(Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) }), forKey: Self.key)
        changed?()
    }

    /// A key as it's shown: its cap.
    static func display(_ key: String) -> String {
        switch key {
        case " ": "Space"
        case "\r": "↩"
        case "\t": "⇥"
        case "\u{1b}": "esc"
        case "\u{8}", "\u{7f}": "⌫"
        default: key.uppercased()
        }
    }
}
