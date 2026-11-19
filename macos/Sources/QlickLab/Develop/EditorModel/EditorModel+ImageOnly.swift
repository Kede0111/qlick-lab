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
    // MARK: Image Only and upside down

    /// F: Image Only on or off. From the grid it opens the current
    /// photograph in Image Only. Not while cropping, whose tools are in the
    /// inspector and the status line.
    func toggleImageOnly() {
        if imageOnly { return leaveImageOnly() }
        guard !cropping else { return }
        if mode == .grid {
            guard selection.current != nil else { return }
            editCurrent()
        }
        guard mode == .photo, source != nil else { return }
        imageOnly = true
    }
    func leaveImageOnly() { if imageOnly { imageOnly = false } }
    /// ⌥⌘F: in Image Only it ends it and shows the strip.
    func toggleFilmstrip() {
        if imageOnly { leaveImageOnly(); filmstripVisible = true } else { filmstripVisible.toggle() }
    }
    /// Holding T. Only the photograph view's canvas turns, not while cropping.
    func holdUpsideDown(_ held: Bool) {
        let turned = held && mode == .photo && source != nil && !cropping
        if turned != upsideDown { upsideDown = turned }
    }
    var canChangePresets: Bool { hasCatalog && !cropping && engine != nil }

    /// Lists the folder again, so files copied in by hand appear, and asks
    /// the engine about files it hasn't seen.
    func refreshPresets() async {
        do { presets = try await presetLibrary.list() } catch { presets = []; report(error) }
        presetStatus = presetStatus.filter { presets.contains($0.key) }
        presetTexts = presetTexts.filter { presets.contains($0.key) }
        presetWhiteBalances = presetWhiteBalances.filter { presets.contains($0.key) }
        previews.update(presets: presets)
        guard let engine else { return }
        checkingPresets += 1
        defer { checkingPresets -= 1; pumpPreviews() }
        for preset in presets where presetStatus[preset] == nil {
            do {
                let text = try Self.presetText(try await presetLibrary.read(preset))
                let (_, result) = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(text)])
                presetStatus[preset] = .valid(film: result["film"].string, paper: result["paper"].string,
                                              scan: result["params"]["io.scan_film"].bool)
                presetTexts[preset] = text
                presetWhiteBalances[preset] = result["params"]["io.raw_white_balance"]
            } catch {
                presetStatus[preset] = .invalid(error.localizedDescription)
            }
        }
    }

    /// The film, paper and Lab settings of a preset, as one undo step. The
    /// photograph's own settings stay: Image Size, rotation, crop, border,
    /// output encoding, the preview limit and the Post values.
    func applyPreset(_ preset: PresetFile) {
        guard canChangePresets, let engine else { return }
        Task {
            do {
                let text = try Self.presetText(try await presetLibrary.read(preset))
                // The engine keeps the photograph's settings from the params
                // it's given; ask again if they changed while it answered.
                for _ in 0..<3 {
                    let snapshot = state
                    let (_, result) = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(text),
                                                                "params": snapshot.params])
                    guard state == snapshot else { continue }
                    let (film, paper) = (result["film"].string, result["paper"].string)
                    guard films.contains(where: { $0.id == film }), papers.contains(where: { $0.id == paper }) else {
                        throw EngineError(message: "This version of Qlick Lab doesn’t have the preset’s film or paper.")
                    }
                    var next = state
                    next.film = film; next.paper = paper; next.params = result["params"]
                    if let develop = recipeDevelop(text) { next = develop.applied(to: next, photo: snapshot) }
                    apply(next, action: "Apply Preset “\(preset.name)”")
                    notePresetApplied(preset.url)
                    status = "Applied preset “\(preset.name)”"
                    return
                }
            } catch {
                report(error)
                await refreshPresets()
            }
        }
    }

    /// Saves the film, paper and Lab settings as a new preset, under `name`, or the name asked for first (the
    /// film's, to begin with). Cancel saves nothing.
    func newPreset(named name: String? = nil) {
        guard canChangePresets, let engine else { return }
        let snapshot = state, snapshotItem = sourceItem, exposureOffset = exposureOffset.wrappedValue
        let taken = Set(presets.map { PresetName.key($0.name) })
        let suggested = PresetName.unique(PresetName.from(fileName: filmName), taken: taken)
        // Qlick Lab: the Develop groups to save with it, chosen beside the name (remembered).
        let asking: (@escaping (String?, Set<DevelopGroup>) -> Void) -> Void = { [weak self] done in
            if let name { done(name, DevelopGroup.saved) } else { self?.askPresetName(suggested, groups: DevelopGroup.saved, done) }
        }
        asking { [weak self] name, groups in
            guard let self, let name else { return }
            DevelopGroup.saved = groups
            self.showPane(.presets)
            Task {
                do {
                    let (_, result) = try await engine.request(["command": EngineCommand.presetExport.json, "film": .string(snapshot.film),
                                                                "paper": .string(snapshot.paper), "params": snapshot.params])
                    var text = result["text"].string
                    if !groups.isEmpty { text = RecipeDevelop.taking(groups, from: snapshot, exposureOffset: exposureOffset).adding(to: text) }
                    let file = try await self.presetLibrary.add(Data(text.utf8), name: name)
                    // The photograph's settings are this preset's: it's the one ringed.
                    self.notePresetApplied(file.url, to: snapshotItem)
                    await self.refreshPresets()
                    self.status = "Saved the preset “\(file.name)”"
                } catch { self.report(error) }
            }
        }
    }

    /// Asks for a new preset's name over the window, the suggestion selected, and which Develop groups it also keeps
    /// (`groups` ticked); nil if it's cancelled. A name that can't be a file's is refused and asked for again.
    func askPresetName(_ suggested: String, groups: Set<DevelopGroup>, refused: String? = nil,
                               _ done: @escaping (String?, Set<DevelopGroup>) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save as a New Preset"
        alert.informativeText = refused ?? "The film, the paper and their settings, to use on other photographs."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: suggested)
        field.placeholderString = "Preset name"
        field.setAccessibilityLabel("Preset name")
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        // Qlick Lab: the Develop tab's settings it also keeps, none ticked to keep none.
        let heading = NSTextField(labelWithString: "Also save from Develop:")
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        heading.textColor = .secondaryLabelColor
        let boxes = DevelopGroup.allCases.map { group in
            let box = NSButton(checkboxWithTitle: group.title, target: nil, action: nil)
            box.state = groups.contains(group) ? .on : .off
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return box
        }
        let stack = NSStackView(views: [field, heading] + boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setCustomSpacing(12, after: field)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        alert.window.appearance = NSAppearance(named: .darkAqua)
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return done(nil, groups) }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            let chosen = Set(zip(DevelopGroup.allCases, boxes).filter { $0.1.state == .on }.map(\.0))
            if let problem = PresetName.problem(name) {
                // Asked again once this sheet is gone.
                DispatchQueue.main.async { self?.askPresetName(name.isEmpty ? suggested : name, groups: chosen, refused: problem, done) }
                return
            }
            done(name, chosen)
        }
        if let window = NSApp.windows.first(where: { $0 is EditorWindow }) {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else if NSClassFromString("XCTestCase") != nil {
            // No one to ask under tests: the suggestion.
            done(suggested, groups)
        } else {
            answer(alert.runModal())
        }
    }

    func importPresetsPanel() {
        guard canChangePresets else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.message = "Choose presets saved by Qlick Lab or by spektrafilm (its interface’s state files)."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            MainActor.assumeIsolated { self.importPresets(panel.urls) }
        }
    }

    /// Copies each file that the engine reads into the Presets folder, under
    /// its own name, and lists the ones that it refuses. They go to the end,
    /// or before the preset at `position` (a drop between rows).
    func importPresets(_ urls: [URL], at position: Int? = nil) {
        guard canChangePresets, let engine, !urls.isEmpty else { return }
        showPane(.presets)
        Task {
            var failures: [String] = [], added: [URL] = []
            for url in urls {
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try PresetLibrary.read(url) }.value
                    _ = try await engine.request(["command": EngineCommand.presetImport.json, "text": .string(try Self.presetText(data))])
                    added.append(try await presetLibrary.add(data, name: PresetName.from(fileName: url.deletingPathExtension().lastPathComponent)).url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let imported = added.count
            if let position, imported > 0, let listed = try? await presetLibrary.list() {
                let moved = listed.filter { added.contains($0.url) }
                var order = listed.filter { !added.contains($0.url) }
                let before = listed.prefix(position).filter { !added.contains($0.url) }.count
                order.insert(contentsOf: moved, at: min(before, order.count))
                do { try await presetLibrary.setOrder(order) } catch { report(error) }
            }
            await refreshPresets()
            if imported > 0 { status = imported == 1 ? "Imported 1 preset" : "Imported \(imported) presets" }
            if !failures.isEmpty {
                error = (imported == 0 ? "No presets were imported.\n\n" : "Some files weren’t imported.\n\n")
                    + failures.joined(separator: "\n\n")
            }
        }
    }

    /// Moves presets in the list, as dragged, and remembers the order.
    func movePresets(from source: IndexSet, to destination: Int) {
        var order = presets
        order.move(fromOffsets: source, toOffset: destination)
        guard order != presets else { return }
        presets = order
        Task {
            do { try await presetLibrary.setOrder(order) } catch { report(error) }
            await refreshPresets()
        }
    }

    /// Escape while naming: keeps the old name, or removes a preset New
    /// Preset just made.
    func cancelRename(_ preset: PresetFile) {
        renamingPreset = nil
        guard preset.url == unnamedPreset else { return }
        unnamedPreset = nil
        forgetApplied(preset.url)
        Task {
            do { try await presetLibrary.delete(preset) } catch { report(error) }
            await refreshPresets()
        }
    }

    func renamePreset(_ preset: PresetFile, to name: String) {
        renamingPreset = nil
        if preset.url == unnamedPreset { unnamedPreset = nil }
        guard name != preset.name else { return }
        Task {
            do {
                let renamed = try await presetLibrary.rename(preset, to: name)
                appliedPresets = appliedPresets.mapValues { $0 == preset.url ? renamed.url : $0 }
                // Same file, same thumbnail: no blank tile while it's renamed.
                previews.moveTile(preset: preset.url, to: renamed.url)
            } catch { report(error) }
            await refreshPresets()
        }
    }

    /// Notes `preset` as the one applied last to `item` (the photograph on
    /// screen when nil).
    func notePresetApplied(_ preset: URL, to item: URL? = nil) {
        guard let item = item ?? sourceItem else { return }
        appliedPresets[item] = preset
    }

    func forgetApplied(_ preset: URL) {
        appliedPresets = appliedPresets.filter { $0.value != preset }
    }

    func deletePreset(_ preset: PresetFile) {
        Task {
            let answer = await ask(AppAlert(
                title: "Delete the preset “\(preset.name)”?",
                detail: "This can’t be undone. Photographs edited with it keep their settings.",
                buttons: [.init(title: "Delete", role: .destructive), .init(title: "Cancel", role: .cancel)]))
            guard answer.button == 0 else { return }
            do {
                try await presetLibrary.delete(preset)
                forgetApplied(preset.url)
            } catch { report(error) }
            await refreshPresets()
        }
    }

    /// Writes a copy wherever the user picks, byte for byte.
    func exportPresetPanel(_ preset: PresetFile) {
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        panel.message = "spektrafilm’s format: opens in Qlick Lab and in spektrafilm."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            MainActor.assumeIsolated {
                Task {
                    do { try await self.presetLibrary.read(preset).write(to: url, options: .atomic) }
                    catch { self.report(error); await self.refreshPresets() }
                }
            }
        }
    }

    func showPresetsFolder() {
        let folder = presetLibrary.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { report(error) }
    }

    nonisolated static func presetText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw EngineError(message: "The file isn’t text.") }
        return text
    }
}
