// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

extension EditorModel {
    /// A quarter turn of the photograph, at once; while cropping, with the crop.
    func quarterTurn(clockwise: Bool) {
        if cropping { return turn(clockwise: clockwise) }
        let turns = (Int(value("io.rotate_cw").double) + (clockwise ? 1 : 3)) % 4
        set("io.rotate_cw", .number(Double(turns)))
        zoom(fit: true)
    }

    /// Opens the crop tool if it isn't, and levels the photograph by its lines there, to keep or to cancel.
    func autoStraighten() {
        if !cropping { beginCrop() }
        cropSession?.autoStraighten(image)
    }
}

/// Develop's tools in a bar over the photograph: what the menus hold, at a click (View › Show Toolbar).
struct DevelopToolbar: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        let photo = model.source != nil && !model.renderFailed
        HStack(spacing: 2) {
            group {
                tool("arrow.uturn.backward", "Undo (⌘Z)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                tool("arrow.uturn.forward", "Redo (⇧⌘Z)") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            group {
                tool("rotate.left", "Rotate Left (⌥⌘R)") { model.quarterTurn(clockwise: false) }.disabled(!photo)
                tool("rotate.right", "Rotate Right (⌘R)") { model.quarterTurn(clockwise: true) }.disabled(!photo)
            }
            // The crop tool by name: it also straightens, by hand or by itself.
            group {
                ToolButton(on: model.cropping, help: "Crop and Straighten (R)", action: { model.cropping ? model.endCrop(apply: true) : model.beginCrop() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "crop").font(.system(size: 12, weight: .medium))
                        Text(model.cropping ? "Done" : "Crop").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                }.disabled(!photo)
                tool("level", "Straighten Automatically: levels the photograph by its horizon or its straight lines", action: model.autoStraighten).disabled(!photo)
            }
            group {
                tool(lab.developLoupe ? "plus.magnifyingglass" : "magnifyingglass", "Zoom tool: click zooms in, ⌥-click zooms out; hold Space to move the photograph (Z)", on: lab.developLoupe) {
                    lab.developLoupe.toggle()
                }.disabled(!photo)
                word("Fit", "Fit Photograph (⌘0)", on: model.fitImage) { model.zoom(fit: true) }.disabled(!photo || model.cropping)
                word("1:1", "Actual Size: one pixel of the photograph for one of the screen (⇧⌘1)", on: !model.fitImage && abs(model.zoomShown - 1) < 0.01) {
                    model.canvasScale.zoom(to: 1)
                }.disabled(!photo || model.cropping)
                ZoomSlider(model: model).disabled(!photo || model.cropping)
            }
            // Qlick Lab: before and after are Y (and the status line's word), side by side is Compare's.
            group {
                tool("doc.on.doc", "Copy Edits (⇧⌘C)") { model.copyEdits() }.disabled(!model.canCopyEdits)
                tool("doc.on.clipboard", "Paste Edits (⇧⌘V)") { model.pasteEdits() }.disabled(!model.canPasteEdits)
                tool("arrow.counterclockwise", "Reset All Adjustments") { model.reset() }.disabled(!model.hasCatalog || model.cropping)
            }
            group {
                tool("info.circle", "Photograph Information: what the camera recorded (⌘I)", on: lab.infoVisible) { lab.infoVisible.toggle() }.disabled(!photo)
            }
            Spacer(minLength: 8)
            BackgroundActivity(model: model).padding(.trailing, 8)
            // Qlick Lab: exporting is Print's (⌘3), and File › Export (⇧⌘E).
            group {
                tool("sidebar.left", "Sidebar (Tab)", on: lab.sidebarVisible) { lab.sidebarVisible.toggle() }
                tool("film", "Film Strip (⌥⌘F)", on: model.filmstripVisible) { model.toggleFilmstrip() }
                tool("sidebar.right", "Adjustments (⌥⌘I)", on: model.inspectorVisible) { model.togglePane(.adjustments) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .padding(.trailing, 6)
    }

    private func tool(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        ToolButton(on: on, help: help, action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
    }

    private func word(_ title: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        ToolButton(on: on, help: help, action: action) { Text(title).font(.system(size: 11, weight: on ? .semibold : .medium)) }
    }
}

private struct ToolButton<Label: View>: View {
    let on: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(on ? Color.white : hovered ? Color(white: 0.9) : Color(white: 0.66))
                .frame(minWidth: 28).padding(.horizontal, 2).frame(height: 24)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.85) : hovered ? Color.white.opacity(0.08) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The zoom slider: from fitting to 16 to 1, on a scale of doublings, with the zoom it shows beside it.
/// A click on the figure picks a step from a menu.
private struct ZoomSlider: View {
    let model: EditorModel

    var body: some View {
        let scale = model.canvasScale
        let ratio = model.zoomShown > 0 ? model.zoomShown : 1
        HStack(spacing: 6) {
            Slider(value: Binding(get: { log2(Double(ratio)) },
                                  set: { scale.zoom(to: CGFloat(pow(2, $0))) }), in: -3...4)
                .controlSize(.mini).tint(Theme.accent).frame(width: 96)
                .help("Zoom: drag from an eighth to 16 to 1; scroll or pinch over the photograph")
            Menu {
                Button("Fit") { model.zoom(fit: true) }
                ForEach(CanvasScale.steps, id: \.self) { step in
                    Button(Self.title(step)) { scale.zoom(to: step) }
                }
            } label: {
                Text(model.fitImage ? "Fit" : Self.title(ratio))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.8))
                    .frame(width: 42)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("The zoom; click for its steps")
        }
        .padding(.horizontal, 6)
    }

    static func title(_ ratio: CGFloat) -> String {
        if ratio >= 0.995, abs(ratio - ratio.rounded()) < 0.02 { return "\(Int(ratio.rounded())):1" }
        if abs(ratio - 2.0 / 3) < 0.01 { return "2:3" }
        let inverse = 1 / ratio
        if ratio < 1, abs(inverse - inverse.rounded()) < 0.03 { return "1:\(Int(inverse.rounded()))" }
        return "\(Int((ratio * 100).rounded())) %"
    }
}
