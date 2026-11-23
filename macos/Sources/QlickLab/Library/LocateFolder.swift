// Qlick Lab — GPL-3.0-only.
import AppKit

/// Qlick Lab: Locate Folder. A Folder of an Archive that's offline (its disk taken out) or not found (moved, renamed)
/// is pointed at where its photographs are now: another disk holding the same copy, the disk under another name, the
/// folder moved in the Finder. The lab checks that the folder chosen holds the photographs it knows there (by their
/// names, the folders under it included), says how many it found, and moves every path it keeps there (`relocate`);
/// one ⌘Z puts them back. Nothing on disk moves.
extension LabState {
    func locateFolderPanel(_ path: String, archive: UUID) {
        let name = (path as NSString).lastPathComponent
        let panel = NSOpenPanel()
        panel.title = "Locate Folder"
        panel.message = "Where is “\(name)” now? Choose the folder that holds its photographs."
        panel.prompt = "Locate"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // The panel opens on the disks, never inside the Folder's old place: on a share that's gone or slow, the panel
        // itself would wait on it (and a folder of thousands of RAW files asks for as many icons).
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        LabPanel.begin(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.locateFolder(path, at: url.labStandardized.path, archive: archive) }
        }
    }

    /// Points the Folder at `path` to `new`, once what it holds there is checked.
    func locateFolder(_ path: String, at new: String, archive: UUID) {
        guard new != path else { return }
        let name = (path as NSString).lastPathComponent
        let known = projects.knownPhotographs(under: path, also: catalog.order)
        Task { [weak self] in
            // Looked for off the main thread, with a limit: the new place may be a disk that answers slowly.
            let relative = Array(known.map { String($0.dropFirst(path.count)) }.prefix(2000))
            let found = await Task.detached(priority: .userInitiated) {
                VolumeReach.look(new, patience: 20) { relative.filter { FileManager.default.fileExists(atPath: new + $0) }.count } ?? 0
            }.value
            guard let self else { return }
            let place = (new as NSString).lastPathComponent
            if !relative.isEmpty && found == 0 {
                let answer = await self.model.ask(AppAlert(
                    title: "None of “\(name)”’s photographs are in “\(place)”",
                    detail: "The lab knows \(known.count == 1 ? "1 photograph" : "\(known.count) photographs") in “\(name)”, and found none of them by name in the folder chosen. Its Boxes and Rolls would show them as missing.",
                    buttons: [.init(title: "Choose Another Folder…"), .init(title: "Locate Here Anyway"), .init(title: "Cancel", role: .cancel)]))
                switch answer.button {
                case 0: return self.locateFolderPanel(path, archive: archive)
                case 1: break
                default: return
                }
            }
            self.undoable("Locate Folder") { self.projects.relocate(from: path, to: new); return true }
            self.catalog.refresh()
            // The folder open on the sheet follows.
            if let open = self.model.library.directory?.labStandardized.path, open == path || open.hasPrefix(path + "/") {
                self.open(folder: URL(fileURLWithPath: ProjectStore.moved(open, from: path, to: new), isDirectory: true))
            }
            if !relative.isEmpty && found < relative.count {
                self.model.tell(AppAlert(
                    title: "“\(name)” located in “\(place)”",
                    detail: "\(found) of the \(relative.count) photographs looked for are there; the others stay missing until they're found."))
            }
        }
    }
}
