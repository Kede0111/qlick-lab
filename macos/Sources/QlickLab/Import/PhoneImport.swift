// Qlick Lab — GPL-3.0-only.
import Foundation
import Observation

/// Qlick Lab: the iPhones the import room offers as a source, "iPhone · QLab": QLab's shared folder (its Documents)
/// read over the cable. Opening one copies its photographs, each with its `.qsidecar` (or its former `.qlab.json`),
/// into a transit folder and opens that as the source: the import that follows is the room's own (checked copy,
/// ledger, Archive, a Folder per day as QLab files them). Its recipes (`Recipes/*.qrecipe`) join the lab's.
/// Nothing is written to the iPhone. The transport is `PhoneTransport`, so another can replace the cable.
@MainActor @Observable final class PhoneImport {
    private(set) var devices: [PhoneDevice] = []
    /// What opening an iPhone is doing now, in words, and how far it is (0…1); nil when nothing is.
    private(set) var activity: (text: String, fraction: Double?)?
    /// The last thing to say about an iPhone: what to do (unlock it, trust this Mac), or what came in.
    private(set) var notice: String?

    @ObservationIgnored let transport: PhoneTransport?
    @ObservationIgnored private var stopWatching: (@Sendable () -> Void)?
    @ObservationIgnored private var opening: Task<Void, Never>?

    init(transport: PhoneTransport? = IdeviceTransport.find(), watch: Bool = NSClassFromString("XCTestCase") == nil) {
        self.transport = transport
        guard watch, let transport else { return }
        stopWatching = transport.watch { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    deinit { stopWatching?() }

    /// Where an iPhone's files wait before they're imported: the Mac's cache (they're copies), one folder per iPhone,
    /// kept between imports so what came over once isn't copied again.
    static func transit(for udid: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "be.jackfrom.qlicklab"
        return caches.appendingPathComponent(bundle).appendingPathComponent("iPhone", isDirectory: true)
            .appendingPathComponent(udid.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// Empties an iPhone's transit folder (copies of what is on the iPhone), off the main thread.
    func clearTransit(_ udid: String) {
        let folder = Self.transit(for: udid)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    func handle(_ event: PhoneTransportEvent) {
        switch event {
        case let .attached(udid, deviceID, usb):
            // Over the cable only: a phone seen over the network is left out.
            guard usb else { return }
            if let index = devices.firstIndex(where: { $0.udid == udid }) { devices[index].deviceID = deviceID } else {
                devices.append(PhoneDevice(udid: udid, deviceID: deviceID))
            }
            refresh(udid)
        case let .detached(deviceID):
            devices.removeAll { $0.deviceID == deviceID }
        }
    }

    /// Asks the iPhone again whether QLab's folder can be read (its name comes with the answer).
    func refresh(_ udid: String) {
        guard let transport else { return }
        Task {
            var answer = await transport.probe(udid)
            guard let index = devices.firstIndex(where: { $0.udid == udid }) else { return }
            answer.deviceID = devices[index].deviceID
            if answer.name == nil { answer.name = devices[index].name }
            devices[index] = answer
        }
    }

    private func update(_ device: PhoneDevice) {
        guard let index = devices.firstIndex(where: { $0.udid == device.udid }) else { return }
        var device = device
        device.deviceID = devices[index].deviceID
        if device.name == nil { device.name = devices[index].name }
        devices[index] = device
    }

    /// The files of QLab's folder an import takes: its photographs (not inside Recipes), each one's `.qsidecar`, or its
    /// `.qlab.json` when it has none, and the recipes.
    /// `known`: whether the catalogue imported a photograph of that name and size already (its ledger); those aren't
    /// copied over again.
    nonisolated static func wanted(_ files: [PhoneFile], known: (String, Int) -> Bool = { _, _ in false })
        -> (photos: [PhoneFile], companions: [PhoneFile], recipes: [PhoneFile]) {
        let paths = Set(files.map(\.path))
        let photos = files.filter { file in
            !file.path.hasPrefix("Recipes/") && PhotoFolder.extensions.contains((file.path as NSString).pathExtension.lowercased())
                && !known((file.path as NSString).lastPathComponent, file.size)
        }
        var companions: [PhoneFile] = []
        let byPath = Dictionary(files.map { ($0.path, $0) }) { a, _ in a }
        for photo in photos {
            let sidecar = photo.path + "." + PhotoSidecar.fileExtension, former = photo.path + ".qlab.json"
            if paths.contains(sidecar), let file = byPath[sidecar] { companions.append(file) }
            else if paths.contains(former), let file = byPath[former] { companions.append(file) }
        }
        let recipes = files.filter { $0.path.hasPrefix("Recipes/") && ($0.path as NSString).pathExtension.lowercased() == QRecipe.fileExtension }
        return (photos, companions, recipes)
    }

    /// Opens `device` as the import room's source: asks it to trust this Mac if it hasn't, copies what's new into the
    /// transit folder, brings its recipes in, then shows its photographs. Says what to do when it can't.
    func open(_ device: PhoneDevice, in session: ImportSession) {
        guard let transport, opening == nil, session.run == nil else { return }
        notice = nil
        opening = Task { [weak self] in
            defer { self?.opening = nil; self?.activity = nil }
            guard let self else { return }
            self.activity = ("Looking at the iPhone…", nil)
            var state = await transport.probe(device.udid)
            if state.state == .untrusted {
                self.activity = ("Tap Trust on the iPhone…", nil)
                state = await transport.pair(device.udid)
            }
            self.update(state)
            guard state.state == .ready else { self.notice = state.advice; return }
            do {
                self.activity = ("Listing QLab’s photographs…", nil)
                let ledger = session.ledger
                let listed = try await transport.list(device.udid)
                let (photos, companions, recipes) = await Task.detached { Self.wanted(listed) { ledger.knows(name: $0, size: $1) } }.value
                let all = photos + companions + recipes
                let total = max(all.reduce(0) { $0 + $1.size }, 1)
                let folder = Self.transit(for: device.udid)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let counter = ByteCounter()
                self.activity = ("Copying from the iPhone…", 0)
                _ = try await transport.pull(device.udid, paths: all.map(\.path), into: folder) { bytes in
                    let done = counter.add(bytes)
                    Task { @MainActor [weak self] in self?.activity = ("Copying from the iPhone…", min(Double(done) / Double(total), 1)) }
                }
                let brought = await session.model.importPhoneRecipes(recipes.map { folder.appendingPathComponent($0.path) })
                let anyListed = listed.contains { !$0.path.hasPrefix("Recipes/") && PhotoFolder.extensions.contains(($0.path as NSString).pathExtension.lowercased()) }
                let none = !anyListed ? "No photographs in QLab’s folder." : photos.isEmpty ? "Every photograph on the iPhone is imported already." : nil
                self.notice = [none, brought].compactMap { $0 }.joined(separator: " ").nilIfEmpty
                session.open(ImportSource(root: folder, volume: nil, name: state.title, kind: .phone, uuid: device.udid))
            } catch let error as PhoneTransportError {
                var failed = state; failed.state = error.state; failed.message = error.message
                self.update(failed)
                self.notice = failed.advice ?? error.message
            } catch {
                self.notice = "The iPhone couldn’t be read: \(error.localizedDescription)"
            }
        }
    }
}

/// Bytes counted across threads.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ bytes: Int) -> Int { lock.withLock { total += bytes; return total } }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What to do with a recipe from the iPhone, given the lab's own.
enum PhoneRecipeDecision: Equatable, Sendable {
    /// Not here: added, with its identifier (the same recipe on both).
    case add
    /// Here as it is (same identifier, same revision): nothing to do.
    case same
    /// Here, changed on one side: both kept, the iPhone's as a copy with a name of its own.
    case keepBoth(name: String)

    /// `remote` (its `qrecipe` header) against the lab's recipes (identifier → their header).
    static func decide(remote: [String: Any], local: [String: [String: Any]], taken: Set<String>) -> PhoneRecipeDecision {
        guard let id = remote["id"] as? String, let mine = local[id] else { return .add }
        if let revision = remote["revision"] as? String, revision == mine["revision"] as? String { return .same }
        let name = (remote["name"] as? String) ?? "Recipe"
        return .keepBoth(name: PresetName.unique("\(name) (iPhone)", taken: taken))
    }
}

extension EditorModel {
    /// Qlick Lab: the iPhone's recipes, brought into the lab: one not here is added with its identifier; one here
    /// unchanged is left; one changed on either side comes in as a copy beside the lab's, which is never written over.
    /// Each is read by the engine first, as any recipe imported. Returns a sentence for the import room, or nil.
    func importPhoneRecipes(_ files: [URL]) async -> String? {
        guard !files.isEmpty, canChangePresets, let engine else { return nil }
        let listed = (try? await presetLibrary.list()) ?? []
        var local: [String: [String: Any]] = [:]
        for preset in listed {
            if let data = try? await presetLibrary.read(preset), let header = QRecipe.header(data), let id = header["id"] as? String { local[id] = header }
        }
        var taken = Set(listed.map { PresetName.key($0.name) })
        var added = 0, copies = 0, failed = 0
        for file in files {
            guard let data = try? PresetLibrary.read(file) else { failed += 1; continue }
            let header = QRecipe.header(data) ?? [:]
            let name = PresetName.from(fileName: header["name"] as? String ?? file.deletingPathExtension().lastPathComponent)
            let decision = PhoneRecipeDecision.decide(remote: header, local: local, taken: taken)
            if decision == .same { continue }
            do {
                _ = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(try Self.presetText(data))])
                switch decision {
                case .add:
                    let saved = try await presetLibrary.add(data, name: name)
                    taken.insert(PresetName.key(saved.name)); added += 1
                case .keepBoth(let copyName):
                    let saved = try await presetLibrary.add(QRecipe.withoutID(data), name: copyName)
                    taken.insert(PresetName.key(saved.name)); copies += 1
                case .same: break
                }
            } catch {
                failed += 1
            }
        }
        if added + copies > 0 { await refreshPresets() }
        var words: [String] = []
        if added > 0 { words.append("\(added) recipe\(added == 1 ? "" : "s") from the iPhone added.") }
        if copies > 0 { words.append("\(copies) recipe\(copies == 1 ? "" : "s") changed on one side kept twice, the iPhone’s marked “(iPhone)”.") }
        if failed > 0 { words.append("\(failed) recipe\(failed == 1 ? "" : "s") couldn’t be read.") }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
