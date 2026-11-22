// Qlick Lab — GPL-3.0-only.
import AppKit
import UniformTypeIdentifiers

/// Catalogs: sets of projects kept apart. A catalog is a package (`Name.qlicklab`) holding its projects' small JSON
/// files, the import's Saved Settings and its memory of what it imported; the photographs stay where they are, so a catalog is
/// cheap to make, copy or archive. The lab opens one at a time; the first is the default, in Application Support.
@MainActor @Observable final class CatalogList {
    static let fileExtension = "qlicklab"
    static let type = UTType(exportedAs: "be.jackfrom.qlicklab.catalog", conformingTo: .package)
    static var defaultDirectory: URL { AppDataLocations.supportDirectory.appendingPathComponent("Projects", isDirectory: true) }
    private static let currentKey = "qlick.catalog", recentKey = "qlick.recentCatalogs"

    /// Catalogs opened before, most recent first, the current one included.
    private(set) var recent: [URL]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A catalogue on a disk that doesn't answer stays in the list: it's away, not gone.
        recent = (defaults.stringArray(forKey: Self.recentKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { VolumeReach.exists($0.path) || VolumeReach.isSilent($0.path) }
    }

    /// The catalogue to open at launch: the last one, while it's there and its disk answers. Otherwise the Default
    /// Catalog opens, and `missed` says which one couldn't (the lab says so; the next launch tries it again).
    var initial: URL {
        if let path = defaults.string(forKey: Self.currentKey) {
            if VolumeReach.exists(path, patience: 1.5) { return URL(fileURLWithPath: path, isDirectory: true) }
            if URL(fileURLWithPath: path, isDirectory: true).labStandardized != Self.defaultDirectory.labStandardized {
                Self.missed = (URL(fileURLWithPath: path, isDirectory: true), silent: VolumeReach.isSilent(path))
            }
        }
        return Self.defaultDirectory
    }

    /// The catalogue `initial` couldn't open: not there (its disk not connected) or its disk not answering.
    static var missed: (url: URL, silent: Bool)?

    func remember(_ url: URL) {
        let url = url.labStandardized
        defaults.set(url.path, forKey: Self.currentKey)
        guard url != Self.defaultDirectory.labStandardized else { return }
        recent = [url] + recent.filter { $0.labStandardized != url }
        recent = Array(recent.prefix(10))
        defaults.set(recent.map(\.path), forKey: Self.recentKey)
    }

    static func name(of url: URL) -> String {
        url.labStandardized == defaultDirectory.labStandardized ? "Default Catalog" : url.deletingPathExtension().lastPathComponent
    }
}

extension LabState {
    var catalogName: String { CatalogList.name(of: projects.directory) }

    /// Opens a catalog: its projects take the sidebar's and the library's place.
    func openCatalog(_ url: URL) {
        guard !model.cropping else { NSSound.beep(); return }
        var directory = url.labStandardized
        if directory.pathExtension.lowercased() != CatalogList.fileExtension, directory != CatalogList.defaultDirectory.labStandardized,
           (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { return }
        if directory.path == projects.directory.labStandardized.path { return show(.library) }
        // A disk that doesn't answer isn't waited for: the catalogue open stays.
        guard VolumeReach.answers(directory.path, patience: 1.5) else {
            model.error = "The catalog “\(CatalogList.name(of: directory))” can’t be opened: its disk, “\(VolumeReach.volumeName(of: directory.path))”, isn’t answering."
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directory = directory.labStandardized
        projects.open(directory: directory)
        projects.sidecars = model.sidecarLookup?.store
        projects.countAll()
        importer.loadProfiles(inCatalog: directory)
        catalogs.remember(directory)
        show(.library)
    }

    func newCatalogPanel() {
        let panel = NSSavePanel()
        panel.title = "New Catalog"
        panel.message = "A catalog holds its own Archives and Boxes. The photographs stay where they are."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled Catalog"
        panel.allowedContentTypes = [CatalogList.type]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                try? FileManager.default.removeItem(at: url)
                self?.openCatalog(url)
            }
        }
    }

    func openCatalogPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Catalog"
        panel.prompt = "Open"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [CatalogList.type]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.openCatalog(url) }
        }
    }

    /// Saves the open catalog. Projects are written as they change, so this flushes them and, for the default
    /// catalog, which has no file of its own to name, asks where to keep a copy.
    func saveCatalog() {
        if projects.directory.labStandardized == CatalogList.defaultDirectory.labStandardized { return saveCatalogAsPanel() }
        projects.saveAll()
        catalogs.remember(projects.directory)
    }

    /// Saves the open catalog's projects into a new one, which then stays open: the old one is left as it was.
    func saveCatalogAsPanel() {
        let panel = NSSavePanel()
        panel.title = "Save Catalog As"
        panel.message = "A copy of these Archives and Boxes in a catalog of its own, which then stays open."
        panel.prompt = "Save"
        panel.nameFieldStringValue = catalogName == "Default Catalog" ? "My Catalog" : catalogName + " copy"
        panel.allowedContentTypes = [CatalogList.type]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.saveCatalog(as: url) }
        }
    }

    func saveCatalog(as url: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            // The projects, and the Saved Settings with them.
            for file in (try? fm.contentsOfDirectory(at: projects.directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                try fm.copyItem(at: file, to: url.appendingPathComponent(file.lastPathComponent))
            }
            openCatalog(url)
        } catch {
            model.error = "The catalog couldn’t be saved: \(error.localizedDescription)"
        }
    }
}
