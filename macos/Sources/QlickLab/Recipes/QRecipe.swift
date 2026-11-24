// Qlick Lab — GPL-3.0-only.
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The `.qrecipe` file shared with QLab (docs/q-formats.md): spektrafilm's saved GUI state (what the engine's
/// `preset_import` reads), plus a `qrecipe` header (stable id, name, origin, dates, revision, engine), the lab's own
/// `qlick` block and QLab's `qlab` block, which the lab keeps as it found it.
enum QRecipe {
    static let fileExtension = "qrecipe"
    static let format = 1
    static var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json }

    /// The engine's revision: the Qlick Lab commit it was built from (`QlickEngineRevision`, written by
    /// scripts/build_app.sh), the same QLab records when it builds the engine from this repository.
    static var engineRevision: String { Bundle.main.object(forInfoDictionaryKey: "QlickEngineRevision") as? String ?? "unknown" }

    /// A formatter per use: `ISO8601DateFormatter` isn't Sendable.
    private static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }

    /// Python's non-finite numbers, carried through the JSON writer as text (as the engine does).
    private static let sentinels: [(Double, String)] = [(.infinity, "\u{1}Infinity"), (-.infinity, "\u{1}-Infinity")]

    /// The file's top level (JSON5: spektrafilm writes `Infinity` and `NaN`).
    static func object(_ data: Data) throws -> [String: Any] {
        guard let top = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw EngineError(message: "A recipe is a JSON object.")
        }
        return top
    }

    /// The header of a recipe file, if it has one.
    static func header(_ data: Data) -> [String: Any]? { (try? object(data))?["qrecipe"] as? [String: Any] }

    /// `data` without its header's id: a copy is a recipe of its own.
    static func withoutID(_ data: Data) -> Data {
        guard var top = try? object(data), var header = top["qrecipe"] as? [String: Any] else { return data }
        header["id"] = nil; header["revision"] = nil; header["created"] = nil
        top["qrecipe"] = header
        return (try? text(top)) ?? data
    }

    /// The recipe's id from its header.
    static func id(_ data: Data) -> String? { (header(data)?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    private static func sentinelled(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues(sentinelled)
        case let a as [Any]: return a.map(sentinelled)
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && !n.doubleValue.isFinite:
            if n.doubleValue.isNaN { return "\u{1}NaN" }
            return sentinels.first { $0.0 == n.doubleValue }?.1 ?? "\u{1}NaN"
        default: return value
        }
    }

    /// `top` as the file's text: sorted keys, pretty-printed, Python's non-finite numbers as bare words.
    static func text(_ top: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: sentinelled(top), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var text = String(decoding: data, as: UTF8.self)
        for (escaped, word) in [("\"\\u0001-Infinity\"", "-Infinity"), ("\"\\u0001Infinity\"", "Infinity"), ("\"\\u0001NaN\"", "NaN")] {
            text = text.replacingOccurrences(of: escaped, with: word)
        }
        return Data((text + "\n").utf8)
    }

    /// The recipe `data` with its header set: `id` and `name` as given, its creation date and origin kept (or this lab's
    /// for a recipe without one), modified now, the engine this lab renders with, and a new revision when the content
    /// changed. Every other key is kept, QLab's included.
    static func stamped(_ data: Data, id: String, name: String, now: Date = Date()) throws -> Data {
        var top = try object(data)
        var header = top["qrecipe"] as? [String: Any] ?? [:]
        let before = header
        header["format"] = format
        header["id"] = id
        header["name"] = name
        header["origin"] = header["origin"] ?? "Qlick Lab"
        header["created"] = header["created"] ?? iso.string(from: now)
        header["engine"] = ["name": "spektrafilm-rs", "revision": engineRevision, "defaultsVersion": SidecarDefaults.latest]
        header["revision"] = nil; header["modified"] = nil
        top["qrecipe"] = header
        let revision = fingerprint(top)
        if (before["revision"] as? String) == revision, let modified = before["modified"] {
            header["modified"] = modified   // the same content: the same revision and date
        } else {
            header["modified"] = iso.string(from: now)
        }
        header["revision"] = revision
        top["qrecipe"] = header
        return try text(top)
    }

    /// What the recipe develops with, as a token: everything but its header (its name, dates and revision), so the
    /// same recipe written by either app compares alike. Nil when it isn't a recipe.
    static func content(_ data: Data) -> String? {
        guard var top = try? object(data) else { return nil }
        top["qrecipe"] = nil
        return fingerprint(top)
    }

    /// An opaque token for the content (docs/q-formats.md: readers compare it, never recompute another app's).
    static func fingerprint(_ top: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: sentinelled(top), options: [.sortedKeys])) ?? Data()
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
