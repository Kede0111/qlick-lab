// Qlick Lab — GPL-3.0-only.
import Foundation

/// An iPhone as the import room sees it.
struct PhoneDevice: Identifiable, Hashable, Sendable {
    /// What can be done with it now.
    enum State: String, Sendable {
        /// Plugged in, not asked yet.
        case checking
        /// QLab's folder can be read.
        case ready
        /// Locked since it was switched on (or asked while locked): unlock it.
        case locked
        /// It hasn't trusted this Mac: unlock it and answer Trust.
        case untrusted
        /// QLab isn't on it, or shares nothing.
        case noQLab = "no_qlab"
        case error
    }

    var udid: String
    /// usbmuxd's number for it, which a "detached" event names.
    var deviceID: Int
    var name: String?
    var state: State = .checking
    var message: String?
    var id: String { udid }

    var title: String { "\(name ?? "iPhone") · QLab" }

    /// What the photographer has to do, in one sentence; nil when it's ready.
    var advice: String? {
        switch state {
        case .checking: "Looking at the iPhone…"
        case .ready: nil
        case .locked: "Unlock the iPhone, then click again."
        case .untrusted: "Unlock the iPhone and tap Trust when it asks whether to trust this Mac, then click again."
        case .noQLab: "QLab isn't on this iPhone, or hasn't taken a photograph yet."
        case .error: message.map { "The iPhone couldn’t be read: \($0)" } ?? "The iPhone couldn’t be read."
        }
    }
}

/// A file of QLab's folder on the iPhone, its path relative to that folder (`2026-11-23/QLB_0001.DNG`).
struct PhoneFile: Hashable, Sendable {
    var path: String
    var size: Int
    var modified: Date?
}

/// How the lab reaches an iPhone's QLab folder. Today the cable (`IdeviceTransport`, the `qlick-iphone` helper); a
/// transport that suits the Mac App Store (an iCloud container shared by the two apps) can take its place.
protocol PhoneTransport: Sendable {
    /// Calls `event` for every iPhone plugged in (those there already first) and taken out, until `stop` is called.
    func watch(_ event: @escaping @Sendable (PhoneTransportEvent) -> Void) -> @Sendable () -> Void
    /// Whether QLab's folder can be read, and the iPhone's name.
    func probe(_ udid: String) async -> PhoneDevice
    /// Asks the iPhone to trust this Mac (it shows the question), then probes it again.
    func pair(_ udid: String) async -> PhoneDevice
    /// Every file of QLab's folder.
    func list(_ udid: String) async throws -> [PhoneFile]
    /// Copies `paths` into `folder`, under the same relative paths; `progress` is told of the bytes as they come.
    /// Returns the paths copied or already there; those that failed are named in the error, after the others.
    func pull(_ udid: String, paths: [String], into folder: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> [String]
    /// Leaves QLab a request to delete these photographs (docs/q-formats.md); QLab carries it out when it next opens.
    func requestDelete(_ udid: String, request: Data) async throws
    /// Writes a recipe into QLab's `Recipes/` as `name` (`<name>.qrecipe`), over the file of that name.
    func putRecipe(_ udid: String, name: String, data: Data) async throws
    /// Removes the recipe `name` (`<name>.qrecipe`) from QLab's `Recipes/`.
    func removeRecipe(_ udid: String, name: String) async throws
}

enum PhoneTransportEvent: Sendable {
    case attached(udid: String, deviceID: Int, usb: Bool)
    case detached(deviceID: Int)
}

struct PhoneTransportError: LocalizedError, Sendable {
    var message: String
    var state: PhoneDevice.State = .error
    var errorDescription: String? { message }
}

/// The cable: the `qlick-iphone` helper (crates/qlick-iphone), built with the engine's tools and put beside the app's
/// executable. Everything runs off the main thread. It writes to the iPhone only a deletion request, and the recipes
/// sent or removed one by one from the Recipes room.
struct IdeviceTransport: PhoneTransport {
    let helper: URL

    /// The helper beside the executable, or the workspace's build (`target/release`).
    static func find() -> IdeviceTransport? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["QLICK_IPHONE_HELPER"] { candidates.append(URL(fileURLWithPath: path, isDirectory: false)) }
        if let executable = Bundle.main.executableURL { candidates.append(executable.deletingLastPathComponent().appendingPathComponent("qlick-iphone")) }
        if let root = ProcessInfo.processInfo.environment["SPEKTRAFILM_ROOT"] {
            candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("target/release/qlick-iphone"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }.map(IdeviceTransport.init(helper:))
    }

    /// Runs the helper with `arguments`, `input` on its stdin, and calls `line` for each JSON line it answers.
    private func run(_ arguments: [String], input: String? = nil, line: @escaping (([String: Any]) -> Void)) throws -> Int32 {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = BrokenPipes.ignored
        // A helper that ended early (an iPhone unplugged) makes this fail; what it said is read below all the same.
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        var pending = Data()
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let end = pending.firstIndex(of: 0x0A) {
                let text = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                if let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any] { line(object) }
            }
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func device(from object: [String: Any], udid: String) -> PhoneDevice {
        var device = PhoneDevice(udid: udid, deviceID: 0)
        device.name = object["name"] as? String
        device.state = (object["state"] as? String).flatMap(PhoneDevice.State.init(rawValue:)) ?? .error
        device.message = object["message"] as? String ?? object["error"] as? String
        return device
    }

    private func ask(_ command: String, _ udid: String) async -> PhoneDevice {
        let answer = try? await detached { () -> PhoneDevice in
            var last: [String: Any] = ["state": "error", "message": "The iPhone helper didn’t answer."]
            _ = try run([command, udid]) { last = $0 }
            return Self.device(from: last, udid: udid)
        }
        return answer ?? Self.device(from: ["state": "error", "message": "The iPhone helper couldn’t start."], udid: udid)
    }

    func probe(_ udid: String) async -> PhoneDevice { await ask("probe", udid) }
    func pair(_ udid: String) async -> PhoneDevice { await ask("pair", udid) }

    func list(_ udid: String) async throws -> [PhoneFile] {
        try await detached {
            var files: [PhoneFile] = [], failure: [String: Any]?
            _ = try run(["list", udid]) { object in
                if object["error"] != nil { failure = object; return }
                guard let path = object["path"] as? String else { return }
                files.append(PhoneFile(path: path, size: object["size"] as? Int ?? 0,
                                       modified: (object["modified"] as? Double).map { Date(timeIntervalSince1970: $0) }))
            }
            if let failure {
                throw PhoneTransportError(message: failure["error"] as? String ?? "The iPhone couldn’t be read.",
                                          state: (failure["state"] as? String).flatMap(PhoneDevice.State.init(rawValue:)) ?? .error)
            }
            return files
        }
    }

    func pull(_ udid: String, paths: [String], into folder: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> [String] {
        try await detached {
            var copied: [String] = [], failed: [String] = [], failure: [String: Any]?
            _ = try run(["pull", udid, folder.path], input: paths.joined(separator: "\n") + "\n") { object in
                if let bytes = object["progress"] as? Int { progress(bytes) }
                else if let path = (object["done"] ?? object["skipped"]) as? String { copied.append(path) }
                else if let path = object["failed"] as? String { failed.append("\(path): \(object["error"] as? String ?? "?")") }
                else if object["error"] != nil { failure = object }
            }
            if let failure {
                throw PhoneTransportError(message: failure["error"] as? String ?? "The iPhone couldn’t be read.",
                                          state: (failure["state"] as? String).flatMap(PhoneDevice.State.init(rawValue:)) ?? .error)
            }
            if !failed.isEmpty {
                throw PhoneTransportError(message: "\(failed.count) file\(failed.count == 1 ? "" : "s") couldn’t be copied: " + failed.prefix(3).joined(separator: "; "))
            }
            return copied
        }
    }

    func requestDelete(_ udid: String, request: Data) async throws {
        let text = String(decoding: request, as: UTF8.self)
        try await detached {
            var failure: [String: Any]?, written = false
            _ = try run(["request-delete", udid], input: text) { object in
                if object["written"] != nil { written = true } else if object["error"] != nil { failure = object }
            }
            guard written else {
                throw PhoneTransportError(message: failure?["error"] as? String ?? "The request couldn’t be written on the iPhone.",
                                          state: (failure?["state"] as? String).flatMap(PhoneDevice.State.init(rawValue:)) ?? .error)
            }
        }
    }

    /// Runs a command that writes to the iPhone; it answered `key` when it did.
    private func write(_ arguments: [String], input: String?, answers key: String, failure what: String) async throws {
        try await detached {
            var failure: [String: Any]?, done = false
            _ = try run(arguments, input: input) { object in
                if object[key] != nil { done = true } else if object["error"] != nil { failure = object }
            }
            guard done else {
                throw PhoneTransportError(message: failure?["error"] as? String ?? what,
                                          state: (failure?["state"] as? String).flatMap(PhoneDevice.State.init(rawValue:)) ?? .error)
            }
        }
    }

    func putRecipe(_ udid: String, name: String, data: Data) async throws {
        try await write(["put-recipe", udid, name], input: String(decoding: data, as: UTF8.self), answers: "written",
                        failure: "The recipe couldn’t be written on the iPhone.")
    }

    func removeRecipe(_ udid: String, name: String) async throws {
        try await write(["remove-recipe", udid, name], input: nil, answers: "removed", failure: "The recipe couldn’t be removed from the iPhone.")
    }

    func watch(_ event: @escaping @Sendable (PhoneTransportEvent) -> Void) -> @Sendable () -> Void {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["watch"]
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        _ = BrokenPipes.ignored
        guard (try? process.run()) != nil else { return {} }
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 0x0A) {
                    let text = pending[pending.startIndex..<end]
                    pending.removeSubrange(pending.startIndex...end)
                    guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { continue }
                    switch object["event"] as? String {
                    case "attached":
                        if let udid = object["udid"] as? String, let id = object["id"] as? Int {
                            event(.attached(udid: udid, deviceID: id, usb: (object["connection"] as? String) == "usb"))
                        }
                    case "detached":
                        if let id = object["id"] as? Int { event(.detached(deviceID: id)) }
                    default: break
                    }
                }
            }
        }
        // Closing its stdin ends the helper.
        return { try? stdin.fileHandleForWriting.close() }
    }
}
