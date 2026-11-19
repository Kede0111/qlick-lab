// Qlick Lab — GPL-3.0-only.
import AppKit
import Observation
import SwiftUI

/// The Compare room's canvas (`CompareCanvas`) wherever frames are looked at closely: the contact sheet's loupe, and
/// Import's loupe and comparison. The same wheel, pinch, drag, Fit and 100 %, and a frame's two states split by a line.
struct FrameCanvas: NSViewRepresentable {
    var panes: [CompareCanvas.Pane]
    var split = false
    var focused = 0
    /// When it changes (another frame, other frames), the canvas fits them whole again.
    var reset: AnyHashable
    let control: FrameCanvasControl
    var onOpen: (Int) -> Void = { _ in }
    var onFocus: (Int) -> Void = { _ in }
    /// Keys, once the canvas has them (after a click on it); true if taken.
    var onKey: (NSEvent) -> Bool = { _ in false }

    final class Coordinator {
        var reset: AnyHashable?
        var parent: FrameCanvas
        init(_ parent: FrameCanvas) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CompareCanvas {
        let canvas = CompareCanvas()
        let coordinator = context.coordinator
        control.canvas = canvas
        canvas.onOpen = { coordinator.parent.onOpen($0) }
        canvas.onFocus = { coordinator.parent.onFocus($0) }
        canvas.onKey = { coordinator.parent.onKey($0) }
        canvas.onViewport = { [weak control, weak canvas] viewport in
            control?.zoom = viewport.zoom
            control?.magnification = canvas?.magnification ?? 1
        }
        update(canvas, coordinator)
        return canvas
    }

    func updateNSView(_ canvas: CompareCanvas, context: Context) {
        context.coordinator.parent = self
        update(canvas, context.coordinator)
    }

    private func update(_ canvas: CompareCanvas, _ coordinator: Coordinator) {
        canvas.panes = panes
        if canvas.split != split { canvas.split = split }
        if canvas.focused != focused { canvas.focused = focused }
        if coordinator.reset != reset {
            coordinator.reset = reset
            canvas.zoomToFit()
        }
    }
}

/// Fit, 100 % and the zoom, for the bars round a `FrameCanvas`.
@MainActor @Observable final class FrameCanvasControl {
    @ObservationIgnored weak var canvas: CompareCanvas?
    fileprivate(set) var zoom: CGFloat = 1
    fileprivate(set) var magnification: CGFloat = 1

    var fitted: Bool { abs(zoom - 1) < 0.001 }
    func fit() { canvas?.zoomToFit() }
    func actual() { canvas?.zoomToActual() }
    /// 100 % if it's fitted, fitted otherwise: the loupe key, a double-click's other half.
    func toggle() { fitted ? actual() : fit() }
}

/// Fit, 100 %, the zoom slider and the magnification, as in the Compare room's bar.
struct FrameZoomControls: View {
    let control: FrameCanvasControl

    var body: some View {
        HStack(spacing: 8) {
            Button("Fit") { control.fit() }.buttonStyle(QPillButtonStyle(active: control.fitted))
                .help("The whole frame")
            Button("100 %") { control.actual() }.buttonStyle(QPillButtonStyle(active: abs(control.magnification - 1) < 0.01))
                .help("One pixel of the picture for one pixel of the screen")
            Slider(value: Binding(get: { log2(Double(control.zoom)) }, set: { control.canvas?.setZoom(CGFloat(pow(2, $0))) }), in: -2...5)
                .controlSize(.mini).tint(Color(white: 0.75)).frame(width: 110)
                .help("Zoom; the wheel and a pinch zoom about the pointer, a drag moves the picture")
            Text("\(Int((control.magnification * 100).rounded())) %").font(Theme.value(11.5)).foregroundStyle(Theme.dim).frame(width: 44, alignment: .trailing)
        }
    }
}

extension CGImage {
    /// The picture turned clockwise by quarter turns.
    func turned(_ quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let size = turns % 2 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(self, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage() ?? self
    }
}
