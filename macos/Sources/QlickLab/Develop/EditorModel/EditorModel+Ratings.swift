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
    // MARK: Ratings and flags

    /// What a rating or flag key did, shown briefly over the canvas.
    struct LibraryNote: Equatable {
        var text: String
        /// Why it wasn't saved, if it wasn't.
        var detail: String?
        /// How many photographs it changed: several in the grid.
        var count = 1
        var serial: Int
    }

    /// The open photograph's rating and flag.
    var currentSummary: LibrarySummary? { sourceItem.map { library.summary(for: $0) } }

    /// What rating and flag commands act on: in the grid, every selected
    /// photograph it shows; in the edit view the current one only, so a
    /// forgotten selection in the strip never rates twenty photographs.
    var ratingTargets: [URL] {
        guard mode == .grid else { return sourceItem.map { [$0] } ?? [] }
        return selection.ordered(shownPhotos.map(\.url))
    }

    /// Rates what rating commands act on, 0 (none) to 5 stars.
    func setRating(_ stars: Int, targets: [URL]? = nil) {
        changeLibrary(action: "Rating", targets: targets) { $0.rating = max(0, min(5, stars)) } note: { Self.ratingText($0.rating) }
    }
    func changeRating(by offset: Int) {
        changeLibrary(action: "Rating", many: offset > 0 ? "Rating Raised" : "Rating Lowered") {
            $0.rating = max(0, min(5, $0.rating + offset))
        } note: { Self.ratingText($0.rating) }
    }
    func setFlag(_ flag: PhotoSidecar.Flag?, targets: [URL]? = nil) {
        changeLibrary(action: "Flag", targets: targets) { $0.flag = flag } note: { Self.flagText($0.flag) }
    }

    /// Qlick Lab: the colour label of what rating commands act on; nil takes it off.
    func setLabel(_ label: ColorLabel?, targets: [URL]? = nil) {
        changeLibrary(action: "Colour Label", targets: targets) { $0.label = label } note: { summary in
            summary.label.map { LabelNames.name($0) } ?? "No Label"
        }
    }

    /// A label key: sets it, or takes it off if every photograph it acts on has it already.
    func toggleLabel(_ label: ColorLabel, targets: [URL]? = nil) {
        let targets = targets ?? ratingTargets
        let all = !targets.isEmpty && targets.allSatisfy { library.summary(for: $0).label == label }
        setLabel(all ? nil : label, targets: targets)
    }

    /// Adds keywords to what rating commands act on (each keeps those it has).
    func addKeywords(_ words: [String], targets: [URL]? = nil) {
        let words = PhotoWords.clean(words)
        guard !words.isEmpty else { return }
        changeLibrary(action: "Add Keyword", targets: targets, advancing: false) { summary in
            summary.words.keywords = PhotoWords.clean(summary.words.keywords + words)
        } note: { _ in words.count == 1 ? "Keyword “\(words[0])”" : "\(words.count) Keywords" }
    }

    func removeKeyword(_ word: String, targets: [URL]? = nil) {
        changeLibrary(action: "Remove Keyword", targets: targets, advancing: false) { summary in
            summary.words.keywords.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        } note: { _ in "Keyword “\(word)” Removed" }
    }

    /// ⌥1…⌥9: the keyword set's keyword, added, or taken off when every photograph has it already.
    func toggleKeyword(_ word: String, targets: [URL]? = nil) {
        let targets = targets ?? ratingTargets
        guard !word.isEmpty, !targets.isEmpty else { return }
        if targets.allSatisfy({ library.summary(for: $0).words.has(keyword: word) }) { removeKeyword(word, targets: targets) }
        else { addKeywords([word], targets: targets) }
    }

    /// The title or caption of one photograph.
    func setTitle(_ title: String, caption: String, of photo: URL) {
        changeLibrary(action: "Title and Caption", targets: [photo], advancing: false) { summary in
            summary.words.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            summary.words.caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        } note: { _ in "Title and Caption" }
    }

    func hideLibraryNote(_ serial: Int) { if libraryNote?.serial == serial { libraryNote = nil } }

    nonisolated static func ratingText(_ stars: Int) -> String { stars == 0 ? "No Rating" : String(repeating: "★", count: stars) }
    nonisolated static func flagText(_ flag: PhotoSidecar.Flag?) -> String {
        switch flag { case .pick: "Pick"; case .reject: "Rejected"; case nil: "Unflagged" }
    }

    /// `many` is the note for several photographs, when `note` would differ
    /// between them.
    func changeLibrary(action: String, many: String? = nil, targets: [URL]? = nil, advancing: Bool = true, _ change: (inout LibrarySummary) -> Void,
                               note: (LibrarySummary) -> String) {
        let targets = targets ?? ratingTargets
        guard !targets.isEmpty, !closing else { return }
        let order = shownPhotos.map(\.url), view = libraryView
        var unsaved: String?, last = LibrarySummary(), queued = false, befores: [URL: LibrarySummary] = [:]
        for photo in targets {
            let before = library.summary(for: photo)
            var after = before
            change(&after)
            last = after
            guard after != before else { continue }
            befores[photo] = before
            let reason = saveLibraryChange(from: before, to: after, photo: photo)
            if reason == nil { queued = true } else if unsaved == nil { unsaved = reason }
            library.set(after, for: photo)
        }
        if queued { flushLibraryChanges() }
        let text = targets.count == 1 ? note(last) : many ?? note(last)
        libraryNote = LibraryNote(text: text, detail: unsaved, count: targets.count, serial: (libraryNote?.serial ?? 0) + 1)
        moveOn(after: targets, order: order, advancing: advancing)
        registerLibraryUndo(befores, from: libraryView, to: view, action: action)
    }

    /// After rating or flagging `targets`: those the filter now leaves out
    /// go from the strip and the grid at once, the current photograph too.
    /// The next one shown becomes current (in the edit view it opens), or
    /// the one before at the end. With none left the grid shows that
    /// nothing matches, as it does for a filter nothing passes.
    func moveOn(after targets: [URL], order: [URL], advancing: Bool = true) {
        let dropped = library.filter.active ? Set(targets.filter { !library.filter.includes(library.summary(for: $0)) }) : []
        if !dropped.isEmpty {
            let current = mode == .photo ? sourceItem : selection.current
            if let current, dropped.contains(current) {
                if let next = Self.next(after: current, in: order, skipping: dropped) {
                    if mode == .photo { open(next) } else { selection.select(next) }
                } else {
                    // The edit view has nothing to show, so the grid opens
                    // on its empty sheet; the open photograph stays loaded
                    // behind it for Undo or another filter to bring back.
                    if mode == .photo { showGrid() }
                    if mode == .grid { selection = LibrarySelection() }
                }
                return
            }
            selection.prune(to: Set(shownPhotos.map(\.url)))
        }
        let once = advanceOnce
        advanceOnce = false
        guard advanceAfterRating || once, advancing else { return }
        if mode == .photo { step(by: 1) } else if targets.count == 1 { move(by: 1, extending: false) }
    }

    func flushLibraryChanges() {
        guard let sidecars else { return }
        Task { [weak self] in
            let failures = await sidecars.flush()
            for (failed, reason) in failures { self?.sidecarFailed(failed, reason) }
        }
    }

    /// Where the library stood: the view, its selection and the open photograph.
    struct LibraryView: Equatable {
        var mode: LibraryMode
        var selection: LibrarySelection
        var open: URL?
    }

    var libraryView: LibraryView { LibraryView(mode: mode, selection: selection, open: sourceItem) }

    /// One undo step puts the ratings and flags in `summaries` back. If
    /// nothing has moved since (`now`), the view goes back to `then` too, so
    /// a photograph the filter dropped comes back as the current one.
    func registerLibraryUndo(_ summaries: [URL: LibrarySummary], from now: LibraryView, to then: LibraryView, action: String) {
        guard !summaries.isEmpty else { return }
        undoManager?.registerUndo(withTarget: libraryUndo) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreLibrary(summaries, from: now, to: then, action: action) }
        }
        undoManager?.setActionName(action)
    }

    /// Undo and redo of a rating or flag change.
    func restoreLibrary(_ summaries: [URL: LibrarySummary], from now: LibraryView, to then: LibraryView, action: String) {
        guard !closing else { return }
        let view = libraryView, items = Set(library.items.map(\.url))
        var befores: [URL: LibrarySummary] = [:], queued = false
        for (photo, summary) in summaries where items.contains(photo) {
            let before = library.summary(for: photo)
            var after = before
            after.rating = summary.rating; after.flag = summary.flag; after.words = summary.words
            guard after != before else { continue }
            befores[photo] = before
            if saveLibraryChange(from: before, to: after, photo: photo) == nil { queued = true }
            library.set(after, for: photo)
        }
        if queued { flushLibraryChanges() }
        if view == now, !cropping {
            if then.mode == .photo, let open = then.open, items.contains(open) {
                if open == sourceItem, !sourceDeleted { selection.select(open); mode = .photo } else { self.open(open) }
            } else if then.mode == .grid {
                if mode == .photo { showGrid() }
                if mode == .grid { selection = then.selection }
                selection.prune(to: Set(shownPhotos.map(\.url)))
            }
        } else {
            selection.prune(to: Set(shownPhotos.map(\.url)))
        }
        // Redo takes it back to where it is now, and changes them again.
        registerLibraryUndo(befores, from: libraryView, to: view, action: action)
    }

    /// Queues a rating or flag change to `photo`'s sidecar; why it can't, if
    /// it can't. The open photograph's goes to its variant; another's to its
    /// file's first variant, or a new one if it has no file.
    func saveLibraryChange(from before: LibrarySummary, to after: LibrarySummary, photo: URL) -> String? {
        guard sidecarsEnabled else { return "Not saved: Settings › Save ratings and edits is off" }
        guard let sidecars else { return "Not saved" }
        // Benchmarks keep ratings for the session without a note.
        guard sidecars.writes else { return nil }
        let rating = after.rating != before.rating ? after.rating : nil
        let flag: PhotoSidecar.Flag?? = after.flag != before.flag ? .some(after.flag) : nil
        let words = after.words, was = before.words
        let label: ColorLabel?? = words.label != was.label ? .some(words.label) : nil
        let keywords = words.keywords != was.keywords ? words.keywords : nil
        let title = words.title != was.title ? words.title : nil, caption = words.caption != was.caption ? words.caption : nil
        if photo == sourceItem {
            guard var context = photoSidecar, context.photo == source else { return "Not saved" }
            guard context.blocked == nil else { return "Not saved: its .qlick file can’t be changed" }
            guard PhotoLibrary.canWrite(beside: photo) else { return "Not saved: the folder is read-only" }
            sidecars.enqueue(SidecarPatch(variant: context.variant, primary: context.variantIsNew, rating: rating, flag: flag,
                                          label: label, keywords: keywords, title: title, caption: caption,
                                          defaultsVersion: context.defaultsVersion, app: Self.appVersion), for: context.photo)
            context.exists = context.written != nil || after.rating > 0 || after.flag != nil || !after.words.isEmpty
            photoSidecar = context
        } else {
            guard before.problem == nil else { return "Not saved: its .qlick file can’t be changed" }
            guard PhotoLibrary.canWrite(beside: photo.photoFile) else { return "Not saved: the folder is read-only" }
            // A duplicate's own variant; a photograph's first, or a new one if it has no file.
            sidecars.enqueue(SidecarPatch(variant: photo.variantID ?? SidecarRestore.newVariantID(), primary: photo.variantID == nil,
                                          rating: rating, flag: flag, label: label, keywords: keywords, title: title, caption: caption,
                                          defaultsVersion: SidecarDefaults.latest, app: Self.appVersion),
                             for: photo.photoFile)
        }
        return nil
    }

    /// Opens the photograph `offset` places on in the film strip, as it's
    /// filtered.
    func step(by offset: Int) {
        guard !cropping, let source = sourceItem else { return }
        let shown = shownPhotos
        guard let index = shown.firstIndex(where: { $0.url == source }), shown.indices.contains(index + offset) else { return }
        open(shown[index + offset].url)
    }
}
