// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import Foundation

/// What an open Box holds besides its own photographs, as it's laid on its shelf above them: each Box inside it an
/// archive box with its name on a label, each Roll a canister with its first frames on the leader.
struct BoxShelfItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case box, roll, smartRoll }
    let kind: Kind
    /// The row of the sidebar it stands for: a drop on it does what a drop on that row does.
    let target: SidebarTarget
    let name: String
    /// Every photograph it holds (a Box's, with everything inside it).
    let count: Int
    /// A Box's Boxes and Rolls.
    var boxes = 0
    var rolls = 0
    /// A Roll's first photographs, by path: the frames out of its canister.
    var leader: [String] = []

    var id: SidebarTarget { target }
    var holder: Holder? { target.holder }

    var drag: LabDragItem {
        switch target {
        case .box(let id): .box(id)
        case .roll(let id, let box): .roll(id, box: box)
        case .archive(let id): .archive(id)
        case .folder(let path, let archive): .folder(path, archive: archive)
        case .archives, .boxes: .finder
        }
    }

    /// The line under its name.
    var detail: String {
        switch kind {
        case .box:
            var parts = [photographs(count)]
            if boxes > 0 { parts.append(boxes == 1 ? "1 Box" : "\(boxes) Boxes") }
            if rolls > 0 { parts.append(rolls == 1 ? "1 Roll" : "\(rolls) Rolls") }
            return parts.joined(separator: " · ")
        case .roll: return photographs(count)
        case .smartRoll: return "Smart Roll · \(count)"
        }
    }
}

/// Where a Box's shelf puts its archive boxes and canisters: on the frames' own columns (a Box as wide as a frame, or
/// as a few when frames are small; a Roll twice that, for its leader), row after row, then a note when the Box holds no
/// photographs of its own, then a little space before them. Pure geometry, like `ContactSheetLayout`, so the contact
/// sheet, the Grid and the tests lay it out the same way.
struct BoxShelfLayout: Equatable, Sendable {
    /// What the shelf says under the objects.
    enum Note: Equatable, Sendable {
        case none
        /// Boxes or Rolls, and no photographs of its own.
        case nothingLoose
        /// Nothing at all in the Box.
        case empty
    }

    /// Under each object: its name and its counts.
    static let nameBand: CGFloat = 38
    static let rowGap: CGFloat = 14
    /// From the last row (or the note) to the photographs: room, and a hairline.
    static let foot: CGFloat = 24
    /// An object is never narrower than this, whatever the frames' size.
    static let smallest: CGFloat = 118
    static let noteLine: CGFloat = 34
    static let emptyBlock: CGFloat = 210

    /// The frames' columns the shelf keeps to.
    let columns: Int
    /// From one column's left edge to the next.
    let pitch: CGFloat
    /// The columns one Box takes (a Roll takes twice as many).
    let unit: Int
    /// One object's drawing: a Box's; a Roll's is as tall, `unit` columns wider.
    let art: CGSize
    /// Each object's place (drawing and names), from the shelf's top left.
    let rects: [CGRect]
    let note: Note
    /// Where the note goes.
    let noteRect: CGRect
    let width: CGFloat
    let height: CGFloat

    /// `spans`: 1 for a Box, 2 for a Roll. `frame` is one frame's picture, `pitch` from one frame to the next, `lead`
    /// the film before the first (the objects start where the frames do); `width` the strips' length.
    init(spans: [Int], width: CGFloat, frame: CGSize, pitch: CGFloat, lead: CGFloat = 0, note: Note = .none) {
        let pitch = max(pitch, frame.width, 1)
        let between = pitch - frame.width
        let columns = max(Int(((width - 2 * lead + between) / pitch).rounded(.down)), 1)
        let unit = min(max(Int(((Self.smallest + between) / pitch).rounded(.up)), 1), columns)
        let artWidth = CGFloat(unit) * pitch - between
        let art = CGSize(width: artWidth.rounded(), height: (artWidth * 2 / 3).rounded())
        var rects: [CGRect] = []
        var column = 0, row = 0
        let rowPitch = art.height + Self.nameBand + Self.rowGap
        for span in spans {
            let take = min(max(span, 1) * unit, columns)
            if column > 0, column + take > columns { column = 0; row += 1 }
            let w = CGFloat(take) * pitch - between
            rects.append(CGRect(x: lead + CGFloat(column) * pitch, y: CGFloat(row) * rowPitch, width: w.rounded(), height: art.height + Self.nameBand))
            column += take
            if column >= columns { column = 0; row += 1 }
        }
        let objects = rects.map(\.maxY).max() ?? 0
        let noteHeight: CGFloat = switch note {
        case .none: 0
        case .nothingLoose: Self.noteLine
        case .empty: Self.emptyBlock
        }
        let noteTop = objects + (rects.isEmpty ? 0 : 8)
        self.columns = columns
        self.pitch = pitch
        self.unit = unit
        self.art = art
        self.rects = rects
        self.note = note
        self.noteRect = CGRect(x: lead, y: noteTop, width: max(width - 2 * lead, 1), height: noteHeight)
        self.width = width
        height = rects.isEmpty && note == .none ? 0 : noteTop + noteHeight + Self.foot
    }

    /// The object under `point`, if any.
    func index(at point: CGPoint) -> Int? { rects.firstIndex { $0.contains(point) } }
}

extension ProjectStore {
    /// What the Box `id` shows on its shelf: its Boxes, then its Rolls (Smart Rolls too), in their order.
    func shelf(of id: UUID) -> [BoxShelfItem] {
        guard let box = box(id) else { return [] }
        var items: [BoxShelfItem] = box.boxes.map { inner in
            BoxShelfItem(kind: .box, target: .box(inner.id), name: inner.name, count: frames(of: .box(inner.id)).count,
                         boxes: inner.boxes.count, rolls: inner.rolls.count)
        }
        for roll in box.rolls {
            let list = frames(of: .roll(roll.id, box: id))
            items.append(BoxShelfItem(kind: roll.isSmart ? .smartRoll : .roll, target: .roll(roll.id, box: id), name: roll.name,
                                      count: list.count, leader: Array(list.prefix(2))))
        }
        return items
    }

    /// The photographs a Box holds itself, in their order (Custom Order kept in `order`), or a Roll's: what its list
    /// shows on the sheet. Those of the Boxes and Rolls inside a Box are on its shelf, not in its list.
    func ownFrames(of holder: Holder) -> [String] {
        switch holder {
        case .box(let id):
            guard let box = box(id) else { return [] }
            var seen: Set<String> = []
            return ManualOrder.ordered(box.frames.filter { seen.insert($0).inserted }, by: box.order)
        case .roll: return frames(of: holder)
        }
    }

    /// Whether a Box holds anything at all: photographs, Boxes or Rolls.
    func holdsAnything(_ id: UUID) -> Bool {
        guard let box = box(id) else { return false }
        return !box.frames.isEmpty || !box.boxes.isEmpty || !box.rolls.isEmpty
    }
}

/// The shelf of the Box open on the sheet: what's on it and what it says.
struct BoxShelfContent: Equatable, Sendable {
    var box: UUID
    var name: String
    var items: [BoxShelfItem]
    var note: BoxShelfLayout.Note
    /// A Box takes one object's width, a Roll two (its leader).
    var spans: [Int] { items.map { $0.kind == .box ? 1 : 2 } }
}

extension LabState {
    /// The shelf of the Box open on the sheet, if a Box is open and there's something to show above its photographs.
    var openShelf: BoxShelfContent? {
        guard case .box(let id)? = openView, let box = projects.box(id) else { return nil }
        let items = projects.shelf(of: id)
        let own = !box.frames.isEmpty
        let note: BoxShelfLayout.Note = own ? .none : items.isEmpty ? .empty : .nothingLoose
        guard !items.isEmpty || note != .none else { return nil }
        return BoxShelfContent(box: id, name: box.name, items: items, note: note)
    }
}
