// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Where the previews built ahead are kept, and how much room they may take: on the start-up disk's caches unless
/// another folder (another disk) is chosen. Two kinds, as Lightroom keeps standard and smart previews:
/// - each photograph's develop, 2560 pixels, about 1 MB: it shows the moment the photograph opens;
/// - its proxy, the RAW's data reduced to 2560 pixels (about 9 MB, a third of what half floats took): Develop edits
///   it at the size it's shown, so opening a photograph and its first edits never wait for the RAW to be read.
///   100 % and export read it.
/// Past the limit the least recently used go first; emptied, they're made again as photographs are opened.
enum PreviewStorage {
    static let folderKey = "qlick.previewsFolder", limitKey = "qlick.previewsLimitGB", proxiesKey = "qlick.proxies"
    /// Whether proxies are built ahead for every photograph of a folder, or only as photographs are opened: a
    /// proxy is nine times a developed preview's size, which counts after a large import.
    static var buildsProxiesAhead: Bool { UserDefaults.standard.string(forKey: proxiesKey) != "opened" }
    static let limits = [2, 5, 10, 20, 50, 100]

    static var defaultDirectory: URL { AppDataLocations.cachesDirectory.appendingPathComponent("Renders", isDirectory: true) }
    /// The chosen folder, or nil for the default.
    static var chosenFolder: URL? { UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var directory: URL { chosenFolder.map { $0.appendingPathComponent("Qlick Lab Previews", isDirectory: true) } ?? defaultDirectory }
    static var limitGB: Int { (UserDefaults.standard.object(forKey: limitKey) as? Int).flatMap { limits.contains($0) ? $0 : nil } ?? 10 }
    static var limitBytes: Int { limitGB * 1024 * 1024 * 1024 }
    /// The developed previews' share of the limit: a twentieth, at least 256 MB; the proxies take the rest.
    static var rendersLimit: Int { max(limitBytes / 20, 256 * 1024 * 1024) }
    static var proxiesLimit: Int { max(limitBytes - rendersLimit, 0) }

    static func store() -> EditedThumbnailStore { EditedThumbnailStore(directory: directory, limit: rendersLimit) }

    /// The proxies' folder, inside the previews'.
    static var proxyDirectory: URL { directory.appendingPathComponent("Proxies", isDirectory: true) }

    /// As the helper's (`proxy.rs`): 2 is the compact proxy.
    private static let proxyExtension = "qnproxy2", proxyVersion = 2
    /// The proxies of before, three times the size: never read again, so they go.
    private static let formerProxyExtensions: Set<String> = ["qnproxy"]

    static func removeFormerProxies(in folder: URL = proxyDirectory) {
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where formerProxyExtensions.contains(file.pathExtension) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// `photo`'s proxy file, named as the engine names it (`proxy_file` in the helper): its path, size, modification
    /// time in whole seconds and lens correction.
    static func proxyFile(for photo: URL, lensCorrection: Bool) -> URL? {
        guard let values = try? photo.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        let name = "\(photo.path)|\(size)|\(Int(modified.timeIntervalSince1970.rounded(.down)))|\(lensCorrection ? 1 : 0)|v\(proxyVersion)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        return proxyDirectory.appendingPathComponent(String(format: "%016llx", hash) + "." + proxyExtension)
    }

    private static func proxies(in folder: URL = proxyDirectory) -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { file in
            guard file.pathExtension == proxyExtension, let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    static func proxiesSize() -> Int { proxies().reduce(0) { $0 + $1.size } }

    /// The least recently used proxies go until they're under their share of the limit (three quarters of it, so it
    /// isn't done at every one).
    static func pruneProxies() {
        let limit = proxiesLimit
        var entries = proxies(), total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    static func removeProxies(in folder: URL = proxyDirectory) {
        for entry in proxies(in: folder) { try? FileManager.default.removeItem(at: entry.url) }
        removeFormerProxies(in: folder)
        // Halves the helper left behind.
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension.hasPrefix("part") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension EditorModel {
    func previewCacheSize() async -> Int {
        let archive = renderArchive
        return await Task.detached(priority: .utility) { archive.size() + PreviewStorage.proxiesSize() }.value
    }

    /// Removes every preview built ahead; they're built again as photographs are opened (or by Build Previews).
    func emptyPreviewCache() async {
        lab.previewBuilder.cancel()
        let archive = renderArchive
        await Task.detached(priority: .userInitiated) { archive.removeAll(); PreviewStorage.removeProxies() }.value
    }

    /// Keeps the previews in `folder` (nil: the start-up disk's caches). Those already built are removed from the
    /// old place, not moved: they're quick to build again, and a copy across disks would take long.
    func movePreviews(to folder: URL?) async {
        lab.previewBuilder.cancel()
        let old = renderArchive, oldProxies = PreviewStorage.proxyDirectory
        if let folder { UserDefaults.standard.set(folder.path, forKey: PreviewStorage.folderKey) }
        else { UserDefaults.standard.removeObject(forKey: PreviewStorage.folderKey) }
        guard PreviewStorage.directory.standardizedFileURL != old.directory.standardizedFileURL else { return }
        renderArchive = PreviewStorage.store()
        await Task.detached(priority: .utility) {
            old.removeAll()
            PreviewStorage.removeProxies(in: oldProxies)
            try? FileManager.default.removeItem(at: oldProxies)
            // The folder the lab made, if it's empty now.
            if (try? FileManager.default.contentsOfDirectory(atPath: old.directory.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: old.directory)
            }
        }.value
        lab.previewBuilder.folderChanged()
    }

    func setPreviewLimit(_ gigabytes: Int) {
        UserDefaults.standard.set(gigabytes, forKey: PreviewStorage.limitKey)
        renderArchive = PreviewStorage.store()
        let archive = renderArchive
        Task.detached(priority: .utility) { archive.prune(); PreviewStorage.pruneProxies() }
    }
}

/// Settings › Upkeep › Previews: where they are, the room they take, and emptying them.
struct PreviewStorageSection: View {
    let model: EditorModel
    @State private var bytes: Int?
    @State private var busy = false
    @State private var limit = PreviewStorage.limitGB
    @State private var folder = PreviewStorage.directory
    @State private var proxies = PreviewStorage.buildsProxiesAhead ? "all" : "opened"

    var body: some View {
        InkSection(title: "Previews") {
            ButtonRow {
                FigureText(figure: bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…",
                           trail: "of \(limit) GB")
            } button: {
                Button("Empty Preview Cache") {
                    Task { busy = true; await model.emptyPreviewCache(); await refresh(); busy = false }
                }
                .buttonStyle(OutlinedButtonStyle())
                .inkDisabled(busy || bytes == 0)
            }
            ChoiceRow(title: "Keep at most", items: PreviewStorage.limits.map { .option("\($0) GB", tag: String($0)) },
                      selection: String(limit)) { tag in
                guard let value = Int(tag) else { return }
                limit = value; model.setPreviewLimit(value)
                Task { try? await Task.sleep(for: .seconds(1)); await refresh() }
            }
            ChoiceRow(title: "Build proxies", items: [.option("For every photograph", tag: "all"), .option("Only as photographs are opened", tag: "opened")],
                      selection: proxies) { tag in
                proxies = tag
                UserDefaults.standard.set(tag, forKey: PreviewStorage.proxiesKey)
                if tag == "all" { model.lab.previewBuilder.folderChanged() }
            }
            ButtonRow {
                Text(folder.path)
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            } button: {
                HStack(spacing: 6) {
                    Button("Show") {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .help("Show the previews' folder in the Finder")
                    Button("Change…") { choose() }.buttonStyle(OutlinedButtonStyle()).inkDisabled(busy)
                }
            }
            if PreviewStorage.chosenFolder != nil {
                ButtonRow { EmptyView() } button: {
                    Button("Use the Start-up Disk") {
                        Task { busy = true; await model.movePreviews(to: nil); folder = PreviewStorage.directory; await refresh(); busy = false }
                    }
                    .buttonStyle(OutlinedButtonStyle()).inkDisabled(busy)
                }
            }
            HintText("The oldest go first at the limit. A new folder takes effect at the next launch.")
        }
        .task { await refresh() }
    }

    private func refresh() async { bytes = await model.previewCacheSize() }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Where to Keep the Previews"
        panel.message = "Qlick Lab keeps its previews in a folder “Qlick Lab Previews” inside the folder you choose."
        panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Task { busy = true; await model.movePreviews(to: url); folder = PreviewStorage.directory; await refresh(); busy = false }
            }
        }
    }
}
