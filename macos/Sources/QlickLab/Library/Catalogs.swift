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
            if URL(fileURLWithPath: path).standardizedFileURL != Self.defaultDirectory.standardizedFileURL {
                Self.missed = (URL(fileURLWithPath: path, isDirectory: true), silent: VolumeReach.isSilent(path))
            }
        }
        return Self.defaultDirectory
    }

    /// The catalogue `initial` couldn't open: not there (its disk not connected) or its disk not answering.
    static var missed: (url: URL, silent: Bool)?

    func remember(_ url: URL) {
        let url = url.standardizedFileURL
        defaults.set(url.path, forKey: Self.currentKey)
        guard url != Self.defaultDirectory.standardizedFileURL else { return }
        recent = [url] + recent.filter { $0.standardizedFileURL != url }
        recent = Array(recent.prefix(10))
        defaults.set(recent.map(\.path), forKey: Self.recentKey)
    }

    static func name(of url: URL) -> String {
        url.standardizedFileURL == defaultDirectory.standardizedFileURL ? "Default Catalog" : url.deletingPathExtension().lastPathComponent
    }
}

extension LabState {
    var catalogName: String { projects.isOpen ? CatalogList.name(of: projects.directory) : "No Catalog" }

    /// Opens a catalog in place of the one open, which closes whole first: one catalogue at a time.
    func openCatalog(_ url: URL) {
        var directory = url.standardizedFileURL
        if directory.pathExtension.lowercased() != CatalogList.fileExtension, directory != CatalogList.defaultDirectory.standardizedFileURL,
           (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { return }
        if projects.isOpen, directory.path == projects.directory.standardizedFileURL.path { return show(.library) }
        // A disk that doesn't answer isn't waited for: the catalogue open stays.
        guard VolumeReach.answers(directory.path, patience: 1.5) else {
            model.error = "The catalog “\(CatalogList.name(of: directory))” can’t be opened: its disk, “\(VolumeReach.volumeName(of: directory.path))”, isn’t answering."
            return
        }
        guard leaveCatalog() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directory = directory.standardizedFileURL
        projects.open(directory: directory)
        projects.sidecars = model.sidecarLookup?.store
        projects.countAll()
        importer.loadProfiles(inCatalog: directory)
        followNewCatalog()
        catalogs.remember(directory)
        show(.library)
    }

    /// File › Close Catalog: the catalogue closes whole and the lab stays open, holding nothing, until another is
    /// opened (`NoCatalogView`). The next launch opens the last catalogue open, as before.
    func closeCatalog() {
        guard projects.isOpen, leaveCatalog() else { return }
        projects.close()
        followNewCatalog()
        show(.library)
    }

    /// Closes everything the open catalogue showed or was doing, before another takes its place: the photograph
    /// and its folder or list, the loupe, the comparison, Back and Forward, the undo steps, the background work on
    /// its photographs, what Import had chosen in it, its lists. False (and nothing changes) while that can't be done:
    /// a crop under way, an import running.
    @discardableResult func leaveCatalog() -> Bool {
        if model.cropping { NSSound.beep(); return false }
        if importer.isBusy {
            model.error = "An import is under way in “\(catalogName)”. Let it finish, or stop it, before changing catalog."
            return false
        }
        model.closeFolder()
        // A photograph opened alone (not from a folder) closes too.
        model.forgetPhotograph()
        loupe = nil
        compare = CompareSetup()
        gamutCheck = nil
        copiedPhotos = []
        foundQuery = ""; libraryQuery = ""
        naming = nil; smartRollDraft = nil
        sidebarFold = SidebarFold()
        forgetPlaces()
        model.undoManager?.removeAllActions()
        previewBuilder.cancel(); proxyMaker.cancel()
        importer.forgetCatalog()
        PhotoFolder.forgetLists()
        return true
    }

    /// The index and what's worked out from it follow the catalogue now, not a moment later: nothing of the one
    /// before is listed meanwhile (All Photographs, Picks, By Date, the search).
    private func followNewCatalog() {
        catalogDirectory = projects.directory.standardizedFileURL.path
        catalog.open(catalog: projects.directory, cache: projects.isOpen && NSClassFromString("XCTestCase") == nil)
        finding = FindingCache()
        if projects.isOpen { catalog.refresh(after: .milliseconds(300)) }
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
        guard projects.isOpen else { return }
        if projects.directory.standardizedFileURL == CatalogList.defaultDirectory.standardizedFileURL { return saveCatalogAsPanel() }
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
        guard projects.isOpen else { return }
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
