import Foundation

/// Where deleted photographs go: the Trash, keeping where each file landed
/// so Undo can put it back. Tests use a folder of their own.
struct PhotoTrash: Sendable {
    /// Whether `folder`'s volume has a Trash. Without one, a delete is permanent.
    var available: @Sendable (_ folder: URL) -> Bool
    /// Moves `file` to the Trash and returns where it went.
    var trash: @Sendable (_ file: URL) throws -> URL
    /// Deletes `file` at once: on a volume without a Trash.
    var remove: @Sendable (_ file: URL) throws -> Void

    static let system = PhotoTrash(
        available: { folder in
            (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: true)) != nil
        },
        trash: { file in
            var landed: NSURL?
            try FileManager.default.trashItem(at: file, resultingItemURL: &landed)
            return landed as URL? ?? file
        },
        remove: { try FileManager.default.removeItem(at: $0) })
}

/// What a delete does. Photographs go to the Trash with their sidecars, and
/// so with all their duplicates. A duplicate of a photograph that stays is
/// removed from the sidecar, and the file stays.
struct DeletePlan: Equatable, Sendable {
    /// Everything chosen, in order: what Undo selects again.
    private(set) var items: [URL] = []
    private(set) var files: [URL] = []
    private(set) var duplicates: [URL] = []
    /// Duplicates that go with their photographs without being chosen.
    private(set) var following = 0

    var isEmpty: Bool { items.isEmpty }

    /// `duplicates` gives a photograph's duplicates by variant id.
    init(_ chosen: [URL], duplicates ids: (URL) -> [String] = { _ in [] }) {
        var seen = Set<URL>()
        let chosen = chosen.filter { seen.insert($0).inserted }
        files = chosen.filter { $0.variantID == nil }
        let trashed = Set(files)
        duplicates = chosen.filter { $0.variantID != nil && !trashed.contains($0.photoFile) }
        items = chosen.filter { $0.variantID == nil || !trashed.contains($0.photoFile) }
        following = files.reduce(0) { count, file in count + ids(file).filter { !seen.contains(file.variant($0)) }.count }
    }

    /// The same plan without its files: after a permanent delete, only the
    /// duplicates can come back and go again.
    var withoutFiles: DeletePlan {
        var plan = self
        plan.files = []; plan.following = 0; plan.items = duplicates
        return plan
    }

    /// The Undo menu's name for it.
    var actionName: String {
        guard files.isEmpty else { return "Delete from Disk" }
        return duplicates.count > 1 ? "Remove Duplicates" : "Remove Duplicate"
    }
}

/// What a delete moved, filled in once the files have gone; Undo waits for it.
@MainActor final class TrashRecord {
    var moves: [(original: URL, trashed: URL)] = []
    var task: Task<Void, Never>?
}

extension PhotoSidecar {
    /// `raw` without the variant `id`; nil when nothing is left in it.
    static func removing(variant id: String, from raw: JSONValue) throws -> JSONValue? {
        // Decoding checks the schema: a newer file is never written over.
        _ = try PhotoSidecar(raw: raw)
        guard var top = raw.object, var variants = top["variants"]?.array else { return raw }
        variants.removeAll { $0["id"] == .string(id) }
        top["variants"] = .array(variants)
        let plain = variants.isEmpty || variants.count == 1 && Set(variants[0].object.map { Array($0.keys) } ?? []) == ["id"]
        return plain && Set(top.keys).isSubset(of: PhotoSidecar.plainKeys) ? nil : .object(top)
    }
}
