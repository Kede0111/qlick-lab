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
    // MARK: Cropping

    /// Shows the whole developed photograph, without the border, to crop it.
    func beginCrop() {
        guard !cropping, image != nil, imageSize != .zero else { return }
        holdOriginal(false)
        holdUpsideDown(false)
        // Its tools are in the inspector and the status line.
        leaveImageOnly()
        // The straighten dial takes the label's place.
        endTray(keep: true)
        cropSession = CropSession(start: state, photo: shownImageSize, rotation: imageRotation, source: sourceSize)
    }
    /// A quarter turn, which happens only while cropping (§4.10): from the
    /// menu, or ⌘R / ⌥⌘R, it starts cropping first. Done keeps it with the
    /// crop as one undo step; Cancel turns it back.
    func turn(clockwise: Bool) {
        if !cropping { beginCrop() }
        guard cropping else { return }
        let turns = (Int(value("io.rotate_cw").double) + (clockwise ? 1 : 3)) % 4
        var next = state; next.params["io.rotate_cw"] = .number(Double(turns)); replaceState(next)
    }

    /// Done applies the crop, and any rotation while cropping, as one undo
    /// step. Cancel restores the rotation and keeps the previous crop.
    func endCrop(apply: Bool) {
        guard let session = cropSession else { return }
        // A crop too small for the Longest side stays a draft, with its error shown.
        if apply, session.sizeError != nil { NSSound.beep(); return }
        cropSession = nil
        let rotation = session.start.params["io.rotate_cw"]
        if apply {
            var previous = state; previous.crop = session.start.crop; previous.params["io.rotate_cw"] = rotation
            var next = state; next.crop = session.settings
            if next != previous { registerUndo(restoring: previous, action: "Crop") }
            replaceState(next)
        } else if state.params["io.rotate_cw"] != rotation {
            var next = state; next.params["io.rotate_cw"] = rotation; replaceState(next)
        }
        zoom(fit: true)
    }
}
