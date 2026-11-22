// Qlick Lab — GPL-3.0-only.
import Darwin
import Foundation

/// The disks under /Volumes: a disk plugged in, a memory card, a share on the network (a NAS).
///
/// A disk is away (`offline`) only when it truly is: it isn't mounted any more (unplugged, ejected, a share let go),
/// or the Mac itself has said a share has stopped answering (its server or the network gone: the system's
/// "not responding" event, the one behind the Finder's "Server connections interrupted"). A disk that is only slow
/// (a NAS on 1 Gb/s saturated by the lab's own reading, an exFAT disk busy writing, a card reader) is never away:
/// the lab reads and writes on it at its own speed.
///
/// What a slow disk must not do is hold up the window. So a look made on the main thread waits a moment
/// (`patience`); past it, the answer isn't known yet and the caller carries on as if the file were there (the work
/// that reads it, off the main thread, finds out). The look goes on in the background; until it comes back, the
/// main thread doesn't wait on that disk again, and when it does come back `VolumeReach.changed` is posted, so
/// what was taken on trust is read again. Off the main thread, a look is simply made, at the disk's speed.
///
/// Nothing here asks a disk whether it's there: the mount list (`getfsstat`, `MNT_NOWAIT`) and the system's events
/// (`EVFILT_FS`) come from the Mac, not from the disk.
enum VolumeReach {
    /// Posted on the main thread when a disk comes or goes, stops answering or answers again, or a slow look on it
    /// came back. `userInfo["volume"]`: its path.
    static let changed = Notification.Name("QlickLabVolumeReachChanged")
    /// Told once per disk and launch, on the main thread, when the Mac says a share has stopped answering.
    nonisolated(unsafe) static var stoppedAnswering: (@MainActor (_ volume: URL) -> Void)?

    /// How long a look on the main thread waits for its answer before the window carries on without it.
    static let patience: TimeInterval = 0.8

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// Shares the Mac says don't answer, by their path.
        var silent: Set<String> = []
        /// Disks with a look from the main thread still out: the main thread doesn't wait on them again meanwhile.
        var busy: Set<String> = []
        /// Shares being asked, after the Mac said one stopped answering.
        var asking: Set<String> = []
        var told: Set<String> = []
        /// Mount points, as the Mac lists them; nil until first read, then kept by the system's events.
        var mounted: [String: Bool]?
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

    /// Offline: the disk `path` is on isn't mounted, or the Mac says it doesn't answer. Never because it's slow. A
    /// folder missing from a disk that's there is not offline: it was moved or removed.
    static func offline(_ path: String) -> Bool {
        guard let volume = volume(of: path) else { return false }
        return isSilent(path) || !isMounted(volume)
    }

    /// Whether the Mac says the share under `path` doesn't answer.
    static func isSilent(_ path: String) -> Bool {
        guard let volume = volume(of: path) else { return false }
        _ = watchOnce
        state.lock.lock(); defer { state.lock.unlock() }
        return state.silent.contains(volume)
    }

    /// Runs `look` on the disk of `path`. Off the main thread it's simply made. On the main thread it waits at most
    /// `patience`, and nil means the answer isn't known yet (the disk is slow): the look finishes in the background
    /// and `changed` is posted when it does. Nil too, at once, when the disk is offline.
    static func look<T: Sendable>(_ path: String, patience: TimeInterval = patience, _ look: @escaping @Sendable () -> T) -> T? {
        guard let volume = volume(of: path) else { return look() }
        if offline(path) { return nil }
        guard Thread.isMainThread else { simulateSlowness(volume); return look() }
        let box = LookResult<T>(), done = DispatchSemaphore(value: 0)
        state.lock.lock()
        let waiting = state.busy.contains(volume)
        state.lock.unlock()
        // A look already out on this disk: the window doesn't queue up behind it.
        if waiting { return nil }
        queue.async {
            simulateSlowness(volume)
            let value = look()
            box.lock.lock(); box.value = value; box.done = true; let late = box.late; box.lock.unlock()
            done.signal()
            guard late else { return }
            state.lock.lock(); state.busy.remove(volume); state.lock.unlock()
            post(volume)
        }
        _ = done.wait(timeout: .now() + patience)
        box.lock.lock(); defer { box.lock.unlock() }
        if box.done { return box.value }
        box.late = true
        state.lock.lock(); state.busy.insert(volume); state.lock.unlock()
        return nil
    }

    /// Whether the disk of `path` is there to work on: mounted, and not said by the Mac to have stopped answering.
    /// The disk isn't asked: a slow disk answers, at its speed.
    static func answers(_ path: String) -> Bool { !offline(path) }

    /// Whether the disk of `path` answers a look within `patience`, waited for on any thread: for what can't be done
    /// a little at a time, as opening a whole catalogue on the main thread.
    static func respondsWithin(_ path: String, patience: TimeInterval) -> Bool {
        guard volume(of: path) != nil else { return true }
        if offline(path) { return false }
        let done = DispatchSemaphore(value: 0)
        queue.async { if let volume = volume(of: path) { simulateSlowness(volume) }; var info = stat(); _ = lstat(path, &info); done.signal() }
        return done.wait(timeout: .now() + patience) == .success
    }

    /// `fileExists` that never holds the window up: false on a disk that's offline; true while a slow disk's answer
    /// isn't known yet on the main thread (taken as there: what reads it finds out, and `changed` says when to look again).
    static func exists(_ path: String, patience: TimeInterval = patience) -> Bool {
        if offline(path) { return false }
        return look(path, patience: patience) { FileManager.default.fileExists(atPath: path) } ?? true
    }

    /// `isReadableFile` that never holds the window up, as `exists`.
    static func readable(_ path: String, patience: TimeInterval = patience) -> Bool {
        if offline(path) { return false }
        return look(path, patience: patience) { FileManager.default.isReadableFile(atPath: path) } ?? true
    }

    /// Whether `url` is a folder; false on a disk that's offline. While a slow disk's answer isn't known yet, its
    /// name says: no extension, a folder.
    static func isFolder(_ url: URL, patience: TimeInterval = patience) -> Bool {
        if offline(url.path) { return false }
        return look(url.path, patience: patience) { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            ?? (url.hasDirectoryPath || url.pathExtension.isEmpty)
    }

    private final class LookResult<T>: @unchecked Sendable {
        let lock = NSLock()
        var value: T?
        var done = false
        var late = false
    }

    // MARK: The Mac's list of disks

    /// The mount points and whether each disk is plugged into this Mac, from the system's list as it already knows it:
    /// no disk is asked (`MNT_NOWAIT`).
    static func mountList() -> [String: Bool] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [:] }
        var mounts = Array(repeating: Darwin.statfs(), count: Int(count) + 4)
        let read = mounts.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(MemoryLayout<Darwin.statfs>.stride * buffer.count), MNT_NOWAIT)
        }
        guard read > 0 else { return [:] }
        var list: [String: Bool] = [:]
        for var mount in mounts.prefix(Int(read)) {
            let path = withUnsafeBytes(of: &mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            list[path] = mount.f_flags & UInt32(MNT_LOCAL) != 0
        }
        return list
    }

    private static func mounts() -> [String: Bool] {
        _ = watchOnce
        state.lock.lock()
        if let known = state.mounted { state.lock.unlock(); return known }
        state.lock.unlock()
        let list = mountList()
        state.lock.lock(); state.mounted = list; state.lock.unlock()
        return list
    }

    /// Whether a disk is mounted at `volume`. An entry under /Volumes that isn't a mount point (the startup disk's
    /// link) is looked at itself: it's on the startup disk.
    static func isMounted(_ volume: String) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["QLICK_SLOW_VOLUME"] == volume { return true }
        #endif
        if mounts()[volume] != nil { return true }
        var info = stat()
        return lstat(volume, &info) == 0
    }

    /// Whether the disk mounted at `volume` is plugged into this Mac (not a network share). A disk not in the list
    /// (gone, or not yet mounted) isn't local.
    static func isLocal(_ volume: String) -> Bool { mounts()[volume] ?? false }

    /// The lab has said already that this disk doesn't answer (the catalogue's own message): not said twice.
    static func said(_ path: String) {
        guard let volume = volume(of: path) else { return }
        state.lock.lock(); state.told.insert(volume); state.lock.unlock()
    }

    // MARK: The system's events

    /// The watch of the system's disk events, started on first use.
    private static let watchOnce: Void = {
        Thread.detachNewThread { listen() }
        #if DEBUG
        simulateGone()
        #endif
    }()

    /// Mounts, unmounts and "not responding" come from the kernel (`EVFILT_FS`), for every disk at once.
    private static func listen() {
        let events = kqueue()
        guard events >= 0 else { return }
        var change = kevent(ident: 0, filter: Int16(EVFILT_FS), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(events, &change, 1, nil, 0, nil) == 0 else { close(events); return }
        while true {
            var event = kevent()
            guard kevent(events, nil, 0, &event, 1, nil) == 1 else { continue }
            let flags = Int32(bitPattern: event.fflags)
            if flags & (VQ_MOUNT | VQ_UNMOUNT | VQ_UPDATE | VQ_DEAD) != 0 { remount() }
            // Said for a share going quiet and for one answering again, without saying which: every share is asked.
            if flags & (VQ_NOTRESP | VQ_DEAD) != 0 { askShares() }
        }
    }

    /// Reads the mount list again; a disk that came or went is posted.
    private static func remount() {
        let list = mountList()
        state.lock.lock()
        let before = state.mounted ?? [:]
        state.mounted = list
        let gone = Set(before.keys).subtracting(list.keys), came = Set(list.keys).subtracting(before.keys)
        // A share let go isn't silent any more: it's away, as any disk unplugged.
        state.silent.subtract(gone)
        state.lock.unlock()
        for volume in gone.union(came) where volume.hasPrefix("/Volumes/") { post(volume) }
    }

    /// After the Mac said a share stopped answering, or answers again: each share is asked about its top. One whose
    /// question hasn't come back in `shareWait`, or fails as the network does, is the one: silent until it answers.
    private static let shareWait: TimeInterval = 10

    private static func askShares() {
        for (volume, local) in mounts() where !local && volume.hasPrefix("/Volumes/") { ask(volume) }
    }

    private static func ask(_ volume: String) {
        state.lock.lock()
        let new = state.asking.insert(volume).inserted
        state.lock.unlock()
        guard new else { return }
        Thread.detachNewThread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                let failed = LookResult<Bool>()
                Thread.detachNewThread {
                    var info = stat()
                    let lost = lstat(volume, &info) != 0 && [ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH].contains(errno)
                    failed.lock.lock(); failed.value = lost; failed.lock.unlock()
                    answered.signal()
                }
                let inTime = answered.wait(timeout: .now() + shareWait) == .success
                if inTime {
                    failed.lock.lock(); let lost = failed.value == true; failed.lock.unlock()
                    if !lost { break }
                    setSilent(volume, true)
                } else {
                    setSilent(volume, true)
                    // Still waiting for it: the share is back when the question comes back.
                    answered.wait()
                    failed.lock.lock(); let lost = failed.value == true; failed.lock.unlock()
                    if !lost { break }
                }
                Thread.sleep(forTimeInterval: 3)
                state.lock.lock(); let there = state.mounted?[volume] != nil; state.lock.unlock()
                if !there { break }
            }
            setSilent(volume, false)
            state.lock.lock(); state.asking.remove(volume); state.lock.unlock()
        }
    }

    private static func setSilent(_ volume: String, _ silent: Bool) {
        state.lock.lock()
        let changedNow = silent ? state.silent.insert(volume).inserted : state.silent.remove(volume) != nil
        state.lock.unlock()
        guard changedNow else { return }
        FileHandle.standardError.write(Data("\(volume) \(silent ? "isn't answering (the Mac says so)" : "answers")\n".utf8))
        post(volume)
        guard silent else { return }
        DispatchQueue.main.async {
            state.lock.lock()
            let tell = state.silent.contains(volume) && state.told.insert(volume).inserted
            state.lock.unlock()
            if tell { MainActor.assumeIsolated { stoppedAnswering?(URL(fileURLWithPath: volume, isDirectory: true)) } }
        }
    }

    private static func post(_ volume: String) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil, userInfo: ["volume": volume]) }
    }

    // MARK: Trying it without a NAS

    /// Debug builds only. `QLICK_SLOW_VOLUME=/Volumes/Name` makes every look at that disk take `QLICK_SLOW_SECONDS`
    /// (3), as a NAS saturated by the lab's reading: the disk must never show as away.
    /// `QLICK_GONE_VOLUME=/Volumes/Name` is a share the Mac says stopped answering, for `QLICK_GONE_SECONDS` (20) after
    /// launch: it shows as away, then comes back.
    private static func simulateSlowness(_ volume: String) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["QLICK_SLOW_VOLUME"] == volume else { return }
        Thread.sleep(forTimeInterval: Double(environment["QLICK_SLOW_SECONDS"] ?? "") ?? 3)
        #endif
    }

    #if DEBUG
    private static func simulateGone() {
        let environment = ProcessInfo.processInfo.environment
        guard let volume = environment["QLICK_GONE_VOLUME"] else { return }
        state.lock.lock(); state.silent.insert(volume); state.lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            state.lock.lock(); let tell = state.told.insert(volume).inserted; state.lock.unlock()
            if tell { MainActor.assumeIsolated { stoppedAnswering?(URL(fileURLWithPath: volume, isDirectory: true)) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (Double(environment["QLICK_GONE_SECONDS"] ?? "") ?? 20)) { setSilent(volume, false) }
    }

    /// For the tests: the Mac says a share stopped answering, or answers again.
    static func testSetSilent(_ volume: String, _ silent: Bool) { setSilent(volume, silent) }
    #endif
}
