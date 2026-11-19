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
    // MARK: Notifications

    /// Only an app bundle can post them; never under XCTest.
    static var notificationsAvailable: Bool {
        NSClassFromString("XCTestCase") == nil && Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestNotificationPermission() {
        guard Self.notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyBatchFinished(exported: Int, failed: Int, folder: String) {
        guard Self.notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = failed > 0 ? "Export finished with failures" : "Export finished"
        content.body = (exported == 1 ? "1 photograph" : "\(exported) photographs") + " exported to “\(folder)”" + (failed > 0 ? "; \(failed) failed." : ".")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
