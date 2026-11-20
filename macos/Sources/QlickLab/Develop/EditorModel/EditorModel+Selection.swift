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
    // MARK: Selection and grid

    /// The photographs the strip and grid show: those the filter lets
    /// through, and the current one.
    /// Qlick Lab: in the lab's order (`LibrarySort`).
    var shownPhotos: [PhotoFile] { lab.stacked(lab.sorted(library.shown(current: selection.current))) }

    /// A click on a photograph in the strip or the grid. ⌘ adds or removes
    /// it and ⇧ selects a range, changing only the selection; a plain click
    /// makes it current, which in the edit view opens it. ⌘ on the grid's
    /// current photograph hands current on to the next one selected; in the
    /// edit view that would open it, so there it stays.
    func click(_ photo: URL, command: Bool = false, shift: Bool = false) {
        guard !cropping else { return }
        if command { selection.toggle(photo, in: mode == .grid ? shownPhotos.map(\.url) : nil) }
        else if shift { selection.extend(to: photo, in: shownPhotos.map(\.url)) }
        else if mode == .photo, photo != sourceItem { open(photo) }
        else { selection.select(photo) }
    }

    /// ← and →. In the edit view they open the next photograph; in the grid
    /// the current photograph moves without developing. With ⇧ the
    /// selection grows or shrinks instead and the current photograph stays.
    func move(by offset: Int, extending: Bool) {
        guard !cropping else { return }
        let order = shownPhotos.map(\.url)
        if extending { return selection.extend(by: offset, in: order) }
        guard mode == .grid else { return step(by: offset) }
        guard let current = selection.current, let index = order.firstIndex(of: current) else {
            if let first = order.first { selection.select(first) }
            return
        }
        guard order.indices.contains(index + offset) else { return }
        selection.select(order[index + offset])
    }

    /// ↑ and ↓ in the grid: the photograph a row up or down, the one
    /// nearest across (`SheetLayout.vertical`). With ⇧ the selection grows
    /// or shrinks to it.
    func moveRow(by rows: Int, extending: Bool) {
        guard !cropping, mode == .grid else { return }
        let order = shownPhotos.map(\.url)
        // ⇧ moves the selection's moving end, as ⇧← and ⇧→ do.
        let from = extending ? selection.lead ?? selection.current : selection.current
        guard let from, let index = order.firstIndex(of: from) else {
            if let first = order.first, !extending { selection.select(first) }
            return
        }
        guard let layout = gridLayout, layout.frames.count == order.count,
              let to = layout.vertical(from: index, by: rows) else { return }
        if extending { selection.extend(by: to - index, in: order) } else { selection.select(order[to]) }
    }

    /// ⌘A: every photograph shown.
    func selectAll() { selection.selectAll(shownPhotos.map(\.url)) }
    /// ⌥⌘A: all but the current photograph.
    func deselectAll() { selection.deselectAll() }
    /// The grid's rubber band: `photos` inside it, added to `base`.
    func band(_ photos: [URL], adding base: Set<URL>) { selection.band(photos, adding: base) }

    func showGrid() {
        guard let source = sourceItem, !cropping, mode != .grid else { return }
        holdOriginal(false)
        holdUpsideDown(false)
        // The sheet grows out of the strip, and folds back into the view as set.
        leaveImageOnly()
        endTray(keep: true)
        // The grid shows the open photograph as edited.
        flushSidecar()
        saveOpenThumbnail()
        saveOpenRender()
        if selection.current == nil { selection.select(source) }
        mode = .grid
        filmCacheRelease.release(.editorClosed)
    }

    /// Back to the edit view, on the grid's current photograph. With none,
    /// as when a rating left nothing the filter passes, there's nothing to edit.
    func editCurrent() {
        guard mode == .grid, let current = selection.current else { return }
        if current != sourceItem || sourceDeleted { open(current) } else { mode = .photo }
    }

    func changeGridCellSize(larger: Bool) { gridCellSize += larger ? 40 : -40 }

    func filterChanged() {
        guard !library.filtering else { return }
        // A grid left empty by a rating finds the open photograph again
        // once a filter shows it.
        if mode == .grid, selection.current == nil, let open = sourceItem, !sourceDeleted,
           library.shown(current: nil).contains(where: { $0.url == open }) { selection.select(open) }
        selection.prune(to: Set(library.shown(current: selection.current).map(\.url)))
    }
}
