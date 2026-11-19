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
    // MARK: Presets

    /// The pane header's Adjustments and Presets words, ⌥⌘I and ⌥⌘P: show that panel, or
    /// hide the column if it already shows it.
    /// In Image Only they end it and show that panel.
    func togglePane(_ pane: InspectorPane) {
        if inspectorShown && inspectorPane == pane { inspectorVisible = false } else { showPane(pane) }
    }
    func showPane(_ pane: InspectorPane) { leaveImageOnly(); inspectorPane = pane; inspectorVisible = true }
}
