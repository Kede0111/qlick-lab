// Qlick Lab — GPL-3.0-only.
import Foundation

/// A photograph as the lab's rules and searches see it: its file, its marks and words, what its file says of the
/// exposure, its developments, and what its folder's card says. Built from the catalogue's index (`CatalogIndex`)
/// with the marks on screen laid over it.
struct PhotoRecord: Equatable, Sendable {
    var path: String
    var rating = 0
    var flag: PhotoSidecar.Flag?
    var words = PhotoWords()
    var edited = false
    /// The films its developments are on: stock ids and their names.
    var filmsDeveloped: [String] = []
    /// The same, as they're shown: each stock's name (its id when it has none).
    var filmNames: [String] = []
    /// The recipe applied to it last, by name.
    var recipe: String?
    /// The film its folder's card says was loaded.
    var filmLoaded = ""
    var archive = ""
    var camera: String?
    var lens: String?
    var iso: Double?
    /// Seconds.
    var exposure: Double?
    var aperture: Double?
    var focalLength: Double?
    /// Upright, as it's seen.
    var width: Double?
    var height: Double?
    var captured: Date?
    var imported: Date?
    var editedAt: Date?

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var fileType: String { (path as NSString).pathExtension.lowercased() }

    var orientation: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        if abs(width - height) / max(width, height) < 0.02 { return "square" }
        return width > height ? "landscape" : "portrait"
    }
}

/// What a rule or a search term looks at.
enum PhotoField: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain words: the file name, title, caption, keywords, camera, lens, films, recipe, folder and Archive.
    case text
    case rating, flag, label, keyword
    /// The film loaded or a film developed on: the search's `film:`.
    case film
    case filmLoaded, filmDeveloped, recipe
    case camera, lens, focalLength, aperture, shutter, iso
    case captureDate, importDate, editDate
    case fileName, fileType, orientation, developed
    case title, caption, archive, folder

    var id: String { rawValue }

    enum Kind: Sendable { case text, number, date, choice }

    var kind: Kind {
        switch self {
        case .rating, .focalLength, .aperture, .shutter, .iso: .number
        case .captureDate, .importDate, .editDate: .date
        case .flag, .label, .orientation, .developed: .choice
        default: .text
        }
    }

    var title: String {
        switch self {
        case .text: "Any Text"
        case .rating: "Rating"
        case .flag: "Pick or Reject"
        case .label: "Colour Label"
        case .keyword: "Keyword"
        case .film: "Film"
        case .filmLoaded: "Film Loaded"
        case .filmDeveloped: "Film Developed"
        case .recipe: "Recipe"
        case .camera: "Camera"
        case .lens: "Lens"
        case .focalLength: "Focal Length"
        case .aperture: "Aperture"
        case .shutter: "Shutter Speed"
        case .iso: "ISO"
        case .captureDate: "Capture Date"
        case .importDate: "Import Date"
        case .editDate: "Edit Date"
        case .fileName: "File Name"
        case .fileType: "File Type"
        case .orientation: "Orientation"
        case .developed: "Developed"
        case .title: "Title"
        case .caption: "Caption"
        case .archive: "Archive"
        case .folder: "Folder"
        }
    }

    /// The fields a Smart Roll's rules offer, in the editor's order.
    static let editable: [PhotoField] = [.rating, .flag, .label, .keyword, .filmLoaded, .filmDeveloped, .recipe, .developed,
                                         .camera, .lens, .focalLength, .aperture, .shutter, .iso,
                                         .captureDate, .importDate, .editDate,
                                         .fileName, .fileType, .orientation, .title, .caption, .archive, .folder, .text]

    /// A choice field's values and how they're said.
    var choices: [(value: String, title: String)] {
        switch self {
        case .flag: [("pick", "Picked"), ("reject", "Rejected"), ("none", "Unmarked")]
        case .label: ColorLabel.allCases.map { ($0.rawValue, $0.standardName) } + [("none", "No Label")]
        case .orientation: [("landscape", "Landscape"), ("portrait", "Portrait"), ("square", "Square")]
        case .developed: [("yes", "Yes"), ("no", "No")]
        default: []
        }
    }

    var operators: [RuleOperator] {
        switch kind {
        case .text: [.contains, .notContains, .is, .isNot, .startsWith]
        case .number: [.is, .isNot, .greater, .atLeast, .less, .atMost]
        case .date: [.is, .isNot, .greater, .atLeast, .less, .atMost, .inLast]
        case .choice: [.is, .isNot]
        }
    }

    /// What a new rule on this field starts with.
    var startingRule: SmartRule {
        switch kind {
        case .text: SmartRule(field: self, op: .contains, value: "")
        case .number: SmartRule(field: self, op: .atLeast, value: self == .rating ? "3" : "")
        case .date: SmartRule(field: self, op: .inLast, value: "30")
        case .choice: SmartRule(field: self, op: .is, value: choices.first?.value ?? "")
        }
    }

    /// The value's hint in the rule editor.
    var placeholder: String {
        switch self {
        case .rating: "0 to 5"
        case .focalLength: "35"
        case .aperture: "2.8"
        case .shutter: "1/250"
        case .iso: "800"
        case .captureDate, .importDate, .editDate: "2026-09-19"
        case .fileType: "dng"
        case .camera: "M11"
        case .lens: "35"
        case .filmLoaded, .filmDeveloped: "Portra"
        default: ""
        }
    }
}

enum RuleOperator: String, Codable, CaseIterable, Sendable {
    case contains, notContains, `is`, isNot, startsWith, greater, atLeast, less, atMost, inLast

    func title(for kind: PhotoField.Kind) -> String {
        switch (self, kind) {
        case (.contains, _): "contains"
        case (.notContains, _): "doesn’t contain"
        case (.is, _): "is"
        case (.isNot, _): "is not"
        case (.startsWith, _): "starts with"
        case (.greater, .date): "is after"
        case (.atLeast, .date): "is on or after"
        case (.less, .date): "is before"
        case (.atMost, .date): "is on or before"
        case (.greater, _): "is more than"
        case (.atLeast, _): "is at least"
        case (.less, _): "is less than"
        case (.atMost, _): "is at most"
        case (.inLast, _): "is in the last"
        }
    }
}

/// One condition: a field, how it's compared, and with what.
struct SmartRule: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var field: PhotoField
    var op: RuleOperator
    var value: String

    init(field: PhotoField, op: RuleOperator, value: String) {
        self.field = field; self.op = op; self.value = value
    }

    private enum CodingKeys: String, CodingKey { case field, op, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(PhotoField.self, forKey: .field)
        op = try container.decode(RuleOperator.self, forKey: .op)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(op, forKey: .op)
        try container.encode(value, forKey: .value)
    }

    /// Two rules are the same when they say the same thing, whatever their identity in the editor.
    static func == (a: SmartRule, b: SmartRule) -> Bool { a.field == b.field && a.op == b.op && a.value == b.value }
    func hash(into hasher: inout Hasher) { hasher.combine(field); hasher.combine(op); hasher.combine(value) }
}

/// Rules taken together: all of them, any of them, or none of them; groups nest.
struct RuleGroup: Codable, Hashable, Identifiable, Sendable {
    enum Match: String, Codable, CaseIterable, Sendable {
        case all, any, none
        var title: String {
            switch self {
            case .all: "all"
            case .any: "any"
            case .none: "none"
            }
        }
    }

    var id = UUID()
    var match = Match.all
    var rules: [SmartRule] = []
    var groups: [RuleGroup] = []

    init(match: Match = .all, rules: [SmartRule] = [], groups: [RuleGroup] = []) {
        self.match = match; self.rules = rules; self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case match, rules, groups }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decodeIfPresent(Match.self, forKey: .match) ?? .all
        rules = try container.decodeIfPresent([SmartRule].self, forKey: .rules) ?? []
        groups = try container.decodeIfPresent([RuleGroup].self, forKey: .groups) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(match, forKey: .match)
        try container.encode(rules, forKey: .rules)
        if !groups.isEmpty { try container.encode(groups, forKey: .groups) }
    }

    static func == (a: RuleGroup, b: RuleGroup) -> Bool { a.match == b.match && a.rules == b.rules && a.groups == b.groups }
    func hash(into hasher: inout Hasher) { hasher.combine(match); hasher.combine(rules); hasher.combine(groups) }

    var isEmpty: Bool { rules.isEmpty && groups.allSatisfy(\.isEmpty) }

    /// Every rule, at any depth.
    var allRules: [SmartRule] { rules + groups.flatMap(\.allRules) }

    func matches(_ record: PhotoRecord, now: Date = Date()) -> Bool {
        let results = rules.lazy.map { $0.matches(record, now: now) } + groups.lazy.map { $0.matches(record, now: now) }
        switch match {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.isEmpty || results.contains(true)
        case .none: return !results.contains(true)
        }
    }
}

// MARK: Matching

extension SmartRule {
    func matches(_ record: PhotoRecord, now: Date = Date()) -> Bool {
        switch field.kind {
        case .text: return matchesText(record)
        case .number: return matchesNumber(record)
        case .date: return matchesDate(record, now: now)
        case .choice: return matchesChoice(record)
        }
    }

    /// The values a text field holds; several for keywords, films and the plain words.
    static func texts(_ field: PhotoField, of record: PhotoRecord) -> [String] {
        func some(_ text: String?) -> [String] { (text?.isEmpty ?? true) ? [] : [text!] }
        switch field {
        case .text:
            return [record.name, record.words.title, record.words.caption, record.filmLoaded, record.archive, (record.folder as NSString).lastPathComponent]
                + record.words.keywords + record.filmsDeveloped + some(record.camera) + some(record.lens) + some(record.recipe)
        case .keyword: return record.words.keywords
        case .film: return some(record.filmLoaded) + record.filmsDeveloped
        case .filmLoaded: return some(record.filmLoaded)
        case .filmDeveloped: return record.filmsDeveloped
        case .recipe: return some(record.recipe)
        case .camera: return some(record.camera)
        case .lens: return some(record.lens)
        case .fileName: return [record.name]
        case .fileType: return [record.fileType]
        case .title: return some(record.words.title)
        case .caption: return some(record.words.caption)
        case .archive: return some(record.archive)
        case .folder: return [record.folder]
        default: return []
        }
    }

    /// Text as it's compared: letter case and accents aside, an underscore a space (stock ids read as names).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private func matchesText(_ record: PhotoRecord) -> Bool {
        var wanted = Self.fold(value)
        if field == .fileType, wanted.hasPrefix(".") { wanted.removeFirst() }
        let values = Self.texts(field, of: record).map(Self.fold)
        if field == .folder, op == .is || op == .isNot {
            // A folder is the folder and those under it.
            let path = URL(fileURLWithPath: value.trimmingCharacters(in: .whitespaces)).standardizedFileURL.path
            let inside = record.folder == path || record.folder.hasPrefix(path + "/")
            return op == .is ? inside : !inside
        }
        switch op {
        case .contains: return wanted.isEmpty || values.contains { $0.contains(wanted) }
        case .notContains: return wanted.isEmpty || !values.contains { $0.contains(wanted) }
        case .is: return values.contains(wanted) || (wanted.isEmpty && values.isEmpty)
        case .isNot: return !(values.contains(wanted) || (wanted.isEmpty && values.isEmpty))
        case .startsWith: return values.contains { $0.hasPrefix(wanted) }
        default: return false
        }
    }

    /// A number as typed: `3`, `2.8`, `f/2.8`, `35mm`, `1/250`, `2s`.
    static func number(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["f/", "f", "iso"] where text.hasPrefix(prefix) && Double(text.dropFirst(prefix.count)) != nil { text.removeFirst(prefix.count) }
        for suffix in ["mm", "s", "\"", "*", "★"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        text = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if text.allSatisfy({ $0 == "*" || $0 == "★" }) && !text.isEmpty { return Double(text.count) }
        let parts = text.split(separator: "/")
        if parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 { return top / bottom }
        return Double(text)
    }

    private func numberValue(_ record: PhotoRecord) -> Double? {
        switch field {
        case .rating: Double(record.rating)
        case .focalLength: record.focalLength
        case .aperture: record.aperture
        case .shutter: record.exposure
        case .iso: record.iso
        default: nil
        }
    }

    private func matchesNumber(_ record: PhotoRecord) -> Bool {
        guard let wanted = Self.number(value) else { return op == .isNot }
        guard let have = numberValue(record) else { return op == .isNot }
        // Close enough is the same: 1/250 written as 0.004, f/2.8 as 2.79…
        let same = abs(have - wanted) <= (field == .rating ? 0 : abs(wanted) * 0.03 + 1e-9)
        switch op {
        case .is: return same
        case .isNot: return !same
        case .greater: return have > wanted && !same
        case .atLeast: return have > wanted || same
        case .less: return have < wanted && !same
        case .atMost: return have < wanted || same
        default: return false
        }
    }

    /// A period as typed: `2026`, `2026-09`, `2026-09-19` (also with slashes or dots), from its start to the start of
    /// the next, in the Mac's own calendar.
    static func period(_ text: String, calendar: Calendar = .current) -> DateInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { "-/.".contains($0) }).map(String.init)
        guard (1...3).contains(parts.count), let year = Int(parts[0]), parts[0].count == 4 else { return nil }
        var components = DateComponents(year: year, month: 1, day: 1)
        let unit: Calendar.Component
        if parts.count >= 2 {
            guard let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            components.month = month
        }
        if parts.count == 3 {
            guard let day = Int(parts[2]), (1...31).contains(day) else { return nil }
            components.day = day
            unit = .day
        } else {
            unit = parts.count == 2 ? .month : .year
        }
        guard let start = calendar.date(from: components), let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func dateValue(_ record: PhotoRecord) -> Date? {
        switch field {
        case .captureDate: record.captured
        case .importDate: record.imported
        case .editDate: record.editedAt
        default: nil
        }
    }

    private func matchesDate(_ record: PhotoRecord, now: Date) -> Bool {
        guard let have = dateValue(record) else { return op == .isNot }
        if op == .inLast {
            guard let days = Self.number(value), days > 0 else { return false }
            return have >= now.addingTimeInterval(-days * 86_400) && have <= now.addingTimeInterval(60)
        }
        guard let period = Self.period(value) else { return op == .isNot }
        switch op {
        case .is: return have >= period.start && have < period.end
        case .isNot: return !(have >= period.start && have < period.end)
        case .greater: return have >= period.end
        case .atLeast: return have >= period.start
        case .less: return have < period.start
        case .atMost: return have < period.end
        default: return false
        }
    }

    private func matchesChoice(_ record: PhotoRecord) -> Bool {
        let wanted = value.trimmingCharacters(in: .whitespaces).lowercased()
        let have: String? = switch field {
        case .flag: record.flag?.rawValue ?? "none"
        case .label: record.words.label?.rawValue ?? "none"
        case .orientation: record.orientation
        case .developed: record.edited ? "yes" : "no"
        default: nil
        }
        let same = have == wanted
        return op == .isNot ? !same : same
    }
}

// MARK: The search's words

/// The search box's language: plain words, and fields such as `rating:>=3 pick label:red film:portra camera:m11
/// lens:35 iso:>800 aperture:<2.8 date:2026-09 keyword:usa title:… name:… type:dng developed`. Quotes keep words
/// together (`title:"new york"`), a minus before a term leaves its photographs out, `..` makes a range
/// (`date:2026-09-01..2026-09-15`). Several values for one mark (`label:red label:blue`) mean either.
enum PhotoQuery {
    /// The words a field goes by before a colon.
    static let aliases: [String: PhotoField] = [
        "rating": .rating, "stars": .rating, "star": .rating,
        "flag": .flag, "mark": .flag,
        "label": .label, "color": .label, "colour": .label,
        "keyword": .keyword, "keywords": .keyword, "kw": .keyword, "tag": .keyword,
        "film": .film, "loaded": .filmLoaded, "developedon": .filmDeveloped, "stock": .filmDeveloped,
        "recipe": .recipe,
        "camera": .camera, "cam": .camera,
        "lens": .lens,
        "focal": .focalLength, "mm": .focalLength,
        "aperture": .aperture, "f": .aperture,
        "shutter": .shutter, "speed": .shutter,
        "iso": .iso,
        "date": .captureDate, "taken": .captureDate, "captured": .captureDate,
        "imported": .importDate, "import": .importDate,
        "edited": .editDate,
        "name": .fileName, "file": .fileName,
        "type": .fileType, "ext": .fileType,
        "orientation": .orientation, "shape": .orientation,
        "developed": .developed,
        "title": .title, "caption": .caption,
        "archive": .archive, "folder": .folder,
    ]

    /// Words that are a whole term by themselves.
    static let bare: [String: SmartRule] = [
        "pick": SmartRule(field: .flag, op: .is, value: "pick"), "picks": SmartRule(field: .flag, op: .is, value: "pick"),
        "picked": SmartRule(field: .flag, op: .is, value: "pick"),
        "reject": SmartRule(field: .flag, op: .is, value: "reject"), "rejects": SmartRule(field: .flag, op: .is, value: "reject"),
        "rejected": SmartRule(field: .flag, op: .is, value: "reject"),
        "unmarked": SmartRule(field: .flag, op: .is, value: "none"),
        "developed": SmartRule(field: .developed, op: .is, value: "yes"), "edited": SmartRule(field: .developed, op: .is, value: "yes"),
        "undeveloped": SmartRule(field: .developed, op: .is, value: "no"),
        "landscape": SmartRule(field: .orientation, op: .is, value: "landscape"),
        "portrait": SmartRule(field: .orientation, op: .is, value: "portrait"),
        "unrated": SmartRule(field: .rating, op: .is, value: "0"),
    ]

    /// The words of a query, quotes kept together (and taken off).
    static func tokens(_ query: String) -> [String] {
        var tokens: [String] = [], current = "", quoted = false, started = false
        for character in query {
            if character == "\"" || character == "“" || character == "”" {
                quoted.toggle(); started = true
            } else if character.isWhitespace && !quoted {
                if started || !current.isEmpty { tokens.append(current) }
                current = ""; started = false
            } else {
                current.append(character); started = true
            }
        }
        if started || !current.isEmpty { tokens.append(current) }
        return tokens.filter { !$0.isEmpty }
    }

    /// The query as rules, all of which a photograph must meet. Empty for an empty query.
    static func parse(_ query: String, label: (String) -> ColorLabel? = { ColorLabel(word: $0) }) -> RuleGroup {
        var group = RuleGroup(match: .all)
        var either: [PhotoField: [SmartRule]] = [:]
        var order: [PhotoField] = []
        for token in tokens(query) {
            var text = token
            var negated = false
            if text.count > 1, text.hasPrefix("-") || text.hasPrefix("!") { negated = true; text.removeFirst() }
            let rules = terms(text, label: label)
            guard !rules.isEmpty else { continue }
            if negated {
                group.groups.append(RuleGroup(match: .none, rules: rules))
            } else if rules.count == 1, let rule = rules.first, rule.op == .is, [.flag, .label, .fileType, .orientation].contains(rule.field) {
                if either[rule.field] == nil { order.append(rule.field) }
                either[rule.field, default: []].append(rule)
            } else {
                group.rules += rules
            }
        }
        for field in order {
            let rules = either[field] ?? []
            if rules.count == 1 { group.rules += rules } else { group.groups.append(RuleGroup(match: .any, rules: rules)) }
        }
        return group
    }

    /// One term: `field:value` (with its comparison), a word that is a term, or a plain word.
    private static func terms(_ text: String, label: (String) -> ColorLabel?) -> [SmartRule] {
        if let colon = text.firstIndex(of: ":"), let field = aliases[text[..<colon].lowercased()] {
            let value = String(text[text.index(after: colon)...])
            return terms(field: field, value: value, label: label)
        }
        if let rule = bare[text.lowercased()] { return [rule] }
        return [SmartRule(field: .text, op: .contains, value: text)]
    }

    private static func terms(field: PhotoField, value raw: String, label: (String) -> ColorLabel?) -> [SmartRule] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        // A range: from..to, either side may be left open.
        if let range = value.range(of: ".."), field.kind == .number || field.kind == .date {
            let low = String(value[..<range.lowerBound]), high = String(value[range.upperBound...])
            var rules: [SmartRule] = []
            if !low.isEmpty { rules.append(SmartRule(field: field, op: .atLeast, value: low)) }
            if !high.isEmpty { rules.append(SmartRule(field: field, op: .atMost, value: high)) }
            return rules
        }
        var op: RuleOperator?
        for (sign, meaning) in [(">=", RuleOperator.atLeast), ("<=", .atMost), ("!=", .isNot), ("≥", .atLeast), ("≤", .atMost),
                                (">", .greater), ("<", .less), ("=", .is), ("!", .isNot)] where value.hasPrefix(sign) {
            op = meaning
            value = String(value.dropFirst(sign.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        switch field.kind {
        case .text:
            let chosen: RuleOperator = switch op {
            case .is?: .is
            case .isNot?: .isNot
            default: field == .fileType ? .is : .contains
            }
            return [SmartRule(field: field, op: chosen, value: value)]
        case .number:
            guard SmartRule.number(value) != nil else { return [] }
            return [SmartRule(field: field, op: op ?? .is, value: value)]
        case .date:
            if value.lowercased().hasSuffix("d"), let days = Int(value.dropLast()) { return [SmartRule(field: field, op: .inLast, value: String(days))] }
            guard SmartRule.period(value) != nil else { return [] }
            return [SmartRule(field: field, op: op ?? .is, value: value)]
        case .choice:
            let word = value.lowercased()
            let chosen: String?
            switch field {
            case .flag: chosen = ["pick", "picked", "picks"].contains(word) ? "pick" : ["reject", "rejected", "rejects"].contains(word) ? "reject"
                : ["none", "unmarked", "no"].contains(word) ? "none" : nil
            case .label: chosen = ["none", "no"].contains(word) ? "none" : label(value)?.rawValue
            case .orientation: chosen = ["landscape", "horizontal"].contains(word) ? "landscape" : ["portrait", "vertical"].contains(word) ? "portrait"
                : word == "square" ? "square" : nil
            case .developed: chosen = ["yes", "true", "1", "y"].contains(word) ? "yes" : ["no", "false", "0", "n"].contains(word) ? "no" : nil
            default: chosen = nil
            }
            guard let chosen else { return [] }
            return [SmartRule(field: field, op: op == .isNot ? .isNot : .is, value: chosen)]
        }
    }
}
