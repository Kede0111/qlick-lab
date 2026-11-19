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
    // MARK: Tone graph

    func toneGraphAppeared(_ shown: Bool) {
        toneGraphsShown = max(0, toneGraphsShown + (shown ? 1 : -1))
        scheduleToneCurve()
    }

    /// Asks the helper for the current settings' curve, one request at a
    /// time; edits made meanwhile ask again once it answers.
    func scheduleToneCurve() {
        guard toneGraphsShown > 0, hasCatalog, engine != nil, !closing else { return }
        guard toneCurveTask == nil else { toneCurveStale = true; return }
        toneCurveTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                toneCurveStale = false
                let snapshot = renderState
                let request: JSONValue = .object(["film": .string(snapshot.film), "paper": .string(snapshot.paper), "params": snapshot.params])
                guard toneCurve?.request != request, let engine else { continue }
                do {
                    let (_, result) = try await engine.request([
                        "command": EngineCommand.toneCurve.json, "film": .string(snapshot.film),
                        "paper": .string(snapshot.paper), "params": snapshot.params, "count": .number(256)])
                    let controls = ToneControls { snapshot.params[$0] }
                    if let curve = ToneCurveData(result, request: request, controls: controls) { toneCurve = curve }
                } catch {
                    // A curve that can't be computed leaves the last one; the render reports errors.
                }
            } while toneCurveStale && !closing
            toneCurveTask = nil
        }
    }

    /// Only mention an update once it has visibly taken a while.
    func scheduleActivity() {
        guard activityTimer == nil, !showsActivity else { return }
        activityTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            // A tried stock's tile is up: the tag only once the develop runs long.
            if self?.trialImage != nil { try? await Task.sleep(for: .milliseconds(1100)) }
            guard let self, !Task.isCancelled else { return }
            self.activityTimer = nil
            if !self.previewCurrent, !self.showingCachedPreview, !self.interacting, !self.renderFailed, self.source != nil {
                self.showsActivity = true
            }
        }
    }
    func hideActivity() {
        activityTimer?.cancel(); activityTimer = nil
        if showsActivity { showsActivity = false }
    }
}
