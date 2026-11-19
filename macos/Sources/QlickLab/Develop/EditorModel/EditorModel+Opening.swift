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
    // MARK: Opening

    nonisolated static let rawExtensions = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "ptx", "srw", "x3f", "iiq", "3fr", "ari", "bay", "crw", "dcr", "drf", "erf", "fff", "k25", "kdc", "mef", "mos", "mrw", "rwl"]

    func openPanel() {
        let panel = Self.makeOpenPanel()
        if let source {
            // A file URL reveals and selects the file; a parent URL only opens its folder.
            panel.directoryURL = source
        }
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    /// ⌘O's panel: a photograph, or a folder of them (§6.1).
    static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.allowedContentTypes = [.png, .tiff, .jpeg, .rawImage] + Self.rawExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        return panel
    }

    /// A folder's first photograph in name order, or nil if it has none
    /// (or isn't a folder Negs can read).
    nonisolated static func firstPhotograph(in folder: URL) -> URL? {
        (try? PhotoFolder.images(in: folder))?.first
    }

    /// The folder the library lists.
    var libraryFolder: URL? { libraryRoot ?? source?.deletingLastPathComponent() }

    func open(_ url: URL) {
        EngineTrace.log("open \(url.lastPathComponent)")
        // A photograph of the library listed keeps it; anything else lets it go.
        if libraryRoot != nil, !library.items.contains(where: { $0.url == url || $0.url.photoFile == url.photoFile }) { libraryRoot = nil }
        // A folder opens on its first photograph, in the grid.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let first = Self.firstPhotograph(in: url) else {
                error = "“\(url.lastPathComponent)” has no photographs Qlick Lab can open."
                return
            }
            open(first)
            if source == first { showGrid() }
            return
        }
        explicitOpenRequested = true
        mode = .photo
        // During launch it undoes a restore at launch; later it supersedes it.
        if launching { discardLaunchRestore() } else { launchRestore = nil }
        open(url, restoring: nil)
    }

    /// Opens a library item: a photograph, or a duplicate of one.
    func open(_ item: URL, restoring session: EditorSession?) {
        let item = session?.variant.map { item.photoFile.variant($0) } ?? item
        let url = item.photoFile
        guard !closing, url.isFileURL else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            recentFiles.removeAll { $0 == url }; saveRecents()
            error = "“\(url.lastPathComponent)” can’t be opened. It may have been moved or deleted."
            return
        }
        // A stock being tried is kept, as by a click outside the tray.
        endTray(keep: true)
        trialImage = nil
        // The previous photograph's last edits go to its sidecar first, and
        // the preview on screen becomes its edited thumbnail.
        flushSidecar()
        saveOpenThumbnail()
        saveOpenRender()
        // Paste from Previous: the last photograph left with edits.
        if photoSidecar?.written != nil, photoSidecar?.photo == source { previousEdits = Self.userEdits(state) }
        let previous = state
        cancelBrightnessMatch(); brightnessMatchFailure = nil
        sourceDeleted = false
        source = url; sourceVariant = item.variantID; image = nil; placeholder = nil; standIn = nil; previewCurrent = false; developFailure = nil; screenFrameScale = nil; detail = nil
        // Leaving the grid opens its current photograph and keeps the selection.
        if selection.current != item { selection.select(item) }
        sourceSize = .zero; workingSize = .zero; previewScale = 1
        showingCachedPreview = false
        updateHistogram()
        interactionStart = nil; cropSession = nil
        original = nil; originalCache = nil; originalLoad?.cancel(); originalLoad = nil; holdingOriginal = false
        originalDetail = nil; originalDetailLoad?.cancel(); originalDetailLoad = nil
        sourceGeneration += 1
        imageIsMask = false
        let generation = sourceGeneration
        customFilmFormat = false
        photoFacts = nil
        Task.detached(priority: .utility) { [weak self] in
            let facts = PhotoFacts.read(url)
            await self?.adopt(facts, generation: generation)
        }
        // A schema 2 session restores its edits as before; otherwise the
        // photograph's sidecar has them, read at launch with the session.
        adoptEdits(for: url, restore: session?.sidecar ?? readSidecar(url, variant: item.variantID), legacy: session?.state, previous: previous,
                   match: session?.match)
        if let session { inspectorVisible = session.inspectorVisible }
        isRaw = Self.rawExtensions.contains(url.pathExtension.lowercased())
        // Changes to several photographs (Paste Edits, Duplicate) stay undoable.
        undoManager?.removeAllActions(withTarget: self)
        zoom(fit: session?.fitImage ?? true)
        recentFiles.removeAll { $0 == url }; recentFiles.insert(url, at: 0)
        recentFiles = Array(recentFiles.prefix(10)); saveRecents()
        // A restore at launch may still be undone; `start` notes it.
        if !restoringAtLaunch { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        status = ready ? "" : "Starting…"
        // Try the exact developed frame before decoding the raw placeholder,
        // so a cache hit never flashes the unprocessed photograph.
        let snapshot = renderState, paths = engine?.paths, cache = previewCache
        inputColour = .null; lensCorrectionSupported = false
        // Read off the main actor at once, with its histogram. At launch the
        // main actor stays busy building the window, which takes the frame
        // through `finishLaunching` before it first appears.
        let crop = state.crop, rotation = Int(state.params["io.rotate_cw"].double)
        let cachedFrame = session != nil ? paths.map { paths in
            LaunchFrame {
                guard let frame = await cache.load(source: url, state: snapshot, paths: paths) else { return nil }
                return LaunchFrame.Loaded(frame: frame, scopes: ImageScopes.of(frame.surface, crop: crop, rotation: rotation),
                                         scopesCrop: crop, scopesRotation: rotation)
            }
        } : nil
        launchFrame = restoringAtLaunch ? cachedFrame.map { ($0, generation, snapshot.rendered) } : nil
        // The developed thumbnail stands in until then, if it's been made.
        // Read now (~2 ms), as the window's next frame comes only after
        // SwiftUI has updated it for this photograph (~180 ms on an M1 Pro):
        // that frame shows it rather than an empty canvas. A restored
        // session tries its saved frame first, off the main actor.
        let standIn = developedThumbnail(of: item), kept = keptRender(of: item)
        if session == nil, let image = standIn?() { self.standIn = image }
        Task { [weak self] in
            if let cachedFrame, let cached = await cachedFrame.value {
                guard let self else { return }
                if self.showCached(cached, generation: generation, rendered: snapshot.rendered) { return }
            }
            if session != nil, let standIn, let image = await Task.detached(priority: .userInitiated, operation: standIn).value {
                self?.showStandIn(image, generation: generation)
            }
            // Its last develop, if it was kept: sharper, and laid out as the
            // develop will be, so the camera's preview isn't needed.
            if let kept, let (image, size) = await Task.detached(priority: .userInitiated, operation: kept).value,
               self?.showKept(image, size: size, generation: generation) == true { return }
            // Still read for the photograph's size, which lays out the canvas.
            let thumbnail = await Task.detached(priority: .userInitiated) { Self.thumbnail(url) }.value
            if let (thumbnail, size) = thumbnail { self?.showPlaceholder(thumbnail, size: size, generation: generation) }
        }
        changed(invalidateCache: session == nil)
    }
    /// Ends launch, before the window is shown: a restore at launch is no
    /// longer undone by an open, and its saved frame is shown now if it's
    /// read within `timeout`, so the window's first frame has the
    /// photograph; otherwise it appears when read.
    func finishLaunching(waitingUpTo timeout: TimeInterval) {
        guard launching else { return }
        launching = false
        guard let (frame, generation, rendered) = launchFrame else { return }
        launchFrame = nil
        if let loaded = frame.wait(timeout: timeout) { _ = showCached(loaded, generation: generation, rendered: rendered) }
    }

    /// True if the saved frame is shown, or it no longer applies because
    /// another photograph or image is shown; false if the edits changed.
    func showCached(_ cached: LaunchFrame.Loaded, generation: Int, rendered: EditState) -> Bool {
        guard generation == sourceGeneration, image == nil, !closing else { return true }
        guard renderState.rendered == rendered else { return false }
        let frame = cached.frame
        image = frame.surface; imageSize = frame.photoSize; isRaw = frame.raw
        sourceSize = frame.sourceSize; workingSize = frame.workingSize
        previewScale = frame.workingSize.width > 0 ? Double(frame.surface.width) / frame.workingSize.width : 1
        showingCachedPreview = true; placeholder = nil; standIn = nil; hideActivity()
        // Counted with the frame for the crop it was read with.
        if crop == cached.scopesCrop, imageRotation == cached.scopesRotation {
            histogramRequest += 1; histogram = cached.scopes.histogram; waveform = cached.scopes.waveform
        } else { updateHistogram() }
        updateFilmStrip()
        return true
    }

    /// Reads `item`'s developed thumbnail, if one was made for the edits it
    /// opens with.
    func developedThumbnail(of item: URL) -> (@Sendable () -> CGImage?)? {
        guard let edited = editedThumbnail(for: item), let file = library.items.first(where: { $0.url == item }),
              let key = edited.store.key(for: file, look: edited.look) else { return nil }
        let store = edited.store, look = edited.look
        return {
            store.image(key, maxPixels: Int(EditedThumbnailStore.longSide))
                ?? store.previousKey(for: file, look: look).flatMap { store.image($0, maxPixels: Int(EditedThumbnailStore.longSide)) }
        }
    }

    /// Reads `item`'s last develop, if one was kept for the edits it opens with.
    func keptRender(of item: URL) -> (@Sendable () -> (CGImage, CGSize)?)? {
        guard let look = thumbnailLook(for: item), let file = library.items.first(where: { $0.url == item }),
              let key = renderArchive.key(for: file, look: look) else { return nil }
        let archive = renderArchive
        return { (archive.render(key) ?? archive.previousKey(for: file, look: look).flatMap { archive.render($0) }).map { ($0.image, $0.photoSize) } }
    }

    /// Qlick Lab: the canvas shows the photograph's kept develop while its develop runs.
    var showsKeptRender: Bool { image == nil && placeholder != nil && placeholderFor.map { $0.generation == sourceGeneration && $0.kept } == true }

    /// True if it's shown, or no longer needed.
    func showKept(_ render: CGImage, size: CGSize, generation: Int) -> Bool {
        guard generation == sourceGeneration, image == nil else { return true }
        placeholderSize = size; placeholder = render; standIn = nil; placeholderFor = (generation, true)
        updateFilmStrip()
        return true
    }

    func adopt(_ facts: PhotoFacts?, generation: Int) {
        if generation == sourceGeneration { photoFacts = facts }
    }

    func showStandIn(_ thumbnail: CGImage, generation: Int) {
        guard generation == sourceGeneration, image == nil else { return }
        standIn = thumbnail
    }

    func showPlaceholder(_ thumbnail: CGImage, size: CGSize, generation: Int) {
        guard generation == sourceGeneration, image == nil else { return }
        placeholderSize = size; placeholder = thumbnail; placeholderFor = (generation, false)
        updateFilmStrip()
    }
    func saveRecents() { UserDefaults.standard.set(recentFiles.map(\.path), forKey: "recentFiles") }

    /// A display-sized decode through ImageIO, with EXIF orientation applied
    /// like the engine's loader. RAW files use their embedded preview.
    nonisolated static func thumbnail(_ url: URL, maxPixels: Int = 2048) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let raw = rawExtensions.contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            raw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Lay the thumbnail out at the photograph's full size so the canvas
        // doesn't jump when the developed render arrives.
        var size = CGSize(width: image.width, height: image.height)
        if !raw, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        return (image, size)
    }
}
