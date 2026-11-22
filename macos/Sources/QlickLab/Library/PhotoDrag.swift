// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// What follows the pointer when photographs are dragged, from every view of them (the contact sheet, the grid,
/// Develop's film strip): the first one's picture, the edges of the next behind it, and how many in the pencil's red.
struct PhotoDragPreview: View {
    let image: CGImage?
    let count: Int
    static let side: CGFloat = 104

    var body: some View {
        let size = fitted
        ZStack(alignment: .topTrailing) {
            ZStack {
                if count > 2 { card(size).rotationEffect(.degrees(-7)).offset(x: -7, y: 4) }
                if count > 1 { card(size).rotationEffect(.degrees(5)).offset(x: 6, y: 2) }
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Theme.blank }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.paper.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            }
            .padding(12)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Theme.accent))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var fitted: CGSize {
        guard let image, image.width > 0, image.height > 0 else { return CGSize(width: Self.side, height: Self.side * 2 / 3) }
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        return ratio >= 1 ? CGSize(width: Self.side, height: Self.side / ratio) : CGSize(width: Self.side * ratio, height: Self.side)
    }

    private func card(_ size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(white: 0.16))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.paper.opacity(0.55), lineWidth: 1.2))
            .frame(width: size.width, height: size.height)
    }

    /// The same picture for an AppKit drag (the contact sheet).
    @MainActor static func image(_ image: CGImage?, count: Int, scale: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: PhotoDragPreview(image: image, count: count))
        renderer.scale = scale
        return renderer.nsImage ?? NSImage(size: CGSize(width: side, height: side))
    }
}

extension View {
    /// Photographs dragged from a frame: the selection if the frame is in it, else the frame (`LabState.photoDrag`).
    func photoDrag(_ lab: LabState, _ url: URL, image: CGImage?, count: Int) -> some View {
        onDrag { lab.provider(dragging: lab.photoDrag(from: url)) } preview: { PhotoDragPreview(image: image, count: count) }
    }
}
