// Qlick Lab — GPL-3.0-only.
import Foundation
import SwiftUI

/// A photograph's colour label: a coloured sticker on the frame, for sorting by hand ("to print", "for the client").
/// Red, yellow, green and blue have keys (6 to 9, `SheetAction`); purple is in the menus. Each can be given a name of
/// the photographer's own (Settings, `LabelNames`). Stored in the sidecar (`label`) and, inside a DNG, as the standard
/// `xmp:Label` (its English name, as other software reads it).
enum ColorLabel: String, CaseIterable, Codable, Identifiable, Sendable {
    case red, yellow, green, blue, purple

    var id: String { rawValue }

    /// The colour's own name, and `xmp:Label`'s.
    var standardName: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    /// The sticker's colour: clear, a little muted, distinct from the lab's own red marks by its round shape.
    var hex: UInt32 {
        switch self {
        case .red: 0xe5484d
        case .yellow: 0xf2c94c
        case .green: 0x46a758
        case .blue: 0x3e8fe0
        case .purple: 0x9b6ad6
        }
    }

    var color: Color { Theme.color(hex) }
    var cgColor: CGColor { Theme.nsColor(hex).cgColor }

    /// The key that sets it by default (`SheetAction`), purple having none.
    var action: SheetAction? {
        switch self {
        case .red: .labelRed
        case .yellow: .labelYellow
        case .green: .labelGreen
        case .blue: .labelBlue
        case .purple: nil
        }
    }

    /// The order a sort by label follows: as listed, unlabelled last.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// From the sidecar's word or an XMP label (any case); nil for anything else, which is then left as it was.
    init?(word: String) {
        let lower = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard let label = Self.allCases.first(where: { $0.rawValue == lower }) else { return nil }
        self = label
    }
}

/// The photographer's own names for the colour labels (Settings): "To Print" for red, say. Empty: the colour's name.
enum LabelNames {
    static let key = "qlick.labelNames"

    static func name(_ label: ColorLabel, defaults: UserDefaults = .standard) -> String {
        let own = (defaults.dictionary(forKey: key) as? [String: String])?[label.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return own.isEmpty ? label.standardName : own
    }

    static func own(_ label: ColorLabel, defaults: UserDefaults = .standard) -> String {
        (defaults.dictionary(forKey: key) as? [String: String])?[label.rawValue] ?? ""
    }

    static func set(_ name: String, for label: ColorLabel, defaults: UserDefaults = .standard) {
        var names = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        names[label.rawValue] = trimmed.isEmpty ? nil : trimmed
        if names.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(names, forKey: key) }
    }
}

/// What a photograph says in words, besides its marks: its colour label, keywords, title and caption. Kept in its
/// sidecar variant (`label`, `keywords`, `title`, `caption`) and, inside a DNG, as `xmp:Label`, `dc:subject`, `dc:title`
/// and `dc:description`.
struct PhotoWords: Equatable, Sendable {
    var label: ColorLabel?
    var keywords: [String] = []
    var title = ""
    var caption = ""

    var isEmpty: Bool { label == nil && keywords.isEmpty && title.isEmpty && caption.isEmpty }

    /// Keywords as typed, cleaned: trimmed, no empty ones, each once (letter case aside), in the order given.
    static func clean(_ keywords: [String]) -> [String] {
        var seen: Set<String> = []
        return keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// What's typed in the Add Keyword field: several at once, separated by commas.
    static func typed(_ text: String) -> [String] { clean(text.components(separatedBy: ",")) }

    func has(keyword: String) -> Bool { keywords.contains { $0.caseInsensitiveCompare(keyword) == .orderedSame } }

    /// Read from a sidecar variant's fields. A label this version doesn't know reads as none (and stays in the file).
    init(fields: [String: JSONValue]) {
        if case .string(let word)? = fields["label"] { label = ColorLabel(word: word) }
        keywords = Self.clean((fields["keywords"]?.array ?? []).compactMap { if case .string(let text) = $0 { text } else { nil } })
        if case .string(let text)? = fields["title"] { title = text }
        if case .string(let text)? = fields["caption"] { caption = text }
    }

    init(label: ColorLabel? = nil, keywords: [String] = [], title: String = "", caption: String = "") {
        self.label = label; self.keywords = keywords; self.title = title; self.caption = caption
    }
}

/// The small round sticker a colour label is drawn as, in every view of the photographs.
struct LabelDot: View {
    let label: ColorLabel
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(label.color)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: max(size * 0.1, 0.8)))
            .frame(width: size, height: size)
            .accessibilityLabel("\(LabelNames.name(label)) label")
    }
}

extension ProjectStore {
    /// Every keyword of the catalogue's Archives, with how many photographs carry it, most used first. Spellings that
    /// differ only in letter case count as one, under the first met.
    func keywordCounts() -> [(word: String, count: Int)] {
        var counts: [String: (word: String, count: Int)] = [:]
        for archive in projects {
            for root in roots(of: archive) {
                guard let stats = stats[folder(root.path, in: archive).id] else { continue }
                for (word, count) in stats.keywords {
                    let key = word.lowercased()
                    counts[key] = (counts[key]?.word ?? word, (counts[key]?.count ?? 0) + count)
                }
            }
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    /// Counts again the Archives' Folders holding `photos`: after their keywords changed.
    func recount(holding photos: [URL]) {
        let paths = Set(photos.map { $0.photoFile.standardizedFileURL.path })
        for archive in projects {
            for root in roots(of: archive) where paths.contains(where: { $0.hasPrefix(root.standardizedFileURL.path + "/") }) {
                count(folder(root.path, in: archive))
            }
        }
    }
}

extension LabState {
    /// ⌘K: the information card where the photographs are (over the sheet, or Develop's), its Add Keyword field
    /// taking the keys.
    func askKeyword() {
        switch workspace {
        case .develop: infoVisible = true
        case .contactSheet: wordsVisible = true
        default:
            guard model.mode == .grid || model.source != nil else { return NSSound.beep() }
            show(model.mode == .grid ? .contactSheet : .develop)
            if model.mode == .grid { wordsVisible = true } else { infoVisible = true }
        }
        keywordFocusPending = true
        keywordFocus += 1
    }
}

/// The colour label of one photograph, as a small menu: its sticker (an empty ring without one), then the five and None.
struct LabelMenu: View {
    let model: EditorModel
    let item: URL
    let label: ColorLabel?

    var body: some View {
        Menu {
            ForEach(ColorLabel.allCases) { choice in
                Button {
                    model.toggleLabel(choice, targets: [item])
                } label: {
                    let key = choice.action.map { "  \(ShortcutStore.display(model.lab.keys.key($0)))" } ?? ""
                    if choice == label { Label(LabelNames.name(choice) + key, systemImage: "checkmark") } else { Text(LabelNames.name(choice) + key) }
                }
            }
            Divider()
            Button("None") { model.setLabel(nil, targets: [item]) }.disabled(label == nil)
        } label: {
            Group {
                if let label { LabelDot(label: label, size: 11) }
                else { Circle().strokeBorder(Theme.dim, lineWidth: 1).frame(width: 11, height: 11) }
            }
            .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(label.map { "Colour label: \(LabelNames.name($0))" } ?? "Colour label")
    }
}

extension LabState {
    /// Colour Label, for the frames' AppKit menus (the sheet, Develop): the five with their keys, and None.
    func labelMenuItem(for targets: [URL]) -> NSMenuItem {
        let menu = NSMenu(title: "Colour Label")
        menu.appearance = NSAppearance(named: .darkAqua)
        let summaries = targets.map { model.library.summary(for: $0) }
        for label in ColorLabel.allCases {
            let item = ClosureMenuItem(LabelNames.name(label)) { [weak self] in self?.model.toggleLabel(label, targets: targets) }
            item.image = MainMenuDots.dot(label)
            if let action = label.action { item.keyEquivalent = keys.key(action); item.keyEquivalentModifierMask = [] }
            let passing = summaries.filter { $0.label == label }.count
            item.state = passing == 0 ? .off : passing == summaries.count ? .on : .mixed
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("None") { [weak self] in self?.model.setLabel(nil, targets: targets) })
        let entry = NSMenuItem(title: "Colour Label", action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }
}

/// The label stickers menus show.
enum MainMenuDots {
    static func dot(_ label: ColorLabel) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            Theme.nsColor(label.hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}

/// The same, for the SwiftUI menus (the grid and the film strip).
struct LabelMenuItems: View {
    let model: EditorModel
    let targets: [URL]

    var body: some View {
        Menu("Colour Label") {
            ForEach(ColorLabel.allCases) { label in
                let all = !targets.isEmpty && targets.allSatisfy { model.library.summary(for: $0).label == label }
                let button = Button { model.toggleLabel(label, targets: targets) } label: {
                    if all { Label(LabelNames.name(label), systemImage: "checkmark") } else { Text(LabelNames.name(label)) }
                }
                if let action = label.action, let key = model.lab.keys.key(action).first {
                    button.keyboardShortcut(KeyEquivalent(key), modifiers: [])
                } else {
                    button
                }
            }
            Divider()
            Button("None") { model.setLabel(nil, targets: targets) }
        }
    }
}
