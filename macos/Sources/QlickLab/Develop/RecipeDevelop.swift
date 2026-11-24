// Qlick Lab — GPL-3.0-only.
import Foundation

/// Qlick Lab: the parts of the Develop tab a recipe can carry, chosen when it's saved.
enum DevelopGroup: String, CaseIterable, Sendable {
    case whiteBalance, brightness, tone, color, detail

    var title: String {
        switch self {
        case .whiteBalance: "White balance"
        case .brightness: "Brightness (Match camera brightness, Exposure, Auto exposure)"
        case .tone: "Tone"
        case .color: "Color"
        case .detail: "Detail"
        }
    }

    /// Its word in a recipe's summary.
    var word: String {
        switch self {
        case .whiteBalance: "white balance"
        case .brightness: "brightness"
        case .tone: "tone"
        case .color: "color"
        case .detail: "detail"
        }
    }

    /// The params it holds. Brightness also holds Match camera brightness, which isn't a param.
    var paths: [String] {
        switch self {
        case .whiteBalance: ["io.raw_white_balance.mode", "io.raw_white_balance.temperature", "io.raw_white_balance.tint"]
        case .brightness: ["prep.exposure_ev", "camera.auto_exposure", "camera.auto_exposure_method"]
        case .tone: ["prep.highlights", "prep.shadows", "prep.contrast", "prep.lift", "prep.gain"]
        case .color: ["prep.color_boost", "prep.saturation"]
        case .detail: ["prep.midtone_detail"]
        }
    }

    /// Its name in a menu or a tick box: short, in the menus' capitals.
    var label: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .brightness: "Brightness"
        case .tone: "Tone"
        case .color: "Color"
        case .detail: "Detail"
        }
    }

    /// The groups a recipe applies of its Develop part, wherever it's applied, as last chosen. Before the choice was
    /// group by group it was one box, all or none: that answer is the first choice.
    static var applied: Set<DevelopGroup> {
        get {
            guard let names = UserDefaults.standard.string(forKey: "recipeAppliesGroups") else {
                return UserDefaults.standard.bool(forKey: "recipeAppliesDevelop") ? Set(allCases) : []
            }
            return Set(names.split(separator: ",").compactMap { DevelopGroup(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        }
        set { UserDefaults.standard.set(allCases.filter(newValue.contains).map(\.rawValue).joined(separator: ","), forKey: "recipeAppliesGroups") }
    }

    /// The groups saved into new recipes, as last chosen: none until chosen.
    static var saved: Set<DevelopGroup> {
        get {
            let names = UserDefaults.standard.string(forKey: "recipeDevelopGroups") ?? ""
            return Set(names.split(separator: ",").compactMap { DevelopGroup(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        }
        set { UserDefaults.standard.set(allCases.filter(newValue.contains).map(\.rawValue).joined(separator: ","), forKey: "recipeDevelopGroups") }
    }
}

/// Qlick Lab: a recipe's Develop part, kept in the recipe file under `"qlick": {"develop": …}`. The engine's
/// `preset_import` reads only the keys of spektrafilm's own settings, so the file still opens there and in spektrafilm.
struct RecipeDevelop: Equatable, Sendable {
    var groups: Set<DevelopGroup>
    /// The groups' params, by path. Exposure is the user's own, above the match when matching.
    var values: [String: JSONValue]
    /// Match camera brightness, with the brightness group.
    var matchBrightness = false

    /// What `state` has in `groups`. `exposureOffset` is the Exposure slider's value (above the match).
    static func taking(_ groups: Set<DevelopGroup>, from state: EditState, exposureOffset: Double) -> RecipeDevelop {
        var values: [String: JSONValue] = [:]
        for group in groups { for path in group.paths { values[path] = state.params[path] } }
        if groups.contains(.brightness) {
            values["prep.exposure_ev"] = .number(state.brightnessMatch != nil ? exposureOffset : state.params["prep.exposure_ev"].double)
        }
        return RecipeDevelop(groups: groups, values: values, matchBrightness: groups.contains(.brightness) && state.brightnessMatch != nil)
    }

    /// `next` (a recipe just applied over `photo`) with this Develop part: its groups from the recipe, the others the
    /// photograph's own, as the Develop tab had them.
    func applied(to next: EditState, photo: EditState) -> EditState {
        var state = next
        for group in DevelopGroup.allCases {
            for path in group.paths {
                let value = groups.contains(group) ? values[path] ?? photo.params[path] : photo.params[path]
                if value != .null { state.params[path] = value }
            }
        }
        if groups.contains(.brightness) {
            // Solved again for the photograph it lands on; the exposure is then above the match.
            state.brightnessMatch = matchBrightness ? BrightnessMatch() : nil
        } else {
            state.brightnessMatch = photo.brightnessMatch
        }
        return state
    }

    /// The Develop part of a recipe's text, or nil (a recipe without one, or spektrafilm's).
    static func read(_ text: String) -> RecipeDevelop? {
        // JSON5 reads Python's Infinity and NaN, which spektrafilm's files may hold.
        guard let data = text.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let develop = (top["qlick"] as? [String: Any])?["develop"] as? [String: Any],
              let names = develop["groups"] as? [String] else { return nil }
        let groups = Set(names.compactMap(DevelopGroup.init(rawValue:)))
        guard !groups.isEmpty else { return nil }
        var values: [String: JSONValue] = [:]
        if let params = develop["params"] as? [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: params),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: encoded) {
            let known = Set(groups.flatMap(\.paths))
            values = decoded.filter { known.contains($0.key) }
        }
        return RecipeDevelop(groups: groups, values: values, matchBrightness: develop["match_brightness"] as? Bool ?? false)
    }

    /// `text` (the engine's `preset_export`) with this Develop part added as its last key. Added as text: the
    /// engine's file may hold `Infinity`, which JSON doesn't.
    func adding(to text: String) -> String {
        var params: [String: JSONValue] = [:]
        for (path, value) in values { params[path] = value }
        let develop: JSONValue = .object([
            "groups": .array(DevelopGroup.allCases.filter(groups.contains).map { .string($0.rawValue) }),
            "params": .object(params),
            "match_brightness": .bool(matchBrightness),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(["version": .number(1), "develop": develop])),
              let json = String(data: data, encoding: .utf8),
              let end = text.lastIndex(of: "}") else { return text }
        let head = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        let indented = json.replacingOccurrences(of: "\n", with: "\n  ")
        return head + (head.hasSuffix("{") ? "" : ",") + "\n  \"qlick\": " + indented + "\n}\n"
    }

    /// This Develop part with only `chosen` of its groups (those applied); nil when none is left.
    func only(_ chosen: Set<DevelopGroup>) -> RecipeDevelop? {
        let kept = groups.intersection(chosen)
        guard !kept.isEmpty else { return nil }
        let paths = Set(kept.flatMap(\.paths))
        return RecipeDevelop(groups: kept, values: values.filter { paths.contains($0.key) }, matchBrightness: kept.contains(.brightness) && matchBrightness)
    }

    /// What it holds of `group`, in words: "5200 K, tint +3", "Matched to the camera, +0.30 EV", "Shadows +8".
    func describe(_ group: DevelopGroup) -> String {
        func number(_ path: String) -> Double? { values[path].flatMap { $0 == .null ? nil : $0.double } }
        func signed(_ value: Double, _ digits: Int = 0) -> String {
            let text = String(format: "%.\(digits)f", abs(value))
            return value > 0 ? "+" + text : value < 0 ? "−" + text : text
        }
        switch group {
        case .whiteBalance:
            let mode = values["io.raw_white_balance.mode"]?.string ?? ""
            guard mode == "custom", let temperature = number("io.raw_white_balance.temperature") else {
                return mode.isEmpty || mode == "as_shot" ? "As shot" : mode.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let tint = number("io.raw_white_balance.tint") ?? 0
            return "\(Int(temperature.rounded())) K" + (abs(tint) >= 0.5 ? ", tint \(signed(tint))" : "")
        case .brightness:
            let exposure = number("prep.exposure_ev") ?? 0
            var words = matchBrightness ? ["Matched to the camera"] : []
            if abs(exposure) >= 0.005 || !matchBrightness { words.append(signed(exposure, 2) + " EV") }
            if values["camera.auto_exposure"]?.bool == true { words.append("auto exposure") }
            return words.joined(separator: ", ")
        default:
            let words = group.paths.compactMap { path -> String? in
                guard let value = number(path), abs(value) >= 0.005 else { return nil }
                let name = (path.split(separator: ".").last.map(String.init) ?? path).replacingOccurrences(of: "_", with: " ")
                return name.prefix(1).uppercased() + name.dropFirst() + " " + signed(value, value.rounded() == value ? 0 : 2)
            }
            return words.isEmpty ? "All at zero" : words.joined(separator: ", ")
        }
    }

    /// "tone, color" for a recipe's summary.
    var summary: String { DevelopGroup.allCases.filter(groups.contains).map(\.word).joined(separator: ", ") }
}

extension RecipeDevelop {
    /// What the tick boxes do, wherever they show.
    static let applyHelp = "Of the Develop settings a recipe was saved with, those ticked are applied too; the others stay the photograph's own. None ticked, a recipe changes the film, the paper and their settings only."

    /// Its `qlick.develop` block, as JSON objects.
    var object: [String: Any] {
        var params: [String: Any] = [:]
        for (path, value) in values {
            if let data = try? JSONEncoder().encode(value),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { params[path] = decoded }
        }
        return ["groups": DevelopGroup.allCases.filter(groups.contains).map(\.rawValue), "params": params, "match_brightness": matchBrightness]
    }
}

/// Qlick Lab: a recipe's text changed in place (Edit Recipe), every key it holds kept: spektrafilm's, QLab's block,
/// `qrecipe`, and any the lab doesn't know (`docs/q-formats.md`). Written back pretty-printed with sorted keys;
/// spektrafilm's `Infinity` and `NaN` stay as they were.
enum RecipeText {
    /// The blocks that aren't the engine's own settings.
    static let ownBlocks: Set<String> = ["qlick", "qlab", "qrecipe"]

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    }

    /// `text` with its Develop part `develop` (nil: none), and, given `look` (the engine's `preset_export` of another
    /// development), the engine's settings taken from it. Nil if `text` isn't a recipe's.
    static func editing(_ text: String, develop: RecipeDevelop?, look: String? = nil) -> String? {
        guard var top = object(text) else { return nil }
        if let look {
            guard let exported = object(look) else { return nil }
            for (key, value) in exported where !ownBlocks.contains(key) { top[key] = value }
        }
        var lab = top["qlick"] as? [String: Any] ?? [:]
        if lab["version"] == nil { lab["version"] = 1 }
        if let develop, !develop.groups.isEmpty { lab["develop"] = develop.object } else { lab["develop"] = nil }
        top["qlick"] = lab
        return write(top, indent: "") + "\n"
    }

    /// JSON as spektrafilm reads it, with `Infinity`, `-Infinity` and `NaN` where the numbers are.
    static func write(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            let entries = object.keys.sorted().map { inner + string($0) + ": " + write(object[$0]!, indent: inner) }
            return "{\n" + entries.joined(separator: ",\n") + "\n" + indent + "}"
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + write($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case let text as String:
            return string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double.isNaN { return "NaN" }
            if double.isInfinite { return double > 0 ? "Infinity" : "-Infinity" }
            let type = String(cString: number.objCType)
            if type != "d" && type != "f" { return number.stringValue }
            return double == double.rounded() && abs(double) < 1e15 ? String(format: "%.1f", double) : "\(double)"
        default:
            return "null"
        }
    }

    private static func string(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }
}
