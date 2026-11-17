// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// One frame of the source, large. What shows first is the camera's own rendering, read from inside the file. If
/// the frame has a recipe, the engine develops it from the source, with that recipe, and the two lie side by side
/// under a line to drag: what the camera made of it, and what the lab will. There is no other rendering here: the
/// development is the engine's, the same one the photograph gets once imported.
struct ImportLoupe: View {
    let model: EditorModel
    @State private var preview: CGImage?
    @State private var developed: CGImage?
    @State private var shown: URL?
    @State private var developing = false
    @State private var zoomed = false
    @State private var split = 0.5

    private var session: ImportSession { model.lab.importer }

    var body: some View {
        let session = session
        let current = session.current
        let marks = current.map { session.marks(for: $0) } ?? ImportMarks()
        ZStack {
            Color.black
            if let current, let preview, shown == current {
                GeometryReader { geometry in
                    let area = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 28, dy: 54)
                    if zoomed {
                        ScrollView([.horizontal, .vertical]) {
                            picture(preview, marks: marks)
                                .frame(width: CGFloat(preview.width) / 2, height: CGFloat(preview.height) / 2)
                        }
                        .defaultScrollAnchor(.center)
                        .onTapGesture { zoomed = false }
                    } else if area.width > 20, area.height > 20 {
                        let turned = marks.rotation % 2 != 0
                        let aspect = turned ? CGFloat(preview.height) / CGFloat(max(preview.width, 1)) : CGFloat(preview.width) / CGFloat(max(preview.height, 1))
                        let size = aspect > area.width / area.height ? CGSize(width: area.width, height: area.width / aspect) : CGSize(width: area.height * aspect, height: area.height)
                        picture(preview, marks: marks)
                            .frame(width: turned ? size.height : size.width, height: turned ? size.width : size.height)
                            .rotationEffect(.degrees(Double(marks.rotation) * 90))
                            .frame(width: size.width, height: size.height)
                            .overlay { if let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:)) { ImportMark(flag: flag, seed: current.lastPathComponent) } }
                            .opacity(session.included(current) ? 1 : 0.4)
                            .position(x: area.midX, y: area.midY)
                            .onTapGesture { zoomed = true }
                    }
                }
            } else if current != nil {
                ProgressView().controlSize(.small)
            }
            VStack {
                Spacer()
                if let current, let frame = session.frame(current) { caption(frame, marks: marks) }
            }
            .padding(12)
        }
        .task(id: LoupeKey(item: current, recipe: marks.recipe, zoomed: zoomed)) { await load(current, recipe: marks.recipe) }
        .onChange(of: current) { zoomed = false }
    }

    private struct LoupeKey: Hashable { var item: URL?; var recipe: String?; var zoomed: Bool }

    /// The camera's rendering, and over its right part the recipe's development once it's there.
    @ViewBuilder private func picture(_ preview: CGImage, marks: ImportMarks) -> some View {
        let session = session
        if let developed, marks.recipe != nil {
            if session.splitBefore {
                GeometryReader { geometry in
                    let x = geometry.size.width * split
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1).resizable().interpolation(.high)
                        Image(decorative: developed, scale: 1).resizable().interpolation(.high)
                            .mask(alignment: .leading) { Rectangle().padding(.leading, x) }
                        Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1).offset(x: x)
                        Circle().fill(Color.white).frame(width: 18, height: 18).overlay { Image(systemName: "arrow.left.and.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.black) }
                            .position(x: x, y: geometry.size.height / 2)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(max($0.location.x / max(geometry.size.width, 1), 0.02), 0.98) })
                        label("CAMERA").padding(8)
                        label("RECIPE").padding(8).frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
            } else {
                Image(decorative: developed, scale: 1).resizable().interpolation(.high)
            }
        } else {
            Image(decorative: preview, scale: 1).resizable().interpolation(.high)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func caption(_ frame: ImportFrame, marks: ImportMarks) -> some View {
        let session = session
        return HStack(spacing: 12) {
            Text(frame.file.name).font(Q.label(12.5, weight: .semibold)).foregroundStyle(Q.text).fixedSize()
            if let time = frame.time { Text(time.text).font(Q.value(11.5)).foregroundStyle(Color(white: 0.75)) }
            if marks.rating > 0 { Text(String(repeating: "★", count: marks.rating)).font(.system(size: 11)).foregroundStyle(Q.text) }
            if let recipe = marks.recipe {
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                Label(recipe, systemImage: "flask").font(.system(size: 11.5)).foregroundStyle(Q.text).labelStyle(.titleAndIcon).lineLimit(1)
                if developing { ProgressView().controlSize(.mini) }
                else if developed == nil { Text("couldn’t be developed").font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1) }
                Button(session.splitBefore ? "Recipe Only" : "Camera | Recipe") { session.splitBefore.toggle() }.buttonStyle(QPillButtonStyle())
                    .help("The camera’s rendering beside the recipe’s, or the recipe’s alone (\\)")
            } else {
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                Text("Camera’s rendering").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                    .help("The preview the camera wrote into the file. Give the frame a recipe to see it developed.")
            }
            Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
            Button(session.included(frame.id) ? "Imported" : "Left Out") { session.toggleIncluded([frame.id]) }
                .buttonStyle(QPillButtonStyle(active: session.included(frame.id))).help("Whether the import takes this frame (I)")
        }
        .lineLimit(1)
        .padding(.horizontal, 16).frame(height: 38)
        .glass(Capsule())
    }

    private func load(_ item: URL?, recipe: String?) async {
        guard let item else { preview = nil; developed = nil; shown = nil; return }
        if shown != item { developed = nil }
        // The camera's rendering: screen-sized, or whole when its pixels are looked at.
        let pixels = zoomed ? 12_000 : 3200
        let image = await Task.detached(priority: .userInitiated) { ImportScan.preview(of: item, maxPixels: pixels) }.value
        guard !Task.isCancelled, session.current == item else { return }
        preview = image; shown = item
        guard let recipe, let preset = model.presets.first(where: { $0.name == recipe }) else { developed = nil; developing = false; return }
        // The engine's development under the recipe, from the source itself. A moment's wait first, so stepping
        // through a roll doesn't develop every frame passed.
        developing = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, session.current == item else { return }
        let image2 = await model.lab.compareModel.developer.image(.init(item: item, recipe: preset.url, longSide: 2048))
        guard !Task.isCancelled, session.current == item else { return }
        developed = image2
        developing = false
    }
}

/// Two to four frames side by side, moved and enlarged together: which of a run is the sharp one.
struct ImportCompare: View {
    let model: EditorModel
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var dragStart: CGSize?

    private var session: ImportSession { model.lab.importer }

    /// The selection, or the current frame and those after it.
    private var items: [URL] {
        let session = session
        let chosen = session.shown.map(\.id).filter(session.selected.contains)
        if chosen.count >= 2 { return Array(chosen.prefix(4)) }
        guard let current = session.current, let at = session.shown.firstIndex(where: { $0.id == current }) else { return [] }
        return Array(session.shown[at..<min(at + 2, session.shown.count)].map(\.id))
    }

    var body: some View {
        let items = items
        let columns = items.count > 2 ? 2 : max(items.count, 1)
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(items, id: \.self) { item in
                    GeometryReader { geometry in
                        ImportComparePane(session: session, item: item, zoom: zoom, pan: pan, size: geometry.size)
                    }
                    .aspectRatio(items.count > 2 ? 1.5 : nil, contentMode: .fit)
                    .frame(minHeight: items.count > 2 ? 0 : 360)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { withAnimation(Q.quick) { zoom = zoom > 1 ? 1 : 4; if zoom == 1 { pan = .zero } } }
                    .onTapGesture { session.focus(item) }
                }
            }
            .gesture(DragGesture().onChanged { value in
                let start = dragStart ?? pan
                dragStart = start
                pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }.onEnded { _ in dragStart = nil })
            .gesture(MagnifyGesture().onChanged { zoom = min(max($0.magnification * zoom, 1), 12) })
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Text(items.count < 2 ? "Select two to four frames to compare them." : "Double-click enlarges all of them at the same place; drag moves them together.")
                    .font(.system(size: 11)).foregroundStyle(Q.dim)
                Spacer()
                Slider(value: $zoom, in: 1...12).controlSize(.mini).tint(Color(white: 0.75)).frame(width: 130)
                Button("Fit") { withAnimation(Q.quick) { zoom = 1; pan = .zero } }.buttonStyle(QPillButtonStyle())
            }
            .padding(.horizontal, 14).frame(height: 38)
        }
        .background(Color.black)
    }
}

private struct ImportComparePane: View {
    let session: ImportSession
    let item: URL
    let zoom: CGFloat
    let pan: CGSize
    let size: CGSize
    @State private var image: CGImage?

    var body: some View {
        let marks = session.marks(for: item)
        ZStack {
            Color(white: 0.03)
            if let image {
                TurnedPicture(image: image, rotation: marks.rotation, interpolation: .high)
                    .scaleEffect(zoom)
                    .offset(zoom > 1 ? pan : .zero)
                    .opacity(session.included(item) ? 1 : 0.4)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(item.lastPathComponent).font(Q.value(11)).foregroundStyle(Q.text)
                    if marks.rating > 0 { Text(String(repeating: "★", count: marks.rating)).font(.system(size: 10)).foregroundStyle(Q.text) }
                    if let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:)) { MarkGlyph(flag: flag).frame(width: 15, height: 11) }
                    if !session.included(item) { Text("LEFT OUT").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Q.dim) }
                }
                .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Color.black.opacity(0.6))).padding(8)
            }
        }
        .overlay { Rectangle().strokeBorder(session.current == item ? Color.white.opacity(0.7) : .clear, lineWidth: 1) }
        .task(id: item) {
            // The whole of the camera's rendering, so 100 % is its pixels.
            let loaded = await Task.detached(priority: .userInitiated) { ImportScan.preview(of: item, maxPixels: 6000) }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}
