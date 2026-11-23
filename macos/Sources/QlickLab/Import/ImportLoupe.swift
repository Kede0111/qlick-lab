// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// One frame of the source, large, on the canvas the contact sheet's loupe and the Compare room use (`FrameCanvas`):
/// the wheel and a pinch zoom, 100 % shows its pixels. What shows first is the camera's own rendering, read from
/// inside the file. If the frame has a recipe, the engine develops it from the source, with that recipe, and the two
/// lie side by side under a line to drag: what the camera made of it, and what the lab will. The development is the
/// engine's, the same one the photograph gets once imported. Qlick Lab: a frame QLab developed (its `.qsidecar`) is
/// developed with that sidecar's active version, unless a recipe is chosen for it here.
struct ImportLoupe: View {
    let model: EditorModel
    @State private var preview: CGImage?
    @State private var developed: CGImage?
    @State private var shown: URL?
    @State private var developing = false
    @State private var control = FrameCanvasControl()

    private var session: ImportSession { model.lab.importer }

    var body: some View {
        let session = session
        let current = session.current
        let marks = current.map { session.marks(for: $0) } ?? ImportMarks()
        let development = current.flatMap { session.developments[$0] }
        let developable = marks.recipe != nil || development != nil
        ZStack {
            Color.black
            if let current, let preview, shown == current {
                FrameCanvas(panes: panes(preview, current: current, marks: marks, developing: developable), split: developed != nil && developable && session.splitBefore,
                            reset: current, control: control,
                            onOpen: { _ in control.toggle() },
                            onKey: { ImportKeys.handle($0, model: model) })
                    .padding(.top, 50).padding(.bottom, 58)
                if developed != nil, developable, session.splitBefore {
                    VStack {
                        HStack { label("CAMERA"); Spacer(); label(marks.recipe == nil ? "QLAB" : "RECIPE") }.padding(.horizontal, 12)
                        Spacer()
                    }
                    .padding(.top, 58)
                    .allowsHitTesting(false)
                }
            } else if current != nil {
                ProgressView().controlSize(.small)
            }
            VStack {
                HStack { Spacer(); FrameZoomControls(control: control).padding(.horizontal, 12).frame(height: 34).glass(Capsule()) }
                Spacer()
                if let current, let frame = session.frame(current) { caption(frame, marks: marks, development: development) }
            }
            .padding(10)
        }
        .task(id: LoupeKey(item: current, recipe: marks.recipe, qlab: development != nil, rotation: marks.rotation)) {
            await load(current, recipe: marks.recipe, qlab: development != nil, rotation: marks.rotation)
        }
    }

    private struct LoupeKey: Hashable { var item: URL?; var recipe: String?; var qlab: Bool; var rotation: Int }

    /// The camera's rendering; with a recipe, its development beside it (split) or alone.
    private func panes(_ preview: CGImage, current: URL, marks: ImportMarks, developing: Bool) -> [CompareCanvas.Pane] {
        let faint = !session.included(current) || marks.flag == "reject"
        guard let developed, developing else { return [.init(image: preview, faint: faint)] }
        return session.splitBefore ? [.init(image: preview, faint: faint), .init(image: developed, faint: faint)] : [.init(image: developed, faint: faint)]
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func caption(_ frame: ImportFrame, marks: ImportMarks, development: ImportDevelopment?) -> some View {
        let session = session
        return HStack(spacing: 12) {
            Text(frame.file.name).font(Theme.caps(12.5, weight: .semibold)).foregroundStyle(Theme.paper).fixedSize()
            if let time = frame.time { Text(time.text).font(Theme.value(11.5)).foregroundStyle(Color(white: 0.75)) }
            if let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:)) { MarkGlyph(flag: flag).frame(width: 17, height: 13) }
            if marks.rating > 0 { Text(String(repeating: "★", count: marks.rating)).font(.system(size: 11)).foregroundStyle(Theme.paper) }
            if let recipe = marks.recipe {
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                Label(recipe, systemImage: "flask").font(.system(size: 11.5)).foregroundStyle(Theme.paper).labelStyle(.titleAndIcon).lineLimit(1)
                if developing { ProgressView().controlSize(.mini) }
                else if developed == nil { Text("couldn’t be developed").font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1) }
                Button(session.splitBefore ? "Recipe Only" : "Camera | Recipe") { session.splitBefore.toggle() }.buttonStyle(QPillButtonStyle())
                    .help("The camera’s rendering beside the recipe’s, or the recipe’s alone (\\)")
            } else if let development {
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                Label(development.recipe ?? development.name ?? "Developed in QLab", systemImage: development.recipe == nil ? "iphone" : "flask")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.paper).labelStyle(.titleAndIcon).lineLimit(1)
                    .help(development.recipe.map { "Developed in QLab with the recipe “\($0)”, as it’s imported" } ?? "Developed in QLab, as it’s imported")
                if developing { ProgressView().controlSize(.mini) }
                else if developed == nil { Text("couldn’t be developed").font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1) }
                Button(session.splitBefore ? "QLab Only" : "Camera | QLab") { session.splitBefore.toggle() }.buttonStyle(QPillButtonStyle())
                    .help("The camera’s rendering beside QLab’s development, or QLab’s alone (\\)")
            } else {
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                Text("Camera’s rendering").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
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

    private func load(_ item: URL?, recipe: String?, qlab: Bool, rotation: Int) async {
        guard let item else { preview = nil; developed = nil; shown = nil; return }
        if shown != item { developed = nil }
        // The whole of the camera's rendering, so 100 % is its pixels.
        let image = await Task.detached(priority: .userInitiated) { ImportScan.preview(of: item, maxPixels: 6000)?.turned(rotation) }.value
        guard !Task.isCancelled, session.current == item else { return }
        preview = image; shown = item
        let preset = recipe.flatMap { recipe in model.presets.first { $0.name == recipe } }
        if preset == nil, qlab {
            // QLab's development, from the sidecar beside the frame: the grid's at once if it's made, then larger.
            if developed == nil { developed = session.developed[item]?.turned(rotation) }
            developing = true
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, session.current == item else { return }
            let large = await model.lab.compareModel.developer.image(.init(item: item, longSide: 2048))
            guard !Task.isCancelled, session.current == item else { return }
            developed = large?.turned(rotation) ?? developed
            developing = false
            return
        }
        guard let preset else { developed = nil; developing = false; return }
        // The engine's development under the recipe, from the source itself. A moment's wait first, so stepping
        // through a roll doesn't develop every frame passed.
        developing = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, session.current == item else { return }
        let image2 = await model.lab.compareModel.developer.image(.init(item: item, recipe: preset.url, longSide: 2048))
        guard !Task.isCancelled, session.current == item else { return }
        developed = image2?.turned(rotation)
        developing = false
    }
}

/// Two to four frames side by side on the Compare room's canvas, moved and enlarged together: which of a run is the
/// sharp one.
struct ImportCompare: View {
    let model: EditorModel
    @State private var images: [URL: CGImage] = [:]
    @State private var control = FrameCanvasControl()

    private var session: ImportSession { model.lab.importer }

    /// The selection, or the current frame and the one after it.
    private var items: [URL] {
        let session = session
        let chosen = session.shown.map(\.id).filter(session.selected.contains)
        if chosen.count >= 2 { return Array(chosen.prefix(4)) }
        guard let current = session.current, let at = session.shown.firstIndex(where: { $0.id == current }) else { return [] }
        return Array(session.shown[at..<min(at + 2, session.shown.count)].map(\.id))
    }

    var body: some View {
        let session = session
        let items = items
        let panes = items.map { item in
            CompareCanvas.Pane(image: images[item], busy: images[item] == nil, faint: !session.included(item) || session.marks(for: item).flag == "reject")
        }
        VStack(spacing: 0) {
            ZStack {
                FrameCanvas(panes: panes, focused: items.firstIndex(of: session.current ?? items.first ?? URL(fileURLWithPath: "/")) ?? 0,
                            reset: items, control: control,
                            onOpen: { index in if items.indices.contains(index) { session.focus(items[index]); session.view = .loupe } },
                            onFocus: { index in if items.indices.contains(index) { session.focus(items[index]) } },
                            onKey: { ImportKeys.handle($0, model: model) })
                GeometryReader { geometry in
                    let rects = CompareGeometry.panes(items.count, in: CGRect(origin: .zero, size: geometry.size))
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        if rects.indices.contains(index) {
                            ImportPaneLabel(session: session, item: item, busy: images[item] == nil, names: model.lab.sheet.fileNames)
                                .frame(width: rects[index].width, height: rects[index].height, alignment: .bottomLeading)
                                .offset(x: rects[index].minX, y: rects[index].minY)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                Text(items.count < 2 ? "Select two to four frames to compare them." : "They zoom and move together. Double-click one to see it alone.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
                FrameZoomControls(control: control)
            }
            .padding(.horizontal, 14).frame(height: 40)
        }
        .background(Color.black)
        .task(id: PaneKey(items: items, rotations: items.map { session.marks(for: $0).rotation })) { await load(items) }
    }

    private struct PaneKey: Hashable { var items: [URL]; var rotations: [Int] }

    private func load(_ items: [URL]) async {
        for item in items {
            let rotation = session.marks(for: item).rotation
            // The whole of the camera's rendering, so 100 % is its pixels.
            let image = await Task.detached(priority: .userInitiated) { ImportScan.preview(of: item, maxPixels: 6000)?.turned(rotation) }.value
            guard !Task.isCancelled else { return }
            images[item] = image
        }
        images = images.filter { items.contains($0.key) }
    }
}

/// A pane's name on glass at its foot, with its mark and whether the import takes it.
private struct ImportPaneLabel: View {
    let session: ImportSession
    let item: URL
    let busy: Bool
    let names: SheetOptions.FileNames

    var body: some View {
        let marks = session.marks(for: item)
        HStack(spacing: 8) {
            if names != .off { Text(item.lastPathComponent).font(Theme.value(11)).foregroundStyle(Theme.paper) }
            if let flag = marks.flag.flatMap(PhotoSidecar.Flag.init(rawValue:)) { MarkGlyph(flag: flag).frame(width: 15, height: 11) }
            if marks.rating > 0 { Text(String(repeating: "★", count: marks.rating)).font(.system(size: 10)).foregroundStyle(Theme.paper) }
            if !session.included(item) { Text("LEFT OUT").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.dim) }
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .glass(Capsule())
        .padding(10)
    }
}
