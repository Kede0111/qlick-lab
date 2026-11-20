// Qlick Lab — GPL-3.0-only.
import AppKit

/// Custom Order: the photographs of a Box or a Roll in the order they're put in by hand, by dragging them on the
/// contact sheet or the grid of that Box or Roll. Kept in `boxes.json` (a Roll's own list, a Box's `order`).
enum ManualOrder {
    /// A path as one spelling: `/private/tmp/…` and `/tmp/…` (and `/private/var`, `/private/etc`) are the same folder,
    /// and the lab meets both (a folder chosen, a path standardized).
    static func canonical(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
    /// `frames` in `order`, those it doesn't name after them in their own order.
    static func ordered(_ frames: [String], by order: [String]?) -> [String] {
        guard let order, !order.isEmpty else { return frames }
        var rank: [String: Int] = [:]
        for (index, path) in order.enumerated() where rank[path] == nil { rank[path] = index }
        return frames.enumerated().sorted { a, b in
            switch (rank[a.element], rank[b.element]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Where photographs dropped at `point` go among `frames` (each photograph's place, in the order shown): before
    /// the nearest one if the point is on its left half, else after it. From 0 to `frames.count`.
    static func slot(_ frames: [CGRect], at point: CGPoint) -> Int {
        guard !frames.isEmpty else { return 0 }
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dy * 4 + dx
        }
        var nearest = 0
        for index in frames.indices where distance(frames[index]) < distance(frames[nearest]) { nearest = index }
        return point.x < frames[nearest].midX ? nearest : nearest + 1
    }

    /// The red line a drop at `slot` shows: in the gap before that photograph, or after the last of its row.
    static func bar(_ frames: [CGRect], slot: Int, gap: CGFloat) -> CGRect? {
        guard !frames.isEmpty else { return nil }
        let width: CGFloat = 3
        if slot < frames.count {
            let frame = frames[slot]
            // The first of a row: the line at its left; otherwise between it and the one before.
            let x = slot > 0 && abs(frames[slot - 1].minY - frame.minY) < 1 ? (frames[slot - 1].maxX + frame.minX) / 2 : frame.minX - gap / 2
            return CGRect(x: x - width / 2, y: frame.minY, width: width, height: frame.height)
        }
        let last = frames[frames.count - 1]
        return CGRect(x: last.maxX + gap / 2 - width / 2, y: last.minY, width: width, height: last.height)
    }

    /// `list` (a holder's order) with `moving` put at `slot` of `shown` (the photographs as they're shown, perhaps
    /// filtered or the other way round): before the first photograph shown from the slot on that doesn't move, or
    /// after the last one before it. The photographs moved keep their order among themselves.
    static func reordered(_ list: [String], shown: [String], moving: [String], slot: Int, ascending: Bool = true) -> [String] {
        let moving = Set(moving)
        var shown = shown, slot = min(max(slot, 0), shown.count)
        if !ascending { shown.reverse(); slot = shown.count - slot }
        let carried = list.filter(moving.contains)
        guard !carried.isEmpty else { return list }
        var rest = list.filter { !moving.contains($0) }
        if let after = shown[slot...].first(where: { !moving.contains($0) }), let at = rest.firstIndex(of: after) {
            rest.insert(contentsOf: carried, at: at)
        } else if let before = shown[..<slot].last(where: { !moving.contains($0) }), let at = rest.firstIndex(of: before) {
            rest.insert(contentsOf: carried, at: at + 1)
        } else {
            return list
        }
        return rest
    }
}

extension LabState {
    /// Whether the photographs dragged can be put in order here: they come from the Box or Roll open on the sheet.
    func canReorder(_ item: LabDragItem?) -> Bool {
        guard let holder = openHolder, case .photos(let photos, let from)? = item, from == holder, !photos.isEmpty else { return false }
        return true
    }

    /// Puts the photographs dragged at `slot` of those shown, in the Box or Roll open, in one undo step; the order
    /// becomes Custom Order so the result shows.
    @discardableResult func reorderOpen(_ photos: [URL], slot: Int, shown: [URL]) -> Bool {
        guard let holder = openHolder else { return false }
        let list = projects.frames(of: holder)
        let custom = sort.key == .custom
        // Matched by one spelling, written back in the list's own.
        var own: [String: String] = [:]
        for path in list { own[ManualOrder.canonical(path)] = path }
        func spelled(_ urls: [URL]) -> [String] { ProjectStore.paths(urls).map { own[ManualOrder.canonical($0)] ?? $0 } }
        let order = ManualOrder.reordered(list, shown: spelled(shown), moving: spelled(photos), slot: slot,
                                          ascending: custom ? sort.ascending : true)
        if !custom { sort = LibrarySort(key: .custom, ascending: true) }
        guard order != list else { return false }
        return undoable("Reorder \(Self.title(photos.count))") { projects.setOrder(order, of: holder); return true }
    }
}
