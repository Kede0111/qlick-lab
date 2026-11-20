// Qlick Lab — GPL-3.0-only.
import Foundation

/// Qlick Lab: what the Mac lets the work done ahead use. While it saves energy (Low Power Mode) or runs hot (thermal
/// state serious or critical), the lab does only what's on screen and what the next steps open: the thumbnails on
/// screen, in one helper; the previews of the next photographs in the direction of travel; one proxy at a time. The
/// rest waits until the Mac is back to normal. Whatever is asked for by hand, and the photograph being developed, never
/// waits.
struct MachineState: Sendable {
    var lowPower: Bool
    var thermal: ProcessInfo.ThermalState

    /// Hot enough that macOS is slowing the Mac down to cool it.
    var hot: Bool { thermal == .serious || thermal == .critical }
    /// Background work keeps to what's needed soon.
    var saving: Bool { lowPower || hot }

    /// Tests set it; nil reads the Mac.
    nonisolated(unsafe) static var forced: MachineState?

    static var shared: MachineState {
        forced ?? MachineState(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    /// Calls `changed` on the main queue when either changes. Keep the tokens while it should.
    static func observe(_ changed: @escaping @MainActor @Sendable () -> Void) -> [NSObjectProtocol] {
        [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { changed() } }
        }
    }
}
