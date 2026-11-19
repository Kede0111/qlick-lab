// Qlick Lab — GPL-3.0-only.
import Foundation

/// A roll's card, in the roll's own folder: `Roll.qlickroll`, top-level key `qlick` like the sidecars. It holds what a
/// folder can't say (the roll's name, the film loaded, the camera, notes), so they go with the folder when it's
/// copied, moved, or opened in another catalogue or on another Mac. The catalogue keeps a copy for its lists.
struct RollCardFile: Equatable, Sendable {
    static let fileName = "Roll.qlickroll"
    static let schema = 1

    var name = ""
    var film = ""
    var camera = ""
    var notes = ""

    init(name: String = "", film: String = "", camera: String = "", notes: String = "") {
        self.name = name; self.film = film; self.camera = camera; self.notes = notes
    }

    init(_ roll: LabRoll) { self.init(name: roll.name, film: roll.film, camera: roll.camera, notes: roll.notes) }

    /// Nothing worth a card: no film, camera or notes (the name alone is the folder's).
    var isBlank: Bool { film.isEmpty && camera.isEmpty && notes.isEmpty }

    func apply(to roll: inout LabRoll) {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { roll.name = name }
        roll.film = film; roll.camera = camera; roll.notes = notes
    }

    static func file(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// The card in `folder`, if there's one this version can read.
    static func read(in folder: URL) -> RollCardFile? {
        guard let data = try? Data(contentsOf: file(in: folder)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qlick = root["qlick"] as? [String: Any], (qlick["schema"] as? Int ?? 1) <= schema,
              let roll = qlick["roll"] as? [String: Any] else { return nil }
        return RollCardFile(name: roll["name"] as? String ?? "", film: roll["film"] as? String ?? "",
                        camera: roll["camera"] as? String ?? "", notes: roll["notes"] as? String ?? "")
    }

    /// Writes the card into `folder`, over the one there: keys this version doesn't know are kept as found, and a
    /// newer card is left alone.
    @discardableResult func write(in folder: URL) -> Bool {
        let url = Self.file(in: folder)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            root = found
        }
        var qlick = root["qlick"] as? [String: Any] ?? [:]
        if let found = qlick["schema"] as? Int, found > Self.schema { return false }
        qlick["schema"] = Self.schema
        var roll = qlick["roll"] as? [String: Any] ?? [:]
        roll["name"] = name; roll["film"] = film; roll["camera"] = camera; roll["notes"] = notes
        qlick["roll"] = roll
        root["qlick"] = qlick
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
