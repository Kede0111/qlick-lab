// Qlick Lab — GPL-3.0-only.
import AppKit
import Foundation

// Removing photographs: the lab's only way to delete besides the import's Move. ⌫ (Remove…) and Remove Rejected Photos…
// open one dialog (`RemoveQuestion`) that offers, from the safest: out of the Box or Roll open; out of Qlick Lab (the
// catalogue forgets them, the files stay: `ProjectStore.removed`); or Delete from Disk, to the Trash, asked a second
// time in red words. Nothing is ever deleted without both answers.

/// The catalogue's photographs removed from the lab, in one file beside the Archives: `removed.json`, top-level key
/// `qlick`. Paths only; the files themselves are never touched.
enum RemovedFile {
    static let fileName = "removed.json"
    static let schema = 1

    private struct File: Codable { var qlick: Content }
    private struct Content: Codable { var schema: Int; var photos: [String] }

    static func url(inCatalog directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The paths, or nil when there's no file, or one this version can't read (a newer schema is left alone).
    static func read(inCatalog directory: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url(inCatalog: directory)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.qlick.schema <= schema else { return nil }
        return Set(file.qlick.photos)
    }

    static func isForeign(inCatalog directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(inCatalog: directory).path) && read(inCatalog: directory) == nil
    }

    @discardableResult static func write(_ photos: Set<String>, inCatalog directory: URL) -> Bool {
        guard !isForeign(inCatalog: directory) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            if photos.isEmpty {
                if FileManager.default.fileExists(atPath: url(inCatalog: directory).path) { try FileManager.default.removeItem(at: url(inCatalog: directory)) }
                return true
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(File(qlick: Content(schema: schema, photos: photos.sorted()))).write(to: url(inCatalog: directory), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("removed: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

extension ProjectStore {
    /// Remove from Qlick Lab: the photographs (a duplicate stands for its photograph) leave every listing and every Box.
    /// Only the catalogue changes. Whether anything did.
    @discardableResult func removeFromLab(_ frames: [URL]) -> Bool {
        let paths = Self.paths(frames)
        guard !paths.isEmpty else { return false }
        let gone = Set(paths)
        func strip(_ box: LabBox) -> LabBox {
            var box = box
            box.frames.removeAll { gone.contains($0) }
            for index in box.rolls.indices { box.rolls[index].frames.removeAll { gone.contains($0) } }
            box.boxes = box.boxes.map(strip)
            return box
        }
        replaceBoxes(boxes.map(strip))
        replaceRemoved(removed.union(paths))
        return true
    }

    /// The photographs removed from the lab that lie in an Archive's Folders (or in folders under them).
    func removed(in archive: LabProject) -> [String] {
        let roots = archive.rolls.map { $0.url.labStandardized.path }
        return removed.filter { path in roots.contains { path.hasPrefix($0 + "/") } }.sorted()
    }
}

/// The Remove dialog: what it says and the choices it offers, the safest first (Return's).
struct RemoveQuestion: Equatable {
    enum Choice: Equatable { case holder, lab, disk, duplicates, cancel }

    var alert: AppAlert
    /// What each of `alert`'s buttons does, by index.
    var choices: [Choice]

    /// `photographs`: the photographs chosen (a duplicate counts as its photograph), one named by `name`.
    /// `duplicatesOnly`: only duplicates were chosen, so many. `holder`: the Box or Roll open, if one is.
    init(photographs: Int, name: String?, duplicatesOnly: Int = 0, holder: (name: String, roll: Bool)?, rejected: Bool = false) {
        func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
        var buttons: [AppAlert.Button] = [], choices: [Choice] = []
        let one = photographs == 1
        if let holder, duplicatesOnly == 0 {
            let kind = holder.roll ? "Roll" : "Box"
            buttons.append(.init(title: "Remove from “\(holder.name)”",
                                 detail: "Out of this \(kind) only. \(one ? "It stays" : "They stay") in \(one ? "its" : "their") Archive and in other Boxes."))
            choices.append(.holder)
        }
        let title: String, detail: String
        if duplicatesOnly > 0 {
            title = duplicatesOnly == 1 ? "Remove the duplicate\(name.map { " “\($0)”" } ?? "")?" : "Remove \(duplicatesOnly) duplicates?"
            detail = "A duplicate is a second version of a photograph, kept in its .qlick file. The photograph itself stays."
            buttons.append(.init(title: duplicatesOnly == 1 ? "Remove the Duplicate" : "Remove the Duplicates",
                                 detail: "\(duplicatesOnly == 1 ? "Its" : "Their") rating and edits leave the .qlick file. Undo brings \(duplicatesOnly == 1 ? "it" : "them") back."))
            choices.append(.duplicates)
        } else {
            let what = one ? (name.map { "“\($0)”" } ?? "this photograph") : count(photographs, "photograph")
            title = rejected ? (one ? "Remove the rejected photograph \(what)?" : "Remove the \(photographs) rejected photographs?") : "Remove \(what)?"
            detail = "Nothing leaves the disk unless you choose Delete from Disk."
            buttons.append(.init(title: "Remove from Qlick Lab",
                                 detail: "Out of \(one ? "its" : "their") Archive and every Box. The \(one ? "file stays" : "files stay") on the disk; "
                                    + "Undo, or Restore Removed Photos in the Archive’s menu, brings \(one ? "it" : "them") back."))
            choices.append(.lab)
            buttons.append(.init(title: "Delete from Disk…", role: .destructive,
                                 detail: "The \(one ? "file goes" : "files go") to the Trash with \(one ? "its" : "their") .qlick \(one ? "file" : "files"). You’ll be asked once more."))
            choices.append(.disk)
        }
        buttons.append(.init(title: "Cancel", role: .cancel))
        choices.append(.cancel)
        alert = AppAlert(title: title, detail: detail, buttons: buttons, defaultIndex: 0)
        self.choices = choices
    }

    func choice(_ button: Int) -> Choice { choices.indices.contains(button) ? choices[button] : .cancel }

    /// The second question before Delete from Disk, its warning in red. Return is Cancel.
    static func diskConfirmation(files: Int, duplicates: Int, following: Int, name: String?) -> AppAlert {
        let one = files == 1
        let what = one ? (name.map { "“\($0)”" } ?? "1 photograph") : "\(files) photographs"
        var detail = one ? "Its .qlick file goes with it" : "Their .qlick files go with them"
        if following > 0 { detail += following == 1 ? ", with 1 duplicate" : ", with \(following) duplicates" }
        detail += ". Undo puts \(one ? "it" : "them") back while \(one ? "it is" : "they are") in the Trash; emptying the Trash deletes \(one ? "it" : "them") for good."
        if duplicates > 0 {
            detail += duplicates == 1 ? " 1 duplicate of another photograph leaves its .qlick file." : " \(duplicates) duplicates of other photographs leave their .qlick files."
        }
        return AppAlert(title: "Delete \(what) from the disk?", detail: detail,
                        buttons: [.init(title: "Cancel", role: .cancel), .init(title: "Delete from Disk", role: .destructive)],
                        defaultIndex: 0,
                        warning: one ? "This deletes 1 photograph from the disk. It goes to the Trash."
                            : "This deletes \(files) photographs from the disk. They go to the Trash.")
    }
}

extension EditorModel {
    /// Remove… and Remove Rejected Photos…: the dialog, then what was chosen. `fromHolder` and `fromLab` are the
    /// catalogue's side (`LabState`); Delete from Disk is asked again before anything goes. The task, for the tests.
    @discardableResult func requestRemove(_ items: [URL], rejected: Bool = false, holder: (name: String, roll: Bool)?,
                                          fromHolder: @escaping ([URL]) -> Void, fromLab: @escaping ([URL]) -> Void) -> Task<Void, Never>? {
        var seen = Set<URL>()
        let items = items.filter { seen.insert($0).inserted }
        guard canDelete, !items.isEmpty else { return nil }
        let plan = deletePlan(items)
        var photoSeen = Set<URL>()
        let photos = items.map(\.photoFile).filter { photoSeen.insert($0).inserted }
        let question = RemoveQuestion(photographs: photos.count, name: photos.count == 1 ? photos[0].lastPathComponent : nil,
                                      duplicatesOnly: plan.files.isEmpty ? plan.duplicates.count : 0, holder: holder, rejected: rejected)
        return Task { [weak self] in
            guard let self else { return }
            let answer = await self.ask(question.alert)
            switch question.choice(answer.button) {
            case .holder: fromHolder(photos)
            case .lab: fromLab(items)
            case .duplicates: self.delete(plan)
            case .disk: await self.confirmDeleteFromDisk(plan)
            case .cancel: break
            }
        }
    }

    /// Delete from Disk's second question; the files go to the Trash only on its explicit answer. Never outright: a
    /// volume without a Trash keeps them.
    func confirmDeleteFromDisk(_ plan: DeletePlan) async {
        guard canDelete, let first = plan.items.first else { return }
        let folders = Set((plan.files.isEmpty ? [first] : plan.files).map { $0.photoFile.deletingLastPathComponent() })
        if let locked = folders.first(where: { !PhotoLibrary.canWrite(in: $0) }) {
            error = "Nothing was deleted: the folder “\(locked.lastPathComponent)” is read-only."
            return
        }
        if !plan.files.isEmpty, let bare = folders.first(where: { !trash.available($0) }) {
            tell(AppAlert(title: "Nothing was deleted",
                          detail: "The disk holding “\(bare.lastPathComponent)” has no Trash, and Qlick Lab never deletes a photograph outright. "
                            + "Remove it from Qlick Lab instead, or delete the files in the Finder."))
            return
        }
        let name = plan.files.count == 1 ? library.name(of: plan.files[0]) : nil
        let alert = RemoveQuestion.diskConfirmation(files: plan.files.count, duplicates: plan.duplicates.count, following: plan.following, name: name)
        guard await ask(alert).button == 1 else { return }
        delete(plan)
    }
}

extension LabState {
    /// ⌫, Remove…: the selection (or the frames a menu was opened on).
    func requestRemove(_ items: [URL]? = nil, rejected: Bool = false) {
        let items = items ?? model.deleteTargets
        let holder = openHolder.flatMap { holder in projects.shortName(holder).map { (name: $0, roll: { if case .roll = holder { true } else { false } }()) } }
        model.requestRemove(items, rejected: rejected, holder: holder,
                            fromHolder: { [weak self] in self?.removeFromOpenHolder($0) },
                            fromLab: { [weak self] in self?.removeFromLab($0) })
    }

    /// Remove Rejected Photos…: the rejected photographs of what's listed.
    func requestRemoveRejected() { requestRemove(model.rejected, rejected: true) }

    /// Remove from Qlick Lab: out of the listing and every Box, one undo step. The files aren't touched.
    func removeFromLab(_ items: [URL]) {
        guard model.canDelete, !items.isEmpty else { return }
        var gone = Set(items)
        for photo in Set(items.map(\.photoFile)) {
            gone.insert(photo)
            for id in model.library.duplicates[photo] ?? [] { gone.insert(photo.variant(id)) }
        }
        let next = model.nextLeaving(gone)
        let openGone = model.sourceItem.map { gone.contains($0) || gone.contains($0.photoFile) } ?? false
        // The open photograph's last edits are written before it goes.
        if openGone { model.flushSidecar() }
        let photos = Array(Set(items.map(\.photoFile)))
        let everything: Bool = { if case .some(.none) = next { true } else { false } }()
        // Everything listed goes: the list closes, and Undo opens it again, once the photographs are back.
        if everything, let view = openView, let undo = model.undoManager {
            undo.registerUndo(withTarget: libraryEdits) { [weak self] _ in Task { @MainActor in self?.open(view) } }
        }
        guard undoable("Remove \(Self.title(photos.count)) from Qlick Lab", { projects.removeFromLab(photos) }) else { return }
        model.moveOn(to: next)
        if everything { show(.library) }
        if openGone, model.mode == .grid { model.sourceDeleted = true }
        model.libraryNote = EditorModel.LibraryNote(text: "Removed", detail: "\(photos.count == 1 ? "1 photograph" : "\(photos.count) photographs") from Qlick Lab",
                                                    serial: (model.libraryNote?.serial ?? 0) + 1)
    }

    /// The photographs removed from an Archive's Folders, put back: one undo step.
    func restoreRemoved(in archive: LabProject) {
        let paths = projects.removed(in: archive)
        guard !paths.isEmpty else { return }
        if undoable("Restore \(Self.title(paths.count))", { projects.replaceRemoved(projects.removed.subtracting(paths)); return true }) {
            model.libraryNote = EditorModel.LibraryNote(text: "Restored", detail: "\(paths.count == 1 ? "1 photograph" : "\(paths.count) photographs") in “\(archive.name)”",
                                                        serial: (model.libraryNote?.serial ?? 0) + 1)
        }
    }

    /// What's listed follows the photographs removed or put back: the Folders' trees holding them (read now, as
    /// the lists of an Archive are made from them), the counts, the listing open.
    func followRemoved(_ changed: Set<String>) {
        for root in projects.folders.roots where changed.contains(where: { $0.hasPrefix(root.path + "/") }) {
            projects.folders.rescanNow(root)
        }
        projects.countAll()
        model.library.refreshNow()
    }
}
