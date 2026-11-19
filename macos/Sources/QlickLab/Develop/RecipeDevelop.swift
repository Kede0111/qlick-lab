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

    /// "tone, color" for a recipe's summary.
    var summary: String { DevelopGroup.allCases.filter(groups.contains).map(\.word).joined(separator: ", ") }
}

extension RecipeDevelop {
    /// What the tick box does, wherever it shows.
    static let applyHelp = "Recipes saved with Develop settings (white balance, tone, color…) apply them too. Off, a recipe changes the film, the paper and their settings only."
}
