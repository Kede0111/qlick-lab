// Qlick Lab — GPL-3.0-only.
import Darwin
import Foundation

/// Disks that may stop answering: a network share (a NAS) whose server went away while it stayed mounted, a disk
/// that won't wake. On such a disk any look at a file (does it exist, list a folder) can wait a minute or for ever,
/// and done on the main thread it freezes the lab. The lab asks here first: a disk that doesn't answer within a
/// moment is left aside, without waiting again, until a quiet watch on another thread sees it answer; then
/// `VolumeReach.changed` is posted, and what was skipped is read.
///
/// Only disks under `/Volumes` are watched; the startup disk always answers.
enum VolumeReach {
    /// Posted on the main thread when a disk stops answering or answers again. `userInfo["volume"]`: its path.
    static let changed = Notification.Name("QlickLabVolumeReachChanged")
    /// Told once per disk and launch, on the main thread, when a disk stops answering (the lab says so).
    nonisolated(unsafe) static var stoppedAnswering: (@MainActor (_ volume: URL) -> Void)?

    /// How long a look on the main thread waits before the disk is left aside.
    static let patience: TimeInterval = 0.8

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// Disks that don't answer, by their path, while their watch runs.
        var silent: Set<String> = []
        var told: Set<String> = []
    }
    private static let state = State()
    private static let queue = DispatchQueue(label: "be.jackfrom.qlicklab.volume-reach", qos: .userInitiated, attributes: .concurrent)

    /// The disk a path is on, `/Volumes/Name`; nil on the startup disk.
    static func volume(of path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "/Volumes/" + parts[1]
    }

    /// The disk's name, as the Finder shows it under /Volumes.
    static func volumeName(of path: String) -> String {
        volume(of: path).map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent } ?? "the startup disk"
    }

    /// Offline: the disk `path` is on isn't connected (its /Volumes entry is gone) or doesn't answer. A folder missing
    /// from a disk that's there is not offline: it was moved or removed.
    static func offline(_ path: String) -> Bool {
        guard let volume = volume(of: path) else { return false }
        return isSilent(path) || !FileManager.default.fileExists(atPath: volume)
    }

    /// Whether the disk under `path` is left aside now, without looking.
    static func isSilent(_ path: String) -> Bool {
        guard let volume = volume(of: path) else { return false }
        state.lock.lock(); defer { state.lock.unlock() }
        return state.silent.contains(volume)
    }

    /// Runs `look` on the disk of `path`, waiting at most `patience`. Nil when the disk doesn't answer in time, or
    /// is left aside already: the look isn't made again until it answers.
    static func look<T: Sendable>(_ path: String, patience: TimeInterval = patience, _ look: @escaping @Sendable () -> T) -> T? {
        guard let volume = volume(of: path) else { return look() }
        if isSilent(path) { return nil }
        let box = LookResult<T>(), done = DispatchSemaphore(value: 0)
        queue.async { simulateSilence(volume); box.value = look(); done.signal() }
        // The semaphore orders the write before this read.
        if done.wait(timeout: .now() + patience) == .success { return box.value }
        leaveAside(volume, probe: path)
        return nil
    }

    /// Whether the disk of `path` answers within `patience` (a look at its top).
    /// The path itself is looked at, not only the disk's top: a share whose server has gone may still answer for its
    /// top (kept by the Mac) and never for what's under it.
    static func answers(_ path: String, patience: TimeInterval = patience) -> Bool {
        guard volume(of: path) != nil else { return true }
        return look(path, patience: patience) { var info = stat(); _ = lstat(path, &info); return true } != nil
    }

    /// `fileExists` that never waits long: false on a disk that doesn't answer.
    static func exists(_ path: String, patience: TimeInterval = patience) -> Bool {
        look(path, patience: patience) { FileManager.default.fileExists(atPath: path) } ?? false
    }

    /// `isReadableFile` that never waits long: false on a disk that doesn't answer.
    static func readable(_ path: String, patience: TimeInterval = patience) -> Bool {
        look(path, patience: patience) { FileManager.default.isReadableFile(atPath: path) } ?? false
    }

    /// Whether `url` is a folder; false on a disk that doesn't answer.
    static func isFolder(_ url: URL, patience: TimeInterval = patience) -> Bool {
        look(url.path, patience: patience) { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? false
    }

    private final class LookResult<T>: @unchecked Sendable { var value: T? }

    /// The lab has said already that this disk doesn't answer (the catalogue's own message): not said twice.
    static func said(_ path: String) {
        guard let volume = volume(of: path) else { return }
        state.lock.lock(); state.told.insert(volume); state.lock.unlock()
    }

    // MARK: The watch

    /// `probe`: the path that didn't answer, which the watch keeps asking about (a share may answer for its top and not
    /// for what's under it).
    private static func leaveAside(_ volume: String, probe: String? = nil) {
        let probe = probe ?? volume
        state.lock.lock()
        let new = state.silent.insert(volume).inserted
        state.lock.unlock()
        guard new else { return }
        FileHandle.standardError.write(Data("\(volume) doesn't answer: left aside\n".utf8))
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil, userInfo: ["volume": volume]) }
        // Said once per launch, and only if it still doesn't answer a moment later: a disk waking up isn't news.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            state.lock.lock()
            let tell = state.silent.contains(volume) && state.told.insert(volume).inserted
            state.lock.unlock()
            if tell { MainActor.assumeIsolated { stoppedAnswering?(URL(fileURLWithPath: volume, isDirectory: true)) } }
        }
        // One thread per silent disk, asking again about the path that didn't answer until a look comes back quickly
        // (the server is back, or the share was let go and its path is simply not there).
        Thread.detachNewThread {
            while true {
                let start = Date()
                simulateSilence(volume)
                var info = stat()
                _ = lstat(probe, &info)
                if Date().timeIntervalSince(start) < 2 { break }
                Thread.sleep(forTimeInterval: 3)
            }
            state.lock.lock(); state.silent.remove(volume); state.lock.unlock()
            FileHandle.standardError.write(Data("\(volume) answers again\n".utf8))
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil, userInfo: ["volume": volume]) }
        }
    }

    /// For trying the lab without a NAS to unplug (debug builds only): `QLICK_SILENT_VOLUME=/Volumes/Name` makes every
    /// look at that disk wait as a share whose server has gone does, for `QLICK_SILENT_SECONDS` (20) after launch.
    private static let launched = Date()
    private static func simulateSilence(_ volume: String) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["QLICK_SILENT_VOLUME"] == volume else { return }
        let until = launched.addingTimeInterval(Double(environment["QLICK_SILENT_SECONDS"] ?? "") ?? 20)
        if until > Date() { Thread.sleep(until: until) }
        #endif
    }

    #if DEBUG
    /// For the tests: a disk left aside as if it hadn't answered (its watch then finds it answering at once).
    static func testLeaveAside(_ volume: String) { leaveAside(volume) }
    #endif
}
