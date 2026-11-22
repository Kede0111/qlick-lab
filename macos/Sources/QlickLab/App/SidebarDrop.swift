// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the sidebar as a drop sees it: what it stands for and where it is, in the sidebar's list.
struct SidebarDropRow: Equatable {
    var target: SidebarTarget
    var frame: CGRect
    var depth: Int
    /// The row it unfolds, while it's folded: a drag held over it opens it.
    var folded: SidebarFold.Row?
}

struct SidebarDropRowsKey: PreferenceKey {
    static let defaultValue: [SidebarDropRow] = []
    static func reduce(value: inout [SidebarDropRow], nextValue: () -> [SidebarDropRow]) { value += nextValue() }
}

/// The sidebar's side of a drag: the rows and where they are, the one under the pointer and what a drop there does
/// (the label, the line between rows, the row lit), the folded row that springs open, the scrolling near the edges.
@MainActor @Observable final class SidebarDropModel {
    /// The coordinate space the rows are measured in: the sidebar's list as it's seen (scrolled).
    static let space = "qlick.sidebarDrop"
    /// A drag held this long over a folded row opens it.
    static let springDelay = Duration.milliseconds(700)
    /// How near the list's top or bottom a drag scrolls it.
    static let scrollEdge: CGFloat = 30

    struct Hover: Equatable {
        var row: SidebarDropRow
        var plan: DropPlan?
    }

    /// The row under the pointer and what a drop there does.
    var hover: Hover?
    @ObservationIgnored var rows: [SidebarDropRow] = []
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored private var spring: (row: SidebarFold.Row, task: Task<Void, Never>)?
    @ObservationIgnored private var scroller: Timer?
    @ObservationIgnored private var scrollStep: CGFloat = 0

    func dragStarted() { end() }

    /// The row at `point`, across the whole width of the list.
    func row(at point: CGPoint) -> SidebarDropRow? {
        rows.first { point.y >= $0.frame.minY && point.y < $0.frame.maxY }
    }

    /// The drag is over the list at `point` (`height` tall): what a drop there would do, said by the label and the
    /// pointer; a folded row opens after a moment, the list scrolls near its edges.
    func update(_ item: LabDragItem?, at point: CGPoint, lab: LabState, copying: Bool) -> DropProposal {
        let height = scrollView?.contentView.bounds.height ?? .greatestFiniteMagnitude
        let row = row(at: point)
        let plan: DropPlan? = {
            guard let item, let row else { return nil }
            return lab.projects.plan(item, onto: row.target, at: Double((point.y - row.frame.minY) / max(row.frame.height, 1)), copying: copying)
        }()
        let next = row.map { Hover(row: $0, plan: plan) }
        if next != hover { hover = next }
        springOpen(row?.folded, lab: lab)
        scroll(at: point.y, height: height)
        switch plan?.operation {
        case .copy?: return DropProposal(operation: .copy)
        case .move?: return DropProposal(operation: .move)
        case .refused?: return DropProposal(operation: .forbidden)
        case nil: return DropProposal(operation: item == .finder ? .copy : .forbidden)
        }
    }

    func end() {
        if hover != nil { hover = nil }
        spring?.task.cancel(); spring = nil
        scroller?.invalidate(); scroller = nil
    }

    private func springOpen(_ row: SidebarFold.Row?, lab: LabState) {
        guard spring?.row != row else { return }
        spring?.task.cancel(); spring = nil
        guard let row else { return }
        spring = (row, Task { [weak lab] in
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.quick) { lab?.sidebarFold.unfold(row) }
        })
    }

    private func scroll(at y: CGFloat, height: CGFloat) {
        let edge = Self.scrollEdge
        scrollStep = y < edge ? -(edge - y) / edge * 12 : y > height - edge ? (y - (height - edge)) / edge * 12 : 0
        if scrollStep == 0 { scroller?.invalidate(); scroller = nil; return }
        guard scroller == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scrollTick() } }
        RunLoop.main.add(timer, forMode: .common)
        scroller = timer
    }

    private func scrollTick() {
        guard let scrollView, let document = scrollView.documentView, scrollStep != 0 else { return }
        let clip = scrollView.contentView
        let top: CGFloat = 0
        let bottom = max(document.frame.height - clip.bounds.height, 0)
        // A flipped document scrolls down with a growing y; SwiftUI's is flipped.
        let step = document.isFlipped ? scrollStep : -scrollStep
        let y = min(max(clip.bounds.origin.y + step, top), bottom)
        guard y != clip.bounds.origin.y else { return }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The sidebar list's drops: photographs, rows of the sidebar, folders from the Finder.
struct SidebarDropDelegate: DropDelegate {
    let lab: LabState

    private func item(_ info: DropInfo) -> LabDragItem? {
        if info.hasItemsConforming(to: [LabDragItem.type]) { return lab.dragging }
        if info.hasItemsConforming(to: [.fileURL]) { return .finder }
        return nil
    }

    private var copying: Bool { NSEvent.modifierFlags.contains(.option) }

    func validateDrop(info: DropInfo) -> Bool { item(info) != nil }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        lab.sidebarDrop.update(item(info), at: info.location, lab: lab, copying: copying)
    }

    func dropExited(info: DropInfo) { lab.sidebarDrop.end() }

    func performDrop(info: DropInfo) -> Bool {
        defer { lab.sidebarDrop.end() }
        guard let item = item(info) else { return false }
        let row = lab.sidebarDrop.row(at: info.location)
        if item == .finder {
            let plan = row.flatMap { lab.projects.plan(.finder, onto: $0.target, at: 0.5, copying: false) }
            if case .newArchive? = plan?.action, let plan {
                return LabDrop.load(info.itemProviders(for: [.fileURL])) { [lab] urls in lab.perform(plan, finder: urls) }
            }
            guard plan?.operation != .refused else { return false }
            let archive: UUID? = { if case .importFinder(let id)? = plan?.action { return id }; return nil }()
            return LabDrop.load(info.itemProviders(for: [.fileURL])) { [lab] urls in lab.importFolders(urls, into: archive) }
        }
        guard let row, let plan = lab.projects.plan(item, onto: row.target, at: Double((info.location.y - row.frame.minY) / max(row.frame.height, 1)), copying: copying),
              plan.operation != .refused else { return false }
        lab.dragging = nil
        lab.perform(plan)
        return true
    }
}

extension View {
    /// A row of the sidebar that takes drops (its place is reported to the list) and, with `drags`, can be dragged.
    func sidebarDrop(_ lab: LabState, _ target: SidebarTarget, depth: Int, folded: SidebarFold.Row? = nil, drags: LabDragItem? = nil,
                     symbol: String = "", name: String = "") -> some View {
        modifier(SidebarDropRowModifier(lab: lab, row: SidebarDropRow(target: target, frame: .zero, depth: depth, folded: folded),
                                        drags: drags, symbol: symbol, name: name))
    }
}

private struct SidebarDropRowModifier: ViewModifier {
    let lab: LabState
    let row: SidebarDropRow
    let drags: LabDragItem?
    let symbol: String
    let name: String

    func body(content: Content) -> some View {
        let placed = content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: SidebarDropRowsKey.self,
                                       value: [SidebarDropRow(target: row.target, frame: geometry.frame(in: .named(SidebarDropModel.space)),
                                                              depth: row.depth, folded: row.folded)])
            }
        }
        if let drags {
            placed.onDrag { lab.provider(dragging: drags) } preview: { SidebarDragPreview(symbol: symbol, name: name) }
        } else {
            placed
        }
    }
}

/// A row of the sidebar being dragged: its symbol and name on a dark pill.
struct SidebarDragPreview: View {
    let symbol: String
    let name: String
    var body: some View {
        HStack(spacing: 6) {
            LabSymbol(symbol: symbol, points: 11, color: Theme.accent)
            Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// Over the sidebar's list during a drag: the row a drop goes into, lit with the pencil's red; or the line where a
/// row goes between others; and the label that says what the drop does, or why it's refused.
struct SidebarDropOverlay: View {
    let drop: SidebarDropModel

    var body: some View {
        GeometryReader { geometry in
            if let hover = drop.hover, let plan = hover.plan {
                let frame = hover.row.frame
                ZStack(alignment: .topLeading) {
                    if let line = plan.line {
                        let y = line == .before ? frame.minY : frame.maxY
                        let x = frame.minX + SidebarRowIndent.of(hover.row.depth) + 16
                        Rectangle().fill(Theme.accent).frame(width: max(frame.maxX - x - 6, 10), height: 2)
                            .offset(x: x, y: y - 1)
                        Circle().strokeBorder(Theme.accent, lineWidth: 2).frame(width: 8, height: 8)
                            .offset(x: x - 7, y: y - 4)
                    } else if plan.operation != .refused {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    let below = frame.maxY + 50 < geometry.size.height
                    VStack(alignment: .leading, spacing: 0) {
                        if !below { Spacer(minLength: 0) }
                        DropLabel(plan: plan)
                        if below { Spacer(minLength: 0) }
                    }
                    .padding(.top, below ? frame.maxY + 5 : 0)
                    .padding(.bottom, below ? 0 : geometry.size.height - frame.minY + 5)
                    .padding(.horizontal, 8)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                }
                .animation(Theme.quick, value: hover)
            }
        }
        .allowsHitTesting(false)
    }
}

/// What a drop does, in words: "Move 12 photographs to “Rue”", with the green + of a copy or the arrow of a move; or
/// why it's refused, quieter.
struct DropLabel: View {
    let plan: DropPlan

    var body: some View {
        let refused = plan.operation == .refused
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: refused ? "nosign" : plan.operation == .copy ? "plus.circle.fill" : "arrow.right.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(refused ? Theme.dim : plan.operation == .copy ? Color(red: 0.2, green: 0.78, blue: 0.35) : Theme.accent)
            (Text(plan.verb.isEmpty ? "" : plan.verb + " ").fontWeight(.semibold).foregroundColor(Theme.paper)
                + Text(plan.rest).foregroundColor(refused ? Theme.dim : Color(white: 0.82)))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.06).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(refused ? 0.06 : 0.1)))
        .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
        .environment(\.colorScheme, .dark)
    }
}

/// How far a row of the sidebar steps in at `depth` (`SidebarRow`).
enum SidebarRowIndent {
    static func of(_ depth: Int) -> CGFloat { CGFloat(min(depth, 3)) * 10 + CGFloat(max(depth - 3, 0)) * 6 }
}

/// Finds the sidebar list's scroll view, for the drag's scrolling near the edges.
struct SidebarScrollProbe: NSViewRepresentable {
    let drop: SidebarDropModel
    func makeNSView(context: Context) -> Probe { Probe(drop: drop) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        weak var drop: SidebarDropModel?
        init(drop: SidebarDropModel) { self.drop = drop; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            drop?.scrollView = enclosingScrollView
        }
    }
}
