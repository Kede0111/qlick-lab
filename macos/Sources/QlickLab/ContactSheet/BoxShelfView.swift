// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The ink the shelf is drawn in: light lines on the dark sheet, dark ones on the light table.
struct ShelfInk {
    var line: Color
    var hatch: Color
    /// What the objects are filled with, a little off the sheet.
    var fill: Color
    var film: Color
    var hole: Color
    var text: Color
    var dim: Color
    var hairline: Color
    var shadow: Color

    static let dark = ShelfInk(line: Color(white: 0.76), hatch: Color(white: 0.5), fill: Color(white: 0.095), film: Color(white: 0.015),
                               hole: Color(white: 0.2), text: Color(white: 0.9), dim: Color(white: 0.52), hairline: Color.white.opacity(0.07),
                               shadow: Color.black.opacity(0.7))
    static let light = ShelfInk(line: Color(white: 0.14), hatch: Color(white: 0.42), fill: Color(white: 0.97), film: Color(white: 0.05),
                                hole: Color(white: 0.86), text: Color(white: 0.1), dim: Color(white: 0.4), hairline: Color.black.opacity(0.1),
                                shadow: Color.black.opacity(0.18))

    /// The label's paper (the lab's white, Quentin 2026-11-21: no more beige) and the hand that wrote on it.
    static let paper = Theme.paper
    static let handwriting = Color(white: 0.1)
}

/// An open Box's shelf: each Box inside it an archive box with its name on a label, each Roll a 35 mm canister with its
/// first frames on the leader, laid on the frames' columns (`BoxShelfLayout`); then what the Box holds itself, or a
/// word when it holds nothing of its own. A click opens one; photographs, Boxes and Rolls dropped on one go into it as
/// they would on its row of the sidebar.
struct BoxShelfView: View {
    let lab: LabState
    let content: BoxShelfContent
    let layout: BoxShelfLayout
    var light = false

    private var ink: ShelfInk { light ? .light : .dark }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(content.items.enumerated()), id: \.element.id) { index, item in
                if index < layout.rects.count {
                    let rect = layout.rects[index]
                    ShelfObject(lab: lab, item: item, size: rect.size, art: layout.art, ink: ink)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            note
                .frame(width: layout.noteRect.width, height: layout.noteRect.height, alignment: .topLeading)
                .offset(x: layout.noteRect.minX, y: layout.noteRect.minY)
            if content.note != .empty {
                Rectangle().fill(ink.hairline)
                    .frame(width: max(layout.noteRect.width, 1), height: 1)
                    .offset(x: layout.noteRect.minX, y: layout.height - BoxShelfLayout.foot / 2)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .environment(\.colorScheme, light ? .light : .dark)
    }

    @ViewBuilder private var note: some View {
        switch content.note {
        case .none: EmptyView()
        case .nothingLoose:
            Text("No photographs in “\(content.name)” itself. Drag some onto it in the sidebar, or use Add to Box.")
                .font(.system(size: 12)).foregroundStyle(ink.dim)
                .padding(.top, 8)
        case .empty:
            HStack(alignment: .center, spacing: 28) {
                ArchiveBoxArt(name: content.name, size: CGSize(width: 190, height: 140), ink: ink)
                VStack(alignment: .leading, spacing: 8) {
                    Text("“\(content.name)” is empty").font(Theme.title(17)).foregroundStyle(ink.text)
                    Text("Drag photographs onto it in the sidebar, or use Add to Box.\nA Box can hold Boxes and Rolls too.")
                        .font(.system(size: 12.5)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("New Box Inside…") { lab.newBox(in: content.box) }.buttonStyle(QPillButtonStyle())
                        Button("New Roll…") { lab.newRoll(in: content.box) }.buttonStyle(QPillButtonStyle())
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.top, 24)
        }
    }
}

/// One Box or Roll on the shelf: its drawing, then its name and counts. Lit at the pointer; a drop's target in red,
/// with what the drop would do said under it.
struct ShelfObject: View {
    let lab: LabState
    let item: BoxShelfItem
    let size: CGSize
    let art: CGSize
    let ink: ShelfInk
    @State private var hovered = false
    @State private var plan: DropPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch item.kind {
                case .box: ArchiveBoxArt(name: item.name, size: art, ink: ink, lifted: hovered)
                case .roll, .smartRoll: CanisterArt(item: item, size: CGSize(width: size.width, height: art.height), ink: ink, lifted: hovered)
                }
            }
            .frame(width: size.width, height: art.height, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(hovered ? ink.text : ink.text.opacity(0.88))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(Theme.value(10.5)).foregroundStyle(ink.dim).lineLimit(1)
            }
            .padding(.top, 7).padding(.leading, 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.text.opacity(plan != nil && plan?.operation != .refused ? 0.07 : hovered ? 0.04 : 0))
                .overlay {
                    if let plan, plan.operation != .refused {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                    }
                }
                .padding(-7)
        }
        .overlay(alignment: .bottomLeading) {
            if let plan {
                DropLabel(plan: plan).fixedSize().offset(y: 30).allowsHitTesting(false)
            }
        }
        .zIndex(plan != nil ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(Theme.quick, value: hovered)
        .onTapGesture { open() }
        .onDrag { lab.provider(dragging: item.drag) } preview: {
            HStack(spacing: 6) {
                LabGlyphView(glyph: item.kind == .box ? .box : item.kind == .smartRoll ? .smartCanister : .canister, size: 15, color: Theme.accent)
                Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.12)))
            .environment(\.colorScheme, .dark)
        }
        .onDrop(of: [LabDragItem.type], delegate: ShelfDrop(lab: lab, target: item.target, plan: $plan))
        .contextMenu { menu }
        .help(item.kind == .box ? "Open the Box “\(item.name)”" : item.kind == .smartRoll ? "Open the Smart Roll “\(item.name)”: the photographs that meet its rules"
              : "Open the Roll “\(item.name)” on the contact sheet")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind == .box ? "Box" : item.kind == .smartRoll ? "Smart Roll" : "Roll") \(item.name), \(item.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func open() {
        guard let holder = item.holder else { return }
        lab.open(holder.view)
    }

    @ViewBuilder private var menu: some View {
        Button("Open on the Contact Sheet") { open() }
        switch item.target {
        case .box(let id):
            Button("New Box Inside…") { lab.newBox(in: id) }
            Button("New Roll…") { lab.newRoll(in: id) }
            Button("Rename…") { lab.naming = .init(kind: .renameBox(id), name: item.name) }
            Divider()
            Button("Delete the Box…") { lab.deleteBox(id) }
        case .roll(let id, let box):
            if item.kind == .smartRoll { Button("Edit Rules…") { lab.editSmartRoll(id, in: box) } }
            else { RollLookMenu(lab: lab, holder: .roll(id, box: box)) }
            Button("Rename…") { lab.naming = .init(kind: .renameRoll(id, box: box), name: item.name) }
            Divider()
            Button(item.kind == .smartRoll ? "Delete the Smart Roll…" : "Delete the Roll…") { lab.deleteRoll(id, in: box) }
        default: EmptyView()
        }
    }
}

/// A drop on a shelf object: planned as a drop on its row of the sidebar (`ProjectStore.plan`), done the same way.
struct ShelfDrop: DropDelegate {
    let lab: LabState
    let target: SidebarTarget
    @Binding var plan: DropPlan?

    private func item(_ info: DropInfo) -> LabDragItem? { info.hasItemsConforming(to: [LabDragItem.type]) ? lab.dragging : nil }
    private var copying: Bool { NSEvent.modifierFlags.contains(.option) }

    func validateDrop(info: DropInfo) -> Bool { item(info) != nil }
    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let item = item(info) else { plan = nil; return DropProposal(operation: .forbidden) }
        // Into it, never beside it: the middle of the row.
        let next = lab.projects.plan(item, onto: target, at: 0.5, copying: copying)
        if next != plan { plan = next }
        switch next?.operation {
        case .copy?: return DropProposal(operation: .copy)
        case .move?: return DropProposal(operation: .move)
        default: return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) { plan = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { plan = nil }
        guard let item = item(info), let plan = lab.projects.plan(item, onto: target, at: 0.5, copying: copying), plan.operation != .refused else { return false }
        lab.dragging = nil
        lab.perform(plan)
        return true
    }
}

// MARK: Drawings

/// Diagonal pen strokes over `region`, `spacing` apart.
private func hatch(_ context: GraphicsContext, _ region: Path, spacing: CGFloat, color: Color, width: CGFloat, slope: CGFloat = 1) {
    var context = context
    context.clip(to: region)
    let bounds = region.boundingRect
    var lines = Path()
    var x = bounds.minX - bounds.height * abs(slope)
    while x < bounds.maxX + spacing {
        lines.move(to: CGPoint(x: x, y: bounds.maxY))
        lines.addLine(to: CGPoint(x: x + bounds.height * slope, y: bounds.minY))
        x += spacing
    }
    context.stroke(lines, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
}

/// Where the parts of an archive box go in a drawing `size` large: the front, its side going back to the right, the lid
/// overhanging them, the label on the front.
struct ArchiveBoxGeometry {
    let front: CGRect
    let lid: CGRect
    let depth: CGSize
    let label: CGRect
    let line: CGFloat

    init(_ size: CGSize) {
        let height = size.height * 0.8
        let depth = CGSize(width: (height * 0.24).rounded(), height: (height * 0.17).rounded())
        let width = min(height * 1.5, size.width - depth.width - 8)
        let overhang = max(width * 0.025, 2)
        let x = 3 + overhang
        let top = size.height - 5 - height
        let band = (height * 0.21).rounded()
        lid = CGRect(x: x - overhang, y: top, width: width + 2 * overhang, height: band)
        front = CGRect(x: x, y: lid.maxY, width: width, height: height - band)
        self.depth = depth
        label = CGRect(x: front.midX - front.width * 0.33, y: front.minY + front.height * 0.22, width: front.width * 0.66, height: front.height * 0.46)
        line = max(1, size.width / 150)
    }

    func side(of rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX + depth.width, y: rect.minY - depth.height))
            p.addLine(to: CGPoint(x: rect.maxX + depth.width, y: rect.maxY - depth.height))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
        }
    }

    var top: Path {
        Path { p in
            p.move(to: CGPoint(x: lid.minX, y: lid.minY))
            p.addLine(to: CGPoint(x: lid.minX + depth.width, y: lid.minY - depth.height))
            p.addLine(to: CGPoint(x: lid.maxX + depth.width, y: lid.minY - depth.height))
            p.addLine(to: CGPoint(x: lid.maxX, y: lid.minY))
            p.closeSubpath()
        }
    }

    /// The hand hole on the side, as the side's slant draws it.
    var handHole: Path {
        let transform = CGAffineTransform(a: depth.width, b: -depth.height, c: 0, d: front.height, tx: front.maxX, ty: front.minY)
        return Path(roundedRect: CGRect(x: 0.26, y: 0.14, width: 0.48, height: 0.13), cornerRadius: 0.06).applying(transform)
    }
}

/// An archive box, drawn as with a pen: outlined, its sides hatched, the Box's name written by hand on its label.
struct ArchiveBoxArt: View {
    let name: String
    let size: CGSize
    let ink: ShelfInk
    var lifted = false

    var body: some View {
        let g = ArchiveBoxGeometry(size)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in draw(context, g) }
            // The label: paper, a red rule, the name by hand.
            ZStack(alignment: .bottom) {
                Rectangle().fill(ShelfInk.paper)
                Rectangle().fill(Theme.accent.opacity(0.8)).frame(height: max(g.line * 0.9, 1)).padding(.horizontal, g.label.width * 0.08)
                    .padding(.bottom, g.label.height * 0.2)
                Text(name)
                    .font(.custom("Noteworthy-Bold", size: max(g.label.height * 0.42, 9)))
                    .foregroundStyle(ShelfInk.handwriting)
                    .lineLimit(1).minimumScaleFactor(0.45)
                    .padding(.horizontal, g.label.width * 0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, g.label.height * 0.1)
            }
            .frame(width: g.label.width, height: g.label.height)
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 0.8, y: 0.6)
            .rotationEffect(.degrees(-1.6))
            .offset(x: g.label.minX, y: g.label.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .offset(y: lifted ? -2 : 0)
    }

    private func draw(_ context: GraphicsContext, _ g: ArchiveBoxGeometry) {
        let line = GraphicsContext.Shading.color(ink.line)
        let style = StrokeStyle(lineWidth: g.line, lineCap: .round, lineJoin: .round)
        let spacing = max(2.4, size.width / 52)
        // Its shadow on the sheet.
        var shadow = context
        shadow.addFilter(.blur(radius: 5))
        shadow.fill(Path(ellipseIn: CGRect(x: g.front.minX + 4, y: g.front.maxY - 5, width: g.front.width + g.depth.width, height: 10)),
                    with: .color(ink.shadow))
        // The body: its side, then its front.
        let side = g.side(of: g.front)
        context.fill(side, with: .color(ink.fill))
        hatch(context, side, spacing: spacing, color: ink.hatch, width: g.line * 0.6)
        context.stroke(side, with: line, style: style)
        context.fill(g.handHole, with: .color(ink.film))
        context.stroke(g.handHole, with: line, style: style)
        context.fill(Path(g.front), with: .color(ink.fill))
        context.stroke(Path(g.front), with: line, style: style)
        // A few strokes at the foot of the front, the cardboard's shade.
        var foot = Path()
        var x = g.front.minX + spacing
        while x < g.front.maxX - spacing * 0.5 {
            foot.move(to: CGPoint(x: x, y: g.front.maxY - 1))
            foot.addLine(to: CGPoint(x: x + spacing * 0.9, y: g.front.maxY - spacing * 1.4))
            x += spacing * 1.1
        }
        context.stroke(foot, with: .color(ink.hatch.opacity(0.7)), style: StrokeStyle(lineWidth: g.line * 0.5, lineCap: .round))
        // The lid: its side, its band, its top.
        let lidSide = g.side(of: g.lid)
        context.fill(lidSide, with: .color(ink.fill))
        hatch(context, lidSide, spacing: spacing * 0.7, color: ink.hatch, width: g.line * 0.6)
        context.stroke(lidSide, with: line, style: style)
        context.fill(Path(g.lid), with: .color(ink.fill))
        context.stroke(Path(g.lid), with: line, style: style)
        let top = g.top
        context.fill(top, with: .color(ink.fill))
        hatch(context, top, spacing: spacing * 1.8, color: ink.hatch.opacity(0.55), width: g.line * 0.5, slope: -3)
        context.stroke(top, with: line, style: style)
    }
}

/// Where the parts of a canister and its leader go in a drawing `size` large, with `frames` frames on the leader.
struct CanisterGeometry {
    let canister: CGRect
    let body: CGRect
    let caps: [CGRect]
    let knob: CGRect
    let stub: CGRect
    let lip: CGRect
    /// The film out of the lip, to where its tongue starts; then the tongue.
    let strip: CGRect
    let tongue: CGFloat
    let windows: [CGRect]
    let holes: [CGRect]
    let line: CGFloat

    init(_ size: CGSize, frames wanted: Int) {
        let h = size.height * 0.94
        let w = (h * 0.46).rounded()
        let x: CGFloat = 4, y = ((size.height - h) / 2).rounded()
        canister = CGRect(x: x, y: y, width: w, height: h)
        body = CGRect(x: x + w * 0.04, y: y + h * 0.15, width: w * 0.92, height: h * 0.7)
        caps = [CGRect(x: x, y: y + h * 0.065, width: w, height: h * 0.095), CGRect(x: x, y: y + h * 0.84, width: w, height: h * 0.095)]
        knob = CGRect(x: x + w * 0.33, y: y, width: w * 0.34, height: h * 0.075)
        stub = CGRect(x: x + w * 0.38, y: y + h * 0.93, width: w * 0.24, height: h * 0.065)
        lip = CGRect(x: body.maxX - w * 0.03, y: body.minY, width: w * 0.13, height: body.height)
        line = max(1, size.height / 100)
        // Qlick Lab (Quentin, 2026-11-21): the film as wide as the cartridge's body, as a real 35 mm film is; when the
        // leader wouldn't fit, fewer frames on it rather than a narrower film.
        let start = lip.maxX - 1
        func length(_ film: CGFloat, _ frames: Int) -> CGFloat {
            let window = film * 0.66 * 1.5
            return frames == 0 ? film * 0.5 + film * 0.75 : film * 0.22 + CGFloat(frames) * (window + film * 0.12) + film * 0.1 + film * 0.75
        }
        var film = body.height
        let room = size.width - start - 6
        var frames = wanted
        while frames > 0, length(film, frames) > room { frames -= 1 }
        if length(film, frames) > room { film = max(film * room / length(film, frames), 8) }
        let band = film * 0.17
        let window = CGSize(width: film * 0.66 * 1.5, height: film * 0.66)
        let pitch = window.width + film * 0.12
        let top = (y + h / 2 - film / 2).rounded()
        let stripLength = frames == 0 ? film * 0.5 : film * 0.22 + CGFloat(frames) * pitch + film * 0.1
        strip = CGRect(x: start, y: top, width: stripLength, height: film)
        tongue = film * 0.75
        windows = (0..<frames).map { CGRect(x: start + film * 0.22 + CGFloat($0) * pitch, y: top + band, width: window.width, height: window.height) }
        // Eight perforations to a frame, along both edges; the top row stops where the tongue is cut away.
        var holes: [CGRect] = []
        let step = pitch / 8
        let hole = CGSize(width: max(step * 0.52, 1.5), height: max(band * 0.5, 1.5))
        var hx = start + step * 0.6
        while hx + hole.width < strip.maxX + tongue - film * 0.3 {
            // Qlick Lab: the leader's lower half is cut away (as on a real roll and Quentin's reference): the bottom row stops.
            holes.append(CGRect(x: hx, y: top + (band - hole.height) / 2, width: hole.width, height: hole.height))
            if hx + hole.width < strip.maxX - 1 { holes.append(CGRect(x: hx, y: top + film - band + (band - hole.height) / 2, width: hole.width, height: hole.height)) }
            hx += step
        }
        self.holes = holes
    }

    /// The film's outline: the strip, then the tongue, its upper half cut away in a curve.
    var film: Path {
        Path { p in
            // The upper half runs on into the leader; the lower half is cut away in a curve.
            let s = strip, t = tongue, middle = s.maxY - s.height * 0.46, r = s.height * 0.12
            p.move(to: CGPoint(x: s.minX, y: s.maxY))
            p.addLine(to: CGPoint(x: s.maxX, y: s.maxY))
            p.addQuadCurve(to: CGPoint(x: s.maxX + t * 0.36, y: middle), control: CGPoint(x: s.maxX + t * 0.3, y: s.maxY))
            p.addLine(to: CGPoint(x: s.maxX + t - r, y: middle))
            p.addQuadCurve(to: CGPoint(x: s.maxX + t, y: middle - r), control: CGPoint(x: s.maxX + t, y: middle))
            p.addLine(to: CGPoint(x: s.maxX + t, y: s.minY + r))
            p.addQuadCurve(to: CGPoint(x: s.maxX + t - r, y: s.minY), control: CGPoint(x: s.maxX + t, y: s.minY))
            p.addLine(to: CGPoint(x: s.minX, y: s.minY))
            p.closeSubpath()
        }
    }
}

/// A Roll: a 35 mm canister drawn as with a pen, its count printed on it, its first photographs on the leader.
struct CanisterArt: View {
    let item: BoxShelfItem
    let size: CGSize
    let ink: ShelfInk
    var lifted = false
    @State private var images: [String: CGImage] = [:]

    var body: some View {
        let g = CanisterGeometry(size, frames: min(item.leader.count, 2))
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in draw(context, g) }
            ForEach(Array(g.windows.enumerated()), id: \.offset) { index, window in
                if index < item.leader.count, let image = images[item.leader[index]] {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFill()
                        .frame(width: window.width, height: window.height).clipped()
                        .offset(x: window.minX, y: window.minY)
                }
            }
            // What's printed on the canister: its frames' count, and the spark of a Smart Roll.
            VStack(spacing: g.body.height * 0.04) {
                if item.kind == .smartRoll {
                    SparkMark(size: g.body.width * 0.36)
                }
                Text(item.count > 999 ? "999+" : "\(item.count)")
                    .font(Font(SheetFonts.edge(max(g.body.width * 0.28, 8))))
                    .foregroundStyle(ink.line)
                Text("EXP").font(Font(SheetFonts.edge(max(g.body.width * 0.15, 6)))).tracking(0.6).foregroundStyle(ink.dim)
            }
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(width: g.body.width * 0.62, height: g.body.height * 0.56)
            .offset(x: g.body.minX + g.body.width * 0.24, y: g.body.minY + g.body.height * 0.04)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .offset(y: lifted ? -2 : 0)
        .task(id: item.leader) { await load() }
    }

    private func load() async {
        for path in item.leader.prefix(2) where images[path] == nil {
            let file = PhotoFile(url: URL(fileURLWithPath: path))
            let image = await Task.detached(priority: .utility) { await PhotoThumbnails.shared.image(for: file, size: .medium) }.value
            guard !Task.isCancelled else { return }
            if let image { images[path] = image }
        }
    }

    private func draw(_ context: GraphicsContext, _ g: CanisterGeometry) {
        let line = GraphicsContext.Shading.color(ink.line)
        let style = StrokeStyle(lineWidth: g.line, lineCap: .round, lineJoin: .round)
        let spacing = max(2.2, size.height / 40)
        // The shadow under it.
        var shadow = context
        shadow.addFilter(.blur(radius: 4))
        shadow.fill(Path(ellipseIn: CGRect(x: g.canister.minX + 2, y: g.canister.maxY - 4, width: g.canister.width + 4, height: 7)), with: .color(ink.shadow))
        // The film first, so the lip covers its end.
        let film = g.film
        context.fill(film, with: .color(ink.film))
        for window in g.windows { context.fill(Path(roundedRect: window, cornerRadius: 1), with: .color(ink.hole.opacity(0.6))) }
        for hole in g.holes { context.fill(Path(roundedRect: hole, cornerRadius: hole.height * 0.25), with: .color(ink.hole)) }
        context.stroke(film, with: line, style: StrokeStyle(lineWidth: g.line * 0.9, lineJoin: .round))
        // The lip, the body, its shade, the red band of the lab's stock.
        let lip = Path(roundedRect: g.lip, cornerRadius: g.lip.width * 0.4)
        context.fill(lip, with: .color(ink.film))
        context.stroke(lip, with: line, style: style)
        let body = Path(g.body)
        context.fill(body, with: .color(ink.fill))
        hatch(context, Path(CGRect(x: g.body.minX, y: g.body.minY, width: g.body.width * 0.22, height: g.body.height)),
              spacing: spacing * 0.8, color: ink.hatch, width: g.line * 0.6, slope: 4)
        hatch(context, Path(CGRect(x: g.body.minX, y: g.body.minY, width: g.body.width * 0.1, height: g.body.height)),
              spacing: spacing * 0.8, color: ink.hatch, width: g.line * 0.6, slope: -4)
        hatch(context, Path(CGRect(x: g.body.maxX - g.body.width * 0.14, y: g.body.minY, width: g.body.width * 0.14, height: g.body.height)),
              spacing: spacing, color: ink.hatch, width: g.line * 0.6, slope: 4)
        context.fill(Path(CGRect(x: g.body.minX, y: g.body.minY + g.body.height * 0.66, width: g.body.width, height: max(g.body.height * 0.06, 2))),
                     with: .color(Theme.accent))
        context.stroke(body, with: line, style: style)
        // Caps and the spool's knob, knurled: one end only, on top, as a real cartridge.
        for part in [g.knob] {
            let path = Path(roundedRect: part, cornerRadius: part.height * 0.25)
            context.fill(path, with: .color(ink.fill))
            context.stroke(path, with: line, style: style)
        }
        for cap in g.caps {
            let path = Path(roundedRect: cap, cornerRadius: cap.height * 0.35)
            context.fill(path, with: .color(ink.fill))
            var ridges = Path()
            var x = cap.minX + spacing
            while x < cap.maxX - spacing * 0.6 {
                ridges.move(to: CGPoint(x: x, y: cap.minY + cap.height * 0.28))
                ridges.addLine(to: CGPoint(x: x, y: cap.maxY - cap.height * 0.28))
                x += spacing * 1.15
            }
            context.stroke(ridges, with: .color(ink.hatch), style: StrokeStyle(lineWidth: g.line * 0.5, lineCap: .round))
            context.stroke(path, with: line, style: style)
        }
    }
}

/// The spark of a Smart Roll, in the lab's red.
private struct SparkMark: View {
    let size: CGFloat
    var body: some View {
        Canvas { context, canvas in
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2), r = min(canvas.width, canvas.height) / 2, w = r * 0.28
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
            path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
            context.fill(path, with: .color(Theme.accent))
        }
        .frame(width: size, height: size)
    }
}
