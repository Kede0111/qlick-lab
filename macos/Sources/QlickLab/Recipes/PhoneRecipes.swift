// Qlick Lab — GPL-3.0-only.
import Foundation
import Observation

/// Qlick Lab: the recipes of an iPhone's QLab (`Documents/Recipes/*.qrecipe`) beside the lab's, in the Recipes room,
/// exchanged one by one: brought to the Mac, sent to the iPhone, one put in place of the other, or removed from the
/// iPhone. Never on their own, never with an import (a photograph's `.qsidecar` holds its development whole).
///
/// The same recipe is the same identifier on both sides (docs/q-formats.md). Each app sets its own revision, so the
/// two revisions are never compared with one another: the lab remembers, per iPhone, both as they were when the
/// recipe was last exchanged (`PhoneRecipeSync`), and so knows which side changed since.
@MainActor @Observable final class PhoneRecipes {
    private(set) var rows: [PhoneRecipeRow] = []
    /// The iPhone shown, nil when none is plugged in and ready.
    private(set) var udid: String?
    private(set) var phoneName: String?
    /// What it's doing now, in words.
    private(set) var busy: String?
    /// The last thing to say: what was done, or why it couldn't be.
    var notice: String?

    @ObservationIgnored private var local: URL?
    @ObservationIgnored private var listing: Task<Void, Never>?

    /// Where the iPhone's recipes are copied to be read: the caches, emptied at each listing.
    nonisolated static func folder(for udid: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "be.jackfrom.qlicklab"
        return caches.appendingPathComponent(bundle).appendingPathComponent("iPhone Recipes", isDirectory: true)
            .appendingPathComponent(udid.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// Reads the iPhone's recipes again (`device` ready), and the lab's, and sets the rows.
    func refresh(_ device: PhoneDevice?, model: EditorModel) {
        guard let device, device.state == .ready, let transport = model.lab.importer.phones.transport else {
            udid = nil; phoneName = nil; rows = []; return
        }
        listing?.cancel()
        let first = udid != device.udid
        udid = device.udid; phoneName = device.name
        if first { rows = [] }
        listing = Task { [weak self] in
            guard let self else { return }
            self.busy = "Reading QLab’s recipes…"
            defer { self.busy = nil }
            do {
                let folder = Self.folder(for: device.udid)
                let files = try await transport.list(device.udid).filter(Self.isRecipe)
                await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: folder)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }.value
                _ = try await transport.pull(device.udid, paths: files.map(\.path), into: folder) { _ in }
                guard !Task.isCancelled else { return }
                self.local = folder
                let phone = await Task.detached(priority: .userInitiated) { files.compactMap { PhoneRecipeFile.read(folder.appendingPathComponent($0.path)) } }.value
                let mac = await self.macRecipes(model)
                guard !Task.isCancelled else { return }
                self.rows = PhoneRecipeRow.rows(mac: mac, phone: phone, synced: PhoneRecipeSync.load(udid: device.udid))
            } catch {
                self.notice = "QLab’s recipes couldn’t be read: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func isRecipe(_ file: PhoneFile) -> Bool {
        let path = file.path as NSString
        return path.deletingLastPathComponent == "Recipes" && path.pathExtension.lowercased() == QRecipe.fileExtension
            && !path.lastPathComponent.hasPrefix(".")
    }

    /// The lab's recipes with their headers' names and revisions.
    private func macRecipes(_ model: EditorModel) async -> [PhoneRecipeRow.Mac] {
        var out: [PhoneRecipeRow.Mac] = []
        for preset in model.presets {
            let data = try? await model.presetLibrary.read(preset)
            let header = data.flatMap(QRecipe.header) ?? [:]
            out.append(.init(preset: preset, id: preset.shelfID, name: preset.name, revision: header["revision"] as? String,
                             content: data.flatMap(QRecipe.content)))
        }
        return out
    }

    // MARK: What can be done

    /// The iPhone's recipe to the Mac: added, or in place of the Mac's (its name there included).
    func bringToMac(_ row: PhoneRecipeRow, model: EditorModel) {
        guard let phone = row.phone else { return }
        act("Bringing “\(phone.name)” to the Mac…", model: model) { udid, _ in
            let data = try PresetLibrary.read(phone.local)
            try await Self.check(data, model: model)
            let saved: PresetFile
            if let mac = row.mac {
                saved = try await model.presetLibrary.overwrite(mac.preset, with: data, name: phone.name)
            } else {
                saved = try await model.presetLibrary.add(data, name: phone.name)
            }
            let revision = QRecipe.header(try await model.presetLibrary.read(saved))?["revision"] as? String
            if let id = phone.id { PhoneRecipeSync.remember(udid: udid, id: id, mac: revision, phone: phone.revision) }
            return row.mac == nil ? "“\(saved.name)” was added to the lab’s recipes." : "The Mac’s “\(row.mac!.name)” is now the iPhone’s “\(saved.name)”."
        }
    }

    /// The iPhone's recipe to the Mac as a recipe of its own, beside the Mac's.
    func keepBoth(_ row: PhoneRecipeRow, model: EditorModel) {
        guard let phone = row.phone else { return }
        act("Bringing a copy of “\(phone.name)”…", model: model) { _, _ in
            let data = try PresetLibrary.read(phone.local)
            try await Self.check(data, model: model)
            let saved = try await model.presetLibrary.add(QRecipe.withoutID(data), name: "\(phone.name) (iPhone)")
            return "“\(saved.name)” was added beside the Mac’s."
        }
    }

    /// The Mac's recipe to the iPhone: added, or in place of the iPhone's. QLab reads it when it next comes to the front.
    func sendToPhone(_ row: PhoneRecipeRow, model: EditorModel) {
        guard let mac = row.mac, let transport = model.lab.importer.phones.transport else { return }
        // Another recipe's file on the iPhone is never written over.
        let taken = Set(rows.compactMap(\.phone).filter { $0.fileName != row.phone?.fileName }.map { PresetName.key($0.stem) })
        act("Sending “\(mac.name)” to the iPhone…", model: model) { udid, _ in
            var data = try await model.presetLibrary.read(mac.preset)
            // Its identifier in its header, so QLab knows it as the same recipe.
            if QRecipe.id(data) != mac.id { data = try QRecipe.stamped(data, id: mac.id, name: mac.name) }
            let stem = PresetName.unique(mac.name, taken: taken)
            try await transport.putRecipe(udid, name: "\(stem).\(QRecipe.fileExtension)", data: data)
            // Renamed on the Mac: its former file on the iPhone goes, once the new one is there.
            if let former = row.phone, PresetName.key(former.stem) != PresetName.key(stem) {
                try await transport.removeRecipe(udid, name: former.fileName)
            }
            let revision = QRecipe.header(data)?["revision"] as? String
            PhoneRecipeSync.remember(udid: udid, id: mac.id, mac: revision, phone: revision)
            return row.phone == nil ? "“\(mac.name)” was sent to the iPhone: QLab shows it when it next opens."
                : "The iPhone’s “\(row.phone!.name)” is now the Mac’s “\(mac.name)”."
        }
    }

    /// Removes the iPhone's recipe, once asked. Photographs developed with it keep their development.
    func removeFromPhone(_ row: PhoneRecipeRow, model: EditorModel, ask: Bool = true) {
        guard let phone = row.phone, let transport = model.lab.importer.phones.transport else { return }
        Task {
            if !ask {
                act("Deleting “\(phone.name)” from the iPhone…", model: model) { udid, _ in
                    try await transport.removeRecipe(udid, name: phone.fileName)
                    if let id = phone.id { PhoneRecipeSync.forget(udid: udid, id: id) }
                    return "“\(phone.name)” was deleted from the iPhone."
                }
                return
            }
            let answer = await model.ask(AppAlert(
                title: "Delete “\(phone.name)” from the iPhone?",
                detail: "QLab loses this recipe: it can’t be undone on the iPhone. Photographs developed with it keep their development"
                    + (row.mac == nil ? "." : ", and the Mac keeps its own “\(row.mac!.name)”."),
                buttons: [.init(title: "Delete from the iPhone", role: .destructive), .init(title: "Cancel", role: .cancel)]))
            guard answer.button == 0 else { return }
            act("Deleting “\(phone.name)” from the iPhone…", model: model) { udid, _ in
                try await transport.removeRecipe(udid, name: phone.fileName)
                if let id = phone.id { PhoneRecipeSync.forget(udid: udid, id: id) }
                return "“\(phone.name)” was deleted from the iPhone."
            }
        }
    }

    // MARK: Dragged from one side to the other

    /// What a recipe dropped on the other side does, by how it stands: what its button does, nothing when they're the
    /// same, and a question when the side it lands on changed too (or they were never exchanged).
    enum DropDecision: Equatable { case go, alreadySame, ask }

    nonisolated static func dropDecision(toPhone: Bool, _ status: PhoneRecipeRow.Status) -> DropDecision {
        switch status {
        case .same: return .alreadySame
        case .onlyMac, .changedOnMac: return toPhone ? .go : .ask
        case .onlyPhone, .changedOnPhone: return toPhone ? .ask : .go
        case .changedOnBoth, .different: return .ask
        }
    }

    /// A recipe of the lab (`url`, its file) dropped on the iPhone section.
    func dropOnPhone(_ url: URL, model: EditorModel) {
        guard let row = rows.first(where: { $0.mac?.preset.url.labStandardized == url.labStandardized }) else { return }
        switch Self.dropDecision(toPhone: true, row.status) {
        case .go: sendToPhone(row, model: model)
        case .alreadySame: notice = "“\(row.name)” is the same on the iPhone already."
        case .ask:
            Task {
                let answer = await model.ask(AppAlert(
                    title: "Replace the iPhone’s “\(row.phone?.name ?? row.name)” with the Mac’s?",
                    detail: "It is \(row.status.title.lowercased()). The iPhone’s version is replaced, its name included.",
                    buttons: [.init(title: "Replace the iPhone’s", role: .destructive), .init(title: "Cancel", role: .cancel)]))
                if answer.button == 0 { sendToPhone(row, model: model) }
            }
        }
    }

    /// Whether `url` is one of the iPhone's recipes as copied here to be read (what its line drags).
    func isPhoneCopy(_ url: URL) -> Bool { rows.contains { $0.phone?.local.labStandardized == url.labStandardized } }

    /// One of the iPhone's recipes (its copy here) dropped among the lab's.
    func dropOnMac(_ url: URL, model: EditorModel) {
        guard let row = rows.first(where: { $0.phone?.local.labStandardized == url.labStandardized }) else { return }
        switch Self.dropDecision(toPhone: false, row.status) {
        case .go: bringToMac(row, model: model)
        case .alreadySame: notice = "“\(row.name)” is the same on the Mac already."
        case .ask:
            Task {
                let answer = await model.ask(AppAlert(
                    title: "Replace the Mac’s “\(row.mac?.name ?? row.name)” with the iPhone’s?",
                    detail: "It is \(row.status.title.lowercased()). Keep Both brings the iPhone’s beside it, “(iPhone)” after its name.",
                    buttons: [.init(title: "Replace the Mac’s", role: .destructive), .init(title: "Keep Both"), .init(title: "Cancel", role: .cancel)]))
                switch answer.button {
                case 0: bringToMac(row, model: model)
                case 1: keepBoth(row, model: model)
                default: break
                }
            }
        }
    }

    /// The engine reads it as a recipe first, as any recipe imported.
    private static func check(_ data: Data, model: EditorModel) async throws {
        guard let engine = model.engine else { throw EngineError(message: "The engine isn’t ready.") }
        _ = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(try EditorModel.presetText(data))])
    }

    private func act(_ what: String, model: EditorModel, _ work: @escaping @MainActor (String, PhoneTransport) async throws -> String) {
        guard busy == nil, let udid, let transport = model.lab.importer.phones.transport, model.canChangePresets else { return }
        busy = what
        notice = nil
        Task {
            do { notice = try await work(udid, transport) } catch { notice = error.localizedDescription }
            busy = nil
            await model.refreshPresets()
            refresh(model.lab.importer.phones.devices.first { $0.udid == udid }, model: model)
        }
    }
}

/// A recipe of the iPhone, as its file says.
struct PhoneRecipeFile: Hashable, Sendable {
    /// `Portra.qrecipe`, in QLab's `Recipes/`.
    var fileName: String
    var id: String?
    var name: String
    var revision: String?
    /// What it develops with, whoever wrote it (`QRecipe.content`).
    var content: String?
    /// Its copy on the Mac, to read.
    var local: URL
    var stem: String { (fileName as NSString).deletingPathExtension }

    static func read(_ url: URL) -> PhoneRecipeFile? {
        guard let data = try? PresetLibrary.read(url), let top = try? QRecipe.object(data) else { return nil }
        let header = top["qrecipe"] as? [String: Any] ?? [:]
        let stem = url.deletingPathExtension().lastPathComponent
        let name = (header["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        return PhoneRecipeFile(fileName: url.lastPathComponent, id: (header["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               name: name, revision: header["revision"] as? String, content: QRecipe.content(data), local: url)
    }
}

/// One recipe in the room's iPhone section: on the Mac, on the iPhone, or both, and how they stand.
struct PhoneRecipeRow: Identifiable, Hashable, Sendable {
    struct Mac: Hashable, Sendable {
        var preset: PresetFile
        var id: String
        var name: String
        var revision: String?
        var content: String?
    }

    enum Status: Hashable, Sendable {
        case onlyMac, onlyPhone, same, changedOnPhone, changedOnMac, changedOnBoth
        /// On both, never exchanged by this Mac, and not alike.
        case different

        var title: String {
            switch self {
            case .onlyMac: "Only on the Mac"
            case .onlyPhone: "Only on the iPhone"
            case .same: "The same"
            case .changedOnPhone: "Changed on the iPhone"
            case .changedOnMac: "Changed on the Mac"
            case .changedOnBoth: "Changed on both"
            case .different: "Different"
            }
        }
    }

    var id: String
    var mac: Mac?
    var phone: PhoneRecipeFile?
    var status: Status
    var name: String { phone?.name ?? mac?.name ?? "" }

    /// How a recipe on both sides stands: alike when both revisions are the ones last exchanged (or are one), else
    /// which side changed since.
    /// Never exchanged by this Mac (brought by an earlier version, or by hand): alike when what they develop with is.
    static func status(mac: String?, phone: String?, synced: PhoneRecipeSync.Pair?, sameContent: Bool = false) -> Status {
        if let mac, let phone, mac == phone { return .same }
        guard let synced else { return sameContent ? .same : .different }
        let macChanged = mac != synced.mac, phoneChanged = phone != synced.phone
        switch (macChanged, phoneChanged) {
        case (false, false): return .same
        case (false, true): return .changedOnPhone
        case (true, false): return .changedOnMac
        case (true, true): return .changedOnBoth
        }
    }

    /// The two lists side by side, by identifier, in name order.
    static func rows(mac: [Mac], phone: [PhoneRecipeFile], synced: [String: PhoneRecipeSync.Pair]) -> [PhoneRecipeRow] {
        var rows: [PhoneRecipeRow] = []
        let macByID = Dictionary(mac.map { ($0.id, $0) }) { first, _ in first }
        var matched = Set<String>()
        for file in phone {
            if let id = file.id, let twin = macByID[id], !matched.contains(id) {
                matched.insert(id)
                rows.append(PhoneRecipeRow(id: id, mac: twin, phone: file,
                                           status: status(mac: twin.revision, phone: file.revision, synced: synced[id],
                                                          sameContent: twin.content != nil && twin.content == file.content)))
            } else {
                rows.append(PhoneRecipeRow(id: "iphone:" + file.fileName, phone: file, status: .onlyPhone))
            }
        }
        for recipe in mac where !matched.contains(recipe.id) {
            rows.append(PhoneRecipeRow(id: recipe.id, mac: recipe, status: .onlyMac))
        }
        return rows.sorted { PresetName.key($0.name) < PresetName.key($1.name) }
    }
}

/// Per iPhone, each recipe's revisions on the Mac and on the iPhone when it was last exchanged.
enum PhoneRecipeSync {
    struct Pair: Codable, Hashable, Sendable {
        var mac: String?
        var phone: String?
    }

    static let key = "qlick.iphoneRecipesSynced"

    static func load(udid: String, defaults: UserDefaults = .standard) -> [String: Pair] { all(defaults)[udid] ?? [:] }

    static func remember(udid: String, id: String, mac: String?, phone: String?, defaults: UserDefaults = .standard) {
        var everything = all(defaults)
        everything[udid, default: [:]][id] = Pair(mac: mac, phone: phone)
        save(everything, defaults)
    }

    static func forget(udid: String, id: String, defaults: UserDefaults = .standard) {
        var everything = all(defaults)
        everything[udid]?[id] = nil
        save(everything, defaults)
    }

    private static func all(_ defaults: UserDefaults) -> [String: [String: Pair]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: Pair]].self, from: data)) ?? [:]
    }

    private static func save(_ everything: [String: [String: Pair]], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(everything) { defaults.set(data, forKey: key) }
    }
}
