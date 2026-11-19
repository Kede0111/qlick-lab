// Qlick Lab — GPL-3.0-only.
import AppKit

/// A development aid: drives the lab from a named pipe, so its rooms and gestures can be exercised and captured
/// without the mouse, the keyboard or the front of the screen (`scripts/drive.sh`). Off unless the
/// `QLICK_AUTOMATION` environment variable names the pipe; nothing here runs in normal use.
///
/// One command a line, e.g. `room contactSheet`, `click 4`, `drag 6 11 alt`, `sheet style=compact`, `winid /tmp/id`.
@MainActor final class LabAutomation {
    static var shared: LabAutomation?
    static var pipe: String? { ProcessInfo.processInfo.environment["QLICK_AUTOMATION"] }
    /// The window is kept off screen and never comes to the front.
    static var offscreen: Bool { ProcessInfo.processInfo.environment["QLICK_OFFSCREEN"] == "1" }

    private let model: EditorModel
    private weak var window: NSWindow?
    private var source: DispatchSourceRead?
    private var pending = Data()

    static func start(model: EditorModel, window: NSWindow?) {
        guard let pipe, shared == nil else { return }
        let automation = LabAutomation(model: model, window: window)
        guard automation.listen(pipe) else { return }
        shared = automation
    }

    private init(model: EditorModel, window: NSWindow?) {
        self.model = model
        self.window = window
    }

    private func listen(_ path: String) -> Bool {
        if !FileManager.default.fileExists(atPath: path) { mkfifo(path, 0o600) }
        let descriptor = open(path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            MainActor.assumeIsolated { self?.received(Data(buffer[0..<count])) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    private func received(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { run(line) }
        }
    }

    private var lab: LabState { model.lab }
    private var sheet: ContactSheetView? { lab.sheetView }

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0], rest = parts.count > 1 ? parts[1] : ""
        let words = rest.split(separator: " ").map(String.init)
        func modifiers(_ words: [String]) -> NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if words.contains("alt") { flags.insert(.option) }
            if words.contains("cmd") { flags.insert(.command) }
            if words.contains("shift") { flags.insert(.shift) }
            return flags
        }
        switch command {
        case "room": if let room = Workspace(rawValue: rest) { lab.show(room) }
        case "back": lab.goBack()
        case "forward": lab.goForward()
        // import <what> …: the import room without the mouse.
        case "import":
            let session = lab.importer, argument = words.dropFirst().joined(separator: " ")
            switch words.first ?? "" {
            case "source": session.open(ImportVolumes.folder(URL(fileURLWithPath: argument, isDirectory: true)))
            case "dest": session.options.destination = URL(fileURLWithPath: argument, isDirectory: true)
            case "second": session.options.secondCopy = argument.isEmpty ? nil : URL(fileURLWithPath: argument, isDirectory: true)
            case "mode": if let mode = ImportMode(rawValue: argument) { session.options.mode = mode }
            case "folders": session.options.folders = argument
            case "rename": session.options.rename = argument
            case "project": session.options.project = argument
            case "keywords": session.options.keywords = argument
            case "card": if let card = session.cards.first(where: { argument.isEmpty || $0.name == argument }) { session.open(card) }
            case "skipdup": session.options.skipDuplicates = argument != "0"
            case "balance": session.options.balanceEach = argument != "0"
            case "verify": session.options.verify = argument != "0"
            case "eject": session.options.ejectAfter = argument != "0"
            case "view": if let view = ImportView(rawValue: argument) { session.view = view }
            case "filter": if let filter = ImportFilter(rawValue: argument) { session.filter = filter }
            case "style": if let style = ImportProgressStyle(rawValue: argument) { session.progressStyle = style }
            case "click": if let index = Int(argument), session.shown.indices.contains(index) { session.click(session.shown[index].id, command: words.contains("cmd"), shift: words.contains("shift")) }
            case "select": if words.count == 3, let from = Int(words[1]), let to = Int(words[2]), session.shown.indices.contains(from), session.shown.indices.contains(to) {
                session.click(session.shown[from].id); session.click(session.shown[to].id, shift: true)
            }
            case "pick": session.toggle(flag: "pick")
            case "reject": session.toggle(flag: "reject")
            case "rate": session.rate(Int(argument) ?? 0)
            case "rotate": session.rotate(by: Int(argument) ?? 1)
            case "toggle": session.toggleIncluded()
            case "recipe": session.assign(recipe: argument.isEmpty ? nil : argument, to: session.selected.isEmpty && session.current == nil ? session.includedFrames.map(\.id) : nil)
            case "recipeall": session.assign(recipe: argument.isEmpty ? nil : argument, to: session.includedFrames.map(\.id))
            case "start": session.start()
            case "stop": session.stop()
            case "pause": session.togglePause()
            case "resume": session.resume()
            case "open": session.openImported()
            case "done": session.dismissRun()
            case "state":
                // import state <file>: what the room holds, for a test to read.
                let run = session.run
                let lines = ["source=\(session.source?.name ?? "-")", "frames=\(session.frames.count)", "shown=\(session.shown.count)", "dates=\(session.datesReady)",
                             "included=\(session.includedCount)", "known=\(session.known.count)", "plan=\(session.plan.toCopy.count)", "bytes=\(session.plan.bytes)",
                             "folders=\(session.plan.folders.map { "\($0.path):\($0.count)" }.joined(separator: ","))", "blocker=\(session.blocker ?? "-")",
                             "run=\(run.map { "\($0.done)/\($0.total) failed=\($0.failed) finished=\($0.finished) stopped=\($0.stopped)" } ?? "-")",
                             "figures=\(run?.figures ?? "-")", "notes=\(run?.notes.joined(separator: " | ") ?? "-")", "unfinished=\(session.unfinished?.remaining ?? 0)"]
                try? (lines.joined(separator: "\n") + "\n").write(toFile: argument, atomically: true, encoding: .utf8)
            default: break
            }
        case "open": model.open(URL(fileURLWithPath: rest))
        case "roll": lab.open(folder: URL(fileURLWithPath: rest, isDirectory: true))
        case "project":
            // project <name>|<folder>|<folder>…
            let fields = rest.split(separator: "|").map(String.init)
            guard let name = fields.first else { break }
            let project = lab.projects.projects.first { $0.name == name } ?? lab.projects.create(named: name)
            lab.add(fields.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }, to: project.id)
        case "removeproject": if let project = lab.projects.projects.first(where: { $0.name == rest }) { lab.removeProject(project) }
        case "modelanswer": model.answerAlert(Int(rest) ?? 0)
        case "wholeproject": if let project = lab.projects.projects.first(where: { $0.name == rest }) { lab.openWhole(project) }
        case "catalog":
            // catalog new <path> | open <path> | saveas <path>
            guard words.count == 2 else { break }
            let url = URL(fileURLWithPath: words[1], isDirectory: true)
            switch words[0] { case "saveas": lab.saveCatalog(as: url); default: lab.openCatalog(url) }
        case "canvasinfo": try? model.canvasScale.debugDescription.write(toFile: rest, atomically: true, encoding: .utf8)
        case "export":
            // export <path> [sharpen] [nogps]: Reference export of the open photograph.
            guard let path = words.first else { break }
            var save = SaveSettings(bitDepth: SaveSettings.bitDepth(for: path.hasSuffix(".heic") ? .heif : .jpeg), colorSpace: 1, jpegQuality: 90)
            if words.contains("sharpen") { save.sharpening = .screen }
            if words.contains("nogps") { save.metadata = .noLocation }
            Task {
                await model.export(to: URL(fileURLWithPath: path), engine: .reference, size: ExportSize(edge: .long, pixels: 3000), save: save)
                self.note("exported \(path): \(model.status) \(model.error ?? "")")
            }
        case "rollinfo":
            // rollinfo <film>|<camera>|<notes>
            let fields = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if let current = lab.current {
                lab.projects.updateRoll(current.roll.id, in: current.project.id) {
                    $0.film = fields.first ?? ""; $0.camera = fields.count > 1 ? fields[1] : ""; $0.notes = fields.count > 2 ? fields[2] : ""
                }
            }
        case "click":
            guard let index = words.first.flatMap(Int.init), let sheet, let point = sheet.centre(of: index) else { break }
            sheet.press(at: point, modifiers: modifiers(words), clicks: words.contains("double") ? 2 : 1)
            sheet.release()
        case "drag":
            guard words.count >= 2, let from = Int(words[0]), let to = Int(words[1]), let sheet,
                  let start = sheet.centre(of: from), let end = sheet.centre(of: to) else { break }
            sheet.press(at: start, modifiers: modifiers(words))
            for step in 1...12 {
                let t = CGFloat(step) / 12
                sheet.drag(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            sheet.release()
        case "hover":
            // hover <index> [u v]: the pointer over a frame, at a place in it (0…1).
            guard let index = words.first.flatMap(Int.init), let sheet, let centre = sheet.centre(of: index) else { break }
            let u = words.count > 2 ? Double(words[1]) ?? 0.5 : 0.5, v = words.count > 2 ? Double(words[2]) ?? 0.5 : 0.5
            let frame = sheet.layout.frame
            sheet.hover(at: CGPoint(x: centre.x + (u - 0.5) * frame.width * 0.9, y: centre.y + (v - 0.5) * frame.height * 0.9))
        case "default": if words.count >= 2 { UserDefaults.standard.set(words.dropFirst().joined(separator: " "), forKey: words[0]) }
        case "action": if let action = SheetAction(rawValue: rest) { sheet?.perform(action) }
        // Qlick Lab: the background work: stop it all or one piece, build thumbnails for the selection or all.
        case "stopall": BackgroundWork.stopAll(model)
        case "workpanel": lab.workPanelAsked += 1
        case "stopwork": BackgroundWork.tasks(model).first { $0.kind.rawValue == rest }?.stop?()
        case "buildthumbnails": model.buildThumbnails(rest == "all" ? model.library.items.map(\.url) : model.ratingTargets)
        case "rate": if let stars = Int(rest) { model.setRating(stars) }
        case "flag": model.setFlag(rest == "pick" ? .pick : rest == "reject" ? .reject : nil)
        case "undo": window?.undoManager?.undo()
        case "redo": window?.undoManager?.redo()
        case "filter":
            switch rest { case "picks": lab.markFilter = .picks; case "rejects": lab.markFilter = .rejects; case "unmarked": lab.markFilter = .unmarked; default: lab.markFilter = .all }
        case "sheet":
            for word in words {
                let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "style": if let style = SheetOptions.Style(rawValue: pair[1]) { lab.sheet.style = style }
                case "width": if let width = Double(pair[1]) { lab.sheet.frameWidth = width }
                case "tool": if let tool = SheetOptions.Tool(rawValue: pair[1]) { lab.sheet.tool = tool }
                case "mark": if let mark = SheetOptions.Mark(rawValue: pair[1]) { lab.sheet.pencilMark = mark }
                case "film": lab.sheet.showFilm = pair[1] == "1"
                case "light": lab.sheet.lightTable = pair[1] == "1"
                case "names": lab.sheet.fileNames = SheetOptions.FileNames(rawValue: pair[1]) ?? (pair[1] == "1" ? .edge : .off)
                case "info": lab.sheet.showInfo = pair[1] == "1"
                case "sideways": lab.sheet.sidewaysVerticals = pair[1] == "1"
                default: break
                }
            }
        case "scroll": if let y = Double(rest), let sheet { sheet.scroll(CGPoint(x: 0, y: y)) }
        case "sheetbench": try? (sheet?.benchmark() ?? "no sheet").write(toFile: rest, atomically: true, encoding: .utf8)
        case "loupe": lab.loupe = rest == "off" ? nil : model.selection.current
        case "compare":
            if rest.isEmpty || rest == "selection" { lab.compareSelection() }
            else if let kind = CompareSetup.Kind(rawValue: rest) { lab.show(.compare); lab.compareModel.setKind(kind) }
        case "comparefilms":
            lab.compare.films = words
            lab.show(.compare); lab.compareModel.setKind(.films)
        case "zoom":
            if rest == "fit" { lab.compareModel.canvas?.zoomToFit() } else { lab.compareModel.canvas?.zoomToActual() }
        case "split": if let value = Double(rest) { lab.compareModel.split = value; lab.compareModel.push() }
        case "film": model.chooseFilm(rest)
        // Develop's information: the panel, the caption's choice, and its right-click menu written out or used.
        case "crop": if rest == "done" { model.endCrop(apply: true) } else if rest == "cancel" { model.endCrop(apply: false) } else { model.beginCrop() }
        case "straighten":
            // straighten auto | straighten <degrees> | straighten note <file>
            if rest == "auto" { model.autoStraighten() }
            else if words.first == "note", words.count == 2 { try? "\(model.cropSession?.angle ?? .nan) \(model.cropSession?.levelNote ?? "")".write(toFile: words[1], atomically: true, encoding: .utf8) }
            else if let degrees = Double(rest), let session = model.cropSession { session.beginStraightening(); session.straighten(to: degrees); session.endStraightening() }
        case "settings": if !rest.isEmpty { UserDefaults.standard.set(rest, forKey: "settingsTab") }; lab.openSettings()
        case "info": lab.infoVisible = rest != "off"
        case "caption":
            if rest == "off" { lab.caption.visible = false }
            else if rest == "usual" { lab.caption = CaptionOptions() }
            else { lab.caption = CaptionOptions(visible: true, fields: Set(rest.split(separator: ",").compactMap { CaptionField(rawValue: String($0)) })) }
        case "developmenu":
            func lines(_ menu: NSMenu, _ indent: String) -> [String] {
                menu.update()
                return menu.items.flatMap { item -> [String] in
                    if item.isSeparatorItem { return [indent + "—"] }
                    let line = indent + (item.state == .on ? "✓ " : "") + item.title + (item.isEnabled ? "" : "  (off)")
                    return [line] + (item.submenu.map { lines($0, indent + "    ") } ?? [])
                }
            }
            try? (lab.developCommands.menu(at: nil).map { lines($0, "").joined(separator: "\n") } ?? "no menu").write(toFile: rest, atomically: true, encoding: .utf8)
        case "developmenu-do":
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items { if item.title == rest, item.action != nil { return item }; if let hit = item.submenu.flatMap(find) { return hit } }
                return nil
            }
            if let item = lab.developCommands.menu(at: nil).flatMap(find), item.isEnabled, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        case "set":
            // set <path> <number>
            if words.count == 2, let value = Double(words[1]) { model.set(words[0], .number(value)) }
        // shiftdrag <dx>: Shift-drag on the photograph from its middle, dx points to the right (left if negative).
        case "shiftdrag":
            guard let dx = Double(rest), let scroll = model.canvasScale.view, let photo = scroll.documentView, let window = scroll.window else { break }
            let visible = scroll.contentView.bounds
            let start = photo.convert(CGPoint(x: visible.midX, y: visible.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: start.y), modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = event(.leftMouseDown, start.x) { photo.mouseDown(with: down) }
            for step in 1...10 { if let drag = event(.leftMouseDragged, start.x + dx * Double(step) / 10) { photo.mouseDragged(with: drag) } }
            if let up = event(.leftMouseUp, start.x + dx) { photo.mouseUp(with: up) }
        // cursorimage <file.png>: the eyedropper pointer's picture.
        case "cursorimage":
            if let tiff = PhotographView.eyedropper.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: rest)) }
        // setjson <path> <json>: any value, an array or null among them.
        case "setjson":
            if words.count >= 2, let data = words.dropFirst().joined(separator: " ").data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) { model.set(words[0], value) }
        case "wb":
            // wb asshot-as-custom | auto: the panel's own arithmetic.
            guard let source = model.source else { break }
            // The engine's own As Shot and Auto, once it prepared the balance.
            if let known = rest == "auto" ? lab.asShot.autos[source] : lab.asShot.values[source] {
                note("wb \(rest) (engine): \(known)")
                model.setParams([("io.raw_white_balance.mode", .string("custom")), ("io.raw_white_balance.temperature", .number(known.temperature)),
                                 ("io.raw_white_balance.tint", .number(known.tint))])
                break
            }
            Task {
                let pair = await Task.detached { () -> (temperature: Double, tint: Double)? in
                    guard let asShot = WhiteBalanceMath.asShot(of: source) else { return nil }
                    return rest == "auto" ? WhiteBalanceMath.auto(of: source, asShot: asShot) : asShot
                }.value
                self.note("wb \(rest): \(String(describing: pair))")
                if let pair {
                    model.setParams([("io.raw_white_balance.mode", .string("custom")), ("io.raw_white_balance.temperature", .number(pair.temperature)),
                                     ("io.raw_white_balance.tint", .number(pair.tint))])
                }
            }
        case "setstr": if words.count == 2 { model.set(words[0], .string(words[1])) }
        case "setbool": if words.count == 2 { model.set(words[0], .bool(words[1] == "true")) }
        case "drag-set":
            // drag-set <path> <from> <to>: a slider dragged over a second, then let go.
            guard words.count == 3, let from = Double(words[1]), let to = Double(words[2]) else { break }
            model.beginInteraction()
            Task {
                for step in 0...20 {
                    model.set(words[0], .number(from + (to - from) * Double(step) / 20))
                    try? await Task.sleep(for: .milliseconds(50))
                }
                model.endInteraction()
            }
        case "drag-wb":
            // drag-wb <from K> <to K>: the Temperature slider dragged over a second, as the panel sets it, then let go.
            guard words.count == 2, let from = Double(words[0]), let to = Double(words[1]) else { break }
            model.beginInteraction()
            Task {
                for step in 0...20 {
                    model.setParams([("io.raw_white_balance.mode", .string("custom")),
                                     ("io.raw_white_balance.temperature", .number(from + (to - from) * Double(step) / 20)),
                                     ("io.raw_white_balance.tint", .number(1))])
                    try? await Task.sleep(for: .milliseconds(50))
                }
                model.endInteraction()
            }
        case "pane": model.inspectorPane = rest == "presets" ? .presets : .adjustments
        case "applypreset": if let preset = model.presets.first(where: { $0.name == rest }) { model.applyPreset(preset) }
        // applyselected <name>: the preset on every selected frame, as the right-click menu does.
        case "applyselected": if let preset = model.presets.first(where: { $0.name == rest }) { model.labApply(preset, to: model.ratingTargets) }
        case "applyauto": if let preset = model.presets.first(where: { $0.name == rest }) { model.labApply(preset, to: model.ratingTargets, adapting: true) }
        case "newpreset": model.newPreset(named: rest.isEmpty ? nil : rest)
        // sectionsave grain|halation <name>: the open photograph's grain or halation as a preset of the user's.
        // sectionapply grain|halation <name>: that preset on the photographs selected, as its list in Develop does.
        case "sectionsave", "sectionapply":
            guard words.count >= 2, let section = PresetSection(rawValue: words[0]) else { break }
            let name = words.dropFirst().joined(separator: " ")
            if command == "sectionsave" { SectionPresets.shared.save(name, values: model.sectionValues(section), in: section) }
            else if let preset = SectionPresets.shared.list(section).first(where: { $0.name == name }) { model.labApplySection(preset, section, to: model.editTargets) }
        case "sectiondelete": if words.count >= 2, let section = PresetSection(rawValue: words[0]) { SectionPresets.shared.delete(words.dropFirst().joined(separator: " "), in: section) }
        // halationmask on|off: Halation › Show mask.
        case "halationmask": model.halationMask = rest != "off"
        // applydevelop on|off: recipes apply their Develop part too. developgroups tone,color…: what New Preset saves of it.
        case "applydevelop": model.recipesApplyDevelop = rest != "off"
        case "developgroups": DevelopGroup.saved = Set(rest.split(separator: ",").compactMap { DevelopGroup(rawValue: String($0)) })
        case "renamepreset": model.renamingPreset = model.presets.first { $0.name == rest }?.url
        case "selectall": model.selectAll()
        // type <text>, or type ⏎ / ⎋: keys through the event queue, as typed.
        case "type": type(rest)
        // edit <text>: replaces what the field being typed in holds, as typing would, and leaves it (Return).
        case "edit":
            guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { break }
            editor.selectAll(nil); editor.insertText(rest, replacementRange: editor.selectedRange())
            window.makeFirstResponder(nil)
        // answer <text>: fills the sheet's text field and presses its first button (Save, OK…).
        case "answer":
            guard let sheet = window?.attachedSheet, let content = sheet.contentView else { break }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let all = views(content)
            if let field = all.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) { field.stringValue = rest }
            if let button = all.compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "\r" }) { button.performClick(nil) }
            else { window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        case "pickwb":
            // pickwb <x> <y>: the eyedropper's click, as fractions of the photograph from its top left.
            if words.count == 2, let x = Double(words[0]), let y = Double(words[1]) { model.pickWhiteBalance(at: CGPoint(x: x, y: y)) }
        case "zoomto":
            // zoomto <screen pixels per photograph pixel> | fit
            if rest == "fit" { model.canvasScale.zoom(to: nil) } else if let ratio = Double(rest) { model.canvasScale.zoom(to: CGFloat(ratio)) }
        case "devzoom": model.zoom(fit: rest != "100")
        case "original": model.holdOriginal(rest != "off")
        case "pan":
            // pan <dx> <dy>: scrolls the photograph by this many points of the canvas.
            if words.count == 2, let dx = Double(words[0]), let dy = Double(words[1]), let scroll = model.canvasScale.view {
                var point = scroll.contentView.bounds.origin
                point.x += dx / scroll.magnification; point.y += dy / scroll.magnification
                scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
            }
        case "sidebar": lab.sidebarVisible = rest != "off"
        case "favourite": lab.toggleFavourite(rest)
        case "print":
            // print <pdf path> [columns] [white]
            guard let path = words.first else { break }
            var options = SheetPrintOptions.load()
            if words.count > 1, let columns = Int(words[1]) { options.columns = columns }
            if words.contains("white") { options.background = .white }
            if words.contains("black") { options.background = .black }
            Task {
                let data = await SheetPrinter(model: model, options: options).pdf()
                try? data?.write(to: URL(fileURLWithPath: path))
                self.note("printed \(path) \(data?.count ?? 0)")
            }
        case "printdialog": lab.printing = rest != "off"
        case "settings": lab.openSettings()
        case "resize":
            if words.count == 2, let width = Double(words[0]), let height = Double(words[1]), let window {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height), display: true)
            }
        case "move":
            if words.count == 2, let x = Double(words[0]), let y = Double(words[1]) { window?.setFrameOrigin(NSPoint(x: x, y: y)) }
        case "screen":
            let frame = NSScreen.main?.frame ?? .zero
            try? "\(Int(frame.width)) \(Int(frame.height))".write(toFile: rest, atomically: true, encoding: .utf8)
        case "winid":
            // Every window of the app, the main one first: "<number> <title>".
            let windows = ([window].compactMap { $0 } + NSApp.windows.filter { $0 !== window && $0.isVisible })
            let text = windows.map { "\($0.windowNumber) \($0.title)" }.joined(separator: "\n")
            try? text.write(toFile: rest, atomically: true, encoding: .utf8)
        case "state":
            let counts = lab.counts
            let text = "previews=\(lab.previewBuilder.done)/\(lab.previewBuilder.total)\(lab.previewBuilder.running ? "+" : "") proxies=\(lab.proxyMaker.done)/\(lab.proxyMaker.total)\(lab.proxyMaker.busy ? "+" : "") leftout=\(lab.proxyMaker.leftOut.count) thumbnails=\(model.thumbnailsAsked.done)/\(model.thumbnailsAsked.total) left=\(model.thumbnailsLeft) work=[\(BackgroundWork.tasks(model).map { "\($0.kind.rawValue):\($0.figure.replacingOccurrences(of: " ", with: "_"))" }.joined(separator: ","))] kept=\(model.showsKeptRender) catalog=\(lab.catalogName) projects=\(lab.projects.projects.count) room=\(lab.workspace.rawValue) frames=\(lab.frames.count) picks=\(counts.picks) rejects=\(counts.rejects) selected=\(model.selection.selected.count) "
                + "current=\(model.selection.current?.lastPathComponent ?? "-") mode=\(model.mode) ready=\(model.ready) preview=\(model.previewCurrent) "
                + "status=[\(model.status)] film=\(model.film) panes=\(lab.compareModel.panes.count) images=\(lab.compareModel.images.values.map { "\($0.width)x\($0.height)" }.joined(separator: ",")) undo=\(window?.undoManager?.canUndo ?? false) "
                + "presets=[\(model.presets.map(\.name).joined(separator: "|"))] wb=\(model.value("io.raw_white_balance.mode").string)/\(Int(model.value("io.raw_white_balance.temperature").double))/\(model.value("io.raw_white_balance.tint").double) match=\(model.state.brightnessMatch?.ev.map { String(format: "%.2f", $0) } ?? (model.state.brightnessMatch == nil ? "off" : "pending")) renaming=\(model.renamingPreset?.lastPathComponent ?? "-") pane=\(model.inspectorPane) responder=\(window.map { w in (w.firstResponder as? NSTextView).flatMap { $0.delegate as? NSTextField }.map { "field:\($0.stringValue.replacingOccurrences(of: " ", with: "_")):hidden=\($0.isHiddenOrHasHiddenAncestor)" } ?? String(describing: w.firstResponder.map { Swift.type(of: $0) }) } ?? "-")\n"
            try? text.write(toFile: rest, atomically: true, encoding: .utf8)
        case "quit": NSApp.terminate(nil)
        default: note("unknown command: \(line)")
        }
    }

    private func type(_ text: String) {
        guard let main = window else { return }
        // A sheet over the window takes the keys.
        let window = main.attachedSheet ?? main
        window.makeKeyAndOrderFront(nil)
        for character in text {
            let (chars, code): (String, UInt16) = character == "⏎" ? ("\r", 36) : character == "⎋" ? ("\u{1b}", 53) : (String(character), 0)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
    }

    private func note(_ text: String) { FileHandle.standardError.write(Data("automation: \(text)\n".utf8)) }
}
