// Qlick Lab — GPL-3.0-only. Part of EditorModel (Develop/EditorModel.swift holds its stored state).
import Accelerate
import AppKit
import CoreVideo
import CryptoKit
import ImageIO
import IOSurface
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension EditorModel {
    // MARK: Image Size

    /// Original develops the source's own pixels; Longest side resizes the
    /// source so the cropped photograph has that many pixels on its longest side.
    func chooseImageSize(_ mode: ImageSize.Mode) {
        switch mode {
        case .original:
            var next = state; next.params[ImageSize.targetPath] = .null
            apply(next, action: "Change Image Size")
        case .longestSide:
            guard imageSizeMode != .longestSide else { return }
            _ = setLongestSide(ImageSize.remembered ?? nativeLongestSide)
        }
    }

    /// The crop's longest side in the source's own pixels, within the field's range.
    var nativeLongestSide: Int {
        let size = crop.size(of: sourceSize == .zero ? placeholderSize : sourceSize)
        let side = Int(max(size.width, size.height))
        return side > 0 ? min(max(side, ImageSize.range.lowerBound), ImageSize.range.upperBound) : 4000
    }

    /// Sets a Longest side target; returns why it can't be used, changing nothing.
    @discardableResult func setLongestSide(_ pixels: Int) -> String? {
        guard ImageSize.range.contains(pixels) else {
            return "Enter a whole number from \(ImageSize.range.lowerBound) to \(ImageSize.range.upperBound.formatted()) px."
        }
        if sourceSize != .zero {
            let working = ImageSize.working(source: sourceSize, target: pixels, crop: crop)
            if ImageSize.exceedsLimit(working: working, source: sourceSize) { return ImageSize.limitMessage(working: working) }
        }
        ImageSize.remembered = pixels
        var next = state; next.params[ImageSize.targetPath] = .number(Double(pixels))
        apply(next, action: "Change Image Size")
        return nil
    }

    /// The photograph and window to reopen at the next launch; the edits are
    /// in the photograph's sidecar (`flushSidecars`). A match solved for the
    /// current settings comes along: without edits nothing else keeps it.
    var session: EditorSession? {
        guard !closing, ready, let source else { return nil }
        var session = EditorSession(source: source, inspectorVisible: inspectorVisible, fitImage: fitImage)
        session.variant = sourceVariant
        if brightnessMatchActive, !brightnessMatchPending, !matchingBrightness {
            session.match = SessionMatch(state.brightnessMatch, file: source)
        }
        return session
    }

    func restore(_ session: EditorSession) throws {
        try session.validate()
        if let state = session.state {
            guard films.contains(where: { $0.id == state.film }), papers.contains(where: { $0.id == state.paper }) else {
                throw EngineError(message: "The previous session uses an unavailable film or paper. Open a photograph to continue.")
            }
        }
        open(session.source, restoring: session)
    }
}
