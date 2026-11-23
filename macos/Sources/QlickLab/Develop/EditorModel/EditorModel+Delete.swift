// Qlick Lab — GPL-3.0-only. Part of EditorModel (Develop/EditorModel.swift holds its stored state).
import Accelerate
import AppKit
import CoreVideo
import CryptoKit
import ImageIO
import IOSurface
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension EditorModel {
    // MARK: Delete


    /// What Delete acts on: as the rating keys, the grid's selection, or in
    /// the edit view the open photograph only.
    var deleteTargets: [URL] { ratingTargets }

    /// Nothing is cropped, exported or saved from a file that might go.
    var canDelete: Bool { !closing && !cropping && !exporting && !saving }

    /// The folder's rejected photographs and duplicates, filtered out or not.
    var rejected: [URL] { library.items.map(\.url).filter { library.summary(for: $0).flag == .reject } }

    func deletePlan(_ items: [URL]) -> DeletePlan { DeletePlan(items) { library.duplicates[$0] ?? [] } }

    /// Delete from Disk, once asked twice (`LabState.requestRemove`): moves `plan`'s photographs to the Trash with
    /// their sidecars, and removes its duplicates from theirs, as one undo step. If what was
    /// current goes, the next photograph shown becomes current.
    func delete(_ plan: DeletePlan, permanent: Bool = false) {
        guard canDelete, !plan.isEmpty else { return }
        // The open photograph's last edits go to its sidecar first, and so
        // to the Trash with it, or into the snapshot Undo puts back.
        flushSidecar()
        var gone = Set(plan.items)
        for file in plan.files { for id in library.duplicates[file] ?? [] { gone.insert(file.variant(id)) } }
        let next = nextLeaving(gone)
        let open = sourceItem, openGone = sourceItem.map(gone.contains) ?? false
        // Nothing more is written for it.
        if openGone { sidecarWrite?.cancel(); sidecarWrite = nil; photoSidecar = nil }

        // A duplicate of a photograph that stays leaves its sidecar.
        var before: [URL: JSONValue?] = [:], failure: String?
        if let sidecars, sidecars.writes {
            for item in plan.duplicates {
                guard let id = item.variantID else { continue }
                let photo = item.photoFile
                do {
                    guard let raw = try sidecars.readPending(photo: photo) else { continue }
                    let removed = try PhotoSidecar.removing(variant: id, from: raw)
                    if before[photo] == nil { before[photo] = .some(raw) }
                    sidecars.enqueue(SidecarPatch(variant: id, replacement: .some(removed), defaultsVersion: SidecarDefaults.latest,
                                                  app: Self.appVersion), for: photo)
                } catch {
                    failure = failure ?? "“\(library.name(of: item))” couldn’t be removed: its .qlick file can’t be changed."
                }
            }
            library.reload(Array(before.keys))
        }
        library.remove(plan.files)

        moveOn(to: next)
        if openGone, mode == .grid { sourceDeleted = true }

        let record = TrashRecord()
        if !permanent || !before.isEmpty {
            let reopen = openGone ? open : nil
            undoManager?.registerUndo(withTarget: libraryUndo) { [weak self] _ in
                MainActor.assumeIsolated { self?.undoDelete(permanent ? plan.withoutFiles : plan, record: record, sidecars: before, reopen: reopen) }
            }
            undoManager?.setActionName(plan.actionName)
        }
        let files = plan.files, trash = self.trash, sidecars = self.sidecars, removing = failure
        record.task = Task { [weak self] in
            // Everything queued is written first, so nothing writes a sidecar
            // beside a photograph that's gone.
            if let failures = await sidecars?.flush() { for (failed, reason) in failures { self?.sidecarFailed(failed, reason) } }
            let moved = await Task.detached(priority: .userInitiated) { () -> (moves: [(original: URL, trashed: URL)], failure: String?) in
                var moves: [(original: URL, trashed: URL)] = [], failure: String?
                for file in files {
                    let sidecars = [PhotoSidecar.url(for: file), PhotoSidecar.legacyURL(for: file)]
                    for item in [file] + sidecars where item == file || FileManager.default.fileExists(atPath: item.path) {
                        do {
                            if permanent { try trash.remove(item) } else { moves.append((item, try trash.trash(item))) }
                        } catch {
                            failure = failure ?? "“\(file.lastPathComponent)” couldn’t be deleted. \(error.localizedDescription)"
                            break
                        }
                    }
                }
                return (moves, failure)
            }.value
            record.moves = moved.moves
            guard let self else { return }
            if let reason = moved.failure ?? removing { self.error = reason }
            self.library.unhide(files)
        }
        if files.isEmpty, let failure { error = failure }
    }

    /// Where the selection goes when `gone` leave the listing: nil if what's current stays; else the photograph to
    /// show next, or nil inside when nothing is left. Asked before they go.
    func nextLeaving(_ gone: Set<URL>) -> URL?? {
        let current = mode == .grid ? selection.current : sourceItem
        return current.flatMap { current -> URL?? in
            guard gone.contains(current) else { return nil }
            return .some(Self.next(after: current, in: shownPhotos.map(\.url), skipping: gone)
                ?? Self.next(after: current, in: library.items.map(\.url), skipping: gone))
        }
    }

    /// The selection moves on, once photographs have left the listing (`nextLeaving`).
    func moveOn(to next: URL??) {
        switch next {
        case .some(.some(let next)):
            if mode == .grid { selection.select(next) } else { self.open(next, restoring: nil) }
        case .some(.none):
            // Nothing is left to show.
            forgetPhotograph()
            selection = LibrarySelection(); mode = .photo
        case .none:
            selection.prune(to: Set(library.items.map(\.url)))
        }
    }

    /// The first photograph after `item` in `order` that isn't `gone`, or
    /// else the last one before it.
    nonisolated static func next(after item: URL, in order: [URL], skipping gone: Set<URL>) -> URL? {
        guard let index = order.firstIndex(of: item) else { return order.first { !gone.contains($0) } }
        return order[index...].first { !gone.contains($0) } ?? order[..<index].last { !gone.contains($0) }
    }

    /// Puts back what `plan` deleted: the files from the Trash and the
    /// duplicates' sidecars as they were. What comes back is selected; the
    /// edit view opens the photograph it showed.
    func undoDelete(_ plan: DeletePlan, record: TrashRecord, sidecars before: [URL: JSONValue?], reopen: URL?) {
        guard !closing else { return }
        // Redo deletes them again, without asking.
        undoManager?.registerUndo(withTarget: libraryUndo) { [weak self] _ in MainActor.assumeIsolated { self?.delete(plan) } }
        undoManager?.setActionName(plan.actionName)
        let sidecars = self.sidecars
        for (photo, raw) in before {
            sidecars?.enqueue(SidecarPatch(variant: "", replacement: .some(raw), defaultsVersion: SidecarDefaults.latest, app: Self.appVersion), for: photo)
            library.reload(photo)
        }
        Task { [weak self] in
            await record.task?.value
            let moves = record.moves
            record.moves = []
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                var failure: String?
                for move in moves.reversed() {
                    do { try FileManager.default.moveItem(at: move.trashed, to: move.original) } catch {
                        failure = failure ?? "“\(move.original.lastPathComponent)” couldn’t be put back. \(error.localizedDescription)"
                    }
                }
                return failure
            }.value
            if let failures = await sidecars?.flush() { for (failed, reason) in failures { self?.sidecarFailed(failed, reason) } }
            guard let self, !self.closing else { return }
            if let failure { self.error = failure }
            self.library.unhide(plan.files)
            let restored = plan.items.filter { FileManager.default.fileExists(atPath: $0.photoFile.path) }
            if self.mode == .photo, let reopen, restored.contains(reopen) || restored.contains(reopen.photoFile) {
                self.open(reopen, restoring: nil)
            } else if self.source == nil, let first = restored.first {
                self.open(first, restoring: nil)
            }
            if self.mode == .grid, !restored.isEmpty { self.selection.select(restored) }
        }
    }

    /// After changing several sidecars: the library shows them, one undo
    /// step puts back `before`, and they're written.
    func finishSidecarChange(_ before: [URL: JSONValue?], action: String, openChanged: Bool) {
        guard !before.isEmpty else { return }
        for photo in before.keys { library.reload(photo) }
        // The open photograph's own history is of edits that are gone.
        if openChanged { undoManager?.removeAllActions(withTarget: self) }
        registerSidecarUndo(before, action: action)
        writeSidecars()
    }

    func registerSidecarUndo(_ files: [URL: JSONValue?], action: String) {
        undoManager?.registerUndo(withTarget: libraryUndo) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreSidecars(files, action: action) }
        }
        undoManager?.setActionName(action)
    }

    /// Puts `files` back as they were (undo), keeping them as they are now
    /// for redo. The open photograph shows its edits as restored; a
    /// duplicate that's gone gives way to its photograph.
    func restoreSidecars(_ files: [URL: JSONValue?], action: String) {
        guard let sidecars, !closing else { return }
        // Qlick Lab: a recipe still balancing would write over what's put back.
        applyTask?.cancel()
        sidecarWrite?.cancel(); sidecarWrite = nil
        var now: [URL: JSONValue?] = [:]
        for (photo, raw) in files {
            let current: JSONValue?
            do { current = try sidecars.readPending(photo: photo) } catch { continue }
            now[photo] = .some(current)
            sidecars.enqueue(SidecarPatch(variant: "", replacement: .some(raw), defaultsVersion: SidecarDefaults.latest, app: Self.appVersion), for: photo)
            library.reload(photo)
        }
        registerSidecarUndo(now, action: action)
        if let current = selection.current, let id = current.variantID, library.duplicates[current.photoFile]?.contains(id) != true {
            selection.select(current.photoFile)
        }
        if let source, files.keys.contains(source) {
            if let id = sourceVariant, library.duplicates[source]?.contains(id) != true {
                open(source, restoring: nil)
            } else {
                cancelBrightnessMatch(); brightnessMatchFailure = nil
                customFilmFormat = false
                adoptEdits(for: source, restore: readSidecar(source, variant: sourceVariant), legacy: nil, previous: state)
                undoManager?.removeAllActions(withTarget: self)
                changed()
            }
        }
        writeSidecars()
    }

    /// Writes every queued sidecar change.
    func writeSidecars() {
        guard let sidecars else { return }
        Task { [weak self] in
            let failures = await sidecars.flush()
            for (failed, reason) in failures { self?.sidecarFailed(failed, reason) }
        }
    }
}
