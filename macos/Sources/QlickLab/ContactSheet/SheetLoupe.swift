// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// A frame seen large over the sheet (Space), as under a loupe: developed by the engine at the size of the window,
/// with its mark, its number and what the file says. It lies on the canvas Compare and Import use (`FrameCanvas`):
/// the wheel and a pinch zoom, 100 % shows its pixels. The arrows and the pencil's keys keep working, so a roll can
/// be sorted from here one frame at a time.
struct SheetLoupe: View {
    let model: EditorModel
    /// The frame it opened on; it then follows the current frame.
    let item: URL
    @State private var image: CGImage?
    @State private var shown: URL?
    @State private var busy = false
    @State private var control = FrameCanvasControl()

    private var lab: LabState { model.lab }
    private var current: URL { model.selection.current ?? item }

    var body: some View {
        let current = current
        let summary = model.library.summary(for: current)
        ZStack {
            Color.black.opacity(0.94)
                .contentShape(Rectangle())
                .onTapGesture { lab.loupe = nil }
            if let image, shown == current {
                FrameCanvas(panes: [.init(image: image, faint: summary.flag == .reject)], reset: current, control: control,
                            onOpen: { _ in model.click(current); lab.show(.develop) },
                            onKey: { event in key(event) })
                    .padding(.horizontal, 24).padding(.top, 60).padding(.bottom, 64)
            }
            VStack {
                HStack {
                    Spacer()
                    FrameZoomControls(control: control).padding(.horizontal, 12).frame(height: 34).glass(Capsule())
                    QIconButton(symbol: "xmark", help: "Close (Space or esc)") { lab.loupe = nil }
                        .padding(6).glass(Circle())
                }
                Spacer()
                LoupeCaption(model: model, item: current, busy: busy)
            }
            .padding(16)
        }
        .task(id: current) { await load(current) }
    }

    /// Keys once the canvas has them: esc closes, the rest are the sheet's own (arrows, marks, Space).
    private func key(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { lab.loupe = nil; return true }
        guard let sheet = lab.sheetView else { return false }
        sheet.keyDown(with: event)
        return true
    }

    private func load(_ item: URL) async {
        busy = true
        defer { if self.current == item { busy = false } }
        // The thumbnail at once, so moving through the roll never shows an empty loupe.
        let file = PhotoFile(url: item.photoFile), edited = model.editedThumbnail(for: item)
        let thumbnail = await Task.detached(priority: .userInitiated) {
            await PhotoThumbnails.shared.image(for: file, size: .large, look: edited?.look, edited: edited?.store)
        }.value
        guard !Task.isCancelled, current == item else { return }
        if let thumbnail { image = thumbnail; shown = item }
        // Then its built preview (Build Previews, or built in the background), cropped and turned: at once when
        // it's there; else built now, ahead of the rest, and kept for the next look and for Develop.
        if let kept = await keptPreview(item) {
            guard !Task.isCancelled, current == item else { return }
            image = kept; shown = item
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, current == item else { return }
        await lab.previewBuilder.ensure(item)
        guard !Task.isCancelled, current == item else { return }
        if let kept = await keptPreview(item) { image = kept; shown = item; return }
        // No preview could be built (no catalog yet): a development of its own.
        let developed = await lab.compareModel.developer.image(.init(item: item, longSide: Int(EditedThumbnailStore.renderLongSide)))
        guard !Task.isCancelled, current == item, let developed else { return }
        image = developed; shown = item
    }

    /// The photograph's kept develop, as its edits crop and turn it.
    private func keptPreview(_ item: URL) async -> CGImage? {
        guard let read = model.keptRender(of: item) else { return nil }
        guard let (whole, _) = await Task.detached(priority: .userInitiated, operation: read).value else { return nil }
        let state = model.labEdits(for: item).state
        let size = CGSize(width: whole.width, height: whole.height)
        return ThumbnailComposer.compose(whole, size: size, crop: state.crop, cut: true, rotation: Int(state.params["io.rotate_cw"].double),
                                         border: nil, texture: nil, strip: nil, longSide: CGFloat(max(whole.width, whole.height)),
                                         space: whole.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? whole
    }
}

private struct LoupeCaption: View {
    let model: EditorModel
    let item: URL
    let busy: Bool

    var body: some View {
        let lab = model.lab
        let summary = model.library.summary(for: item)
        let facts = lab.facts.get(item)
        HStack(spacing: 12) {
            Text(model.library.name(of: item)).font(Theme.caps(12.5, weight: .semibold)).foregroundStyle(Theme.paper)
            if let facts, !facts.exposureLine.isEmpty { Text(facts.exposureLine).font(Theme.value(11.5)).foregroundStyle(Color(white: 0.75)) }
            if let flag = summary.flag { MarkGlyph(flag: flag).frame(width: 17, height: 13) }
            if summary.rating > 0 { Text(String(repeating: "★", count: summary.rating)).font(.system(size: 11)).foregroundStyle(Theme.paper) }
            if let label = summary.label { LabelDot(label: label, size: 10).help(LabelNames.name(label)) }
            if busy { ProgressView().controlSize(.mini) }
            Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
            HStack(spacing: 5) {
                key(lab.keys.key(.pick)); MarkGlyph(flag: .pick).frame(width: 16, height: 12)
                key(lab.keys.key(.reject)).padding(.leading, 6); MarkGlyph(flag: .reject).frame(width: 14, height: 12)
                key("←"); key("→")
            }
        }
        .padding(.horizontal, 16).frame(height: 36)
        .glass(Capsule())
    }

    private func key(_ key: String) -> some View {
        Text(ShortcutStore.display(key)).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.8))
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.white.opacity(0.12)))
    }
}
