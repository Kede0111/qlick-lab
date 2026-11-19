// Qlick Lab — GPL-3.0-only.
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: The caption's choice

/// What the caption over the photograph can show.
enum CaptionField: String, Codable, CaseIterable, Sendable {
    case camera, lens, iso, shutter, aperture, focalLength, date, pixels, fileName

    var title: String {
        switch self {
        case .camera: "Camera"
        case .lens: "Lens"
        case .iso: "ISO"
        case .shutter: "Shutter Speed"
        case .aperture: "Aperture"
        case .focalLength: "Focal Length"
        case .date: "Date"
        case .pixels: "Dimensions"
        case .fileName: "File Name"
        }
    }
}

/// The caption over the photograph: shown or not, and with what (View › Caption).
struct CaptionOptions: Codable, Equatable, Sendable {
    var visible = true
    var fields = Self.standard

    static let standard: Set<CaptionField> = [.camera, .iso, .shutter, .aperture, .focalLength, .fileName]
    static let key = "qlick.caption"

    static func load(_ defaults: UserDefaults = .standard) -> CaptionOptions {
        guard let data = defaults.data(forKey: key), let options = try? JSONDecoder().decode(CaptionOptions.self, from: data) else { return CaptionOptions() }
        return options
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The caption's menu, in View and in Develop's right-click menu: Show Caption, then a tick for each thing it can show.
@MainActor final class CaptionCommands: NSObject, NSMenuItemValidation {
    private unowned let lab: LabState
    init(lab: LabState) { self.lab = lab }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Caption")
        let show = menu.addItem(withTitle: "Show Caption", action: #selector(toggleVisible), keyEquivalent: "")
        show.target = self
        menu.addItem(.separator())
        for (index, field) in CaptionField.allCases.enumerated() {
            let item = menu.addItem(withTitle: field.title, action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Everything", action: #selector(everything), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Back to the Usual", action: #selector(usual), keyEquivalent: "").target = self
        return menu
    }

    @objc private func toggleVisible() { lab.caption.visible.toggle() }
    @objc private func toggleField(_ item: NSMenuItem) {
        guard CaptionField.allCases.indices.contains(item.tag) else { return }
        let field = CaptionField.allCases[item.tag]
        if lab.caption.fields.contains(field) { lab.caption.fields.remove(field) } else { lab.caption.fields.insert(field) }
        // Choosing what it shows is asking to see it.
        lab.caption.visible = true
    }
    @objc private func everything() { lab.caption = CaptionOptions(visible: true, fields: Set(CaptionField.allCases)) }
    @objc private func usual() { lab.caption = CaptionOptions() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleVisible): item.state = lab.caption.visible ? .on : .off
        case #selector(toggleField(_:)):
            item.state = CaptionField.allCases.indices.contains(item.tag) && lab.caption.fields.contains(CaptionField.allCases[item.tag]) ? .on : .off
        case #selector(everything): return lab.caption.fields.count < CaptionField.allCases.count || !lab.caption.visible
        case #selector(usual): return lab.caption != CaptionOptions()
        default: break
        }
        return true
    }
}

// MARK: Develop's right-click menu

/// The menu a right-click on the photograph opens in Develop: the zoom, the edits to copy and paste, the marks,
/// the turns, the information and what's done with the file.
@MainActor final class DevelopCommands: NSObject {
    private unowned let lab: LabState
    private var model: EditorModel { lab.model }
    /// The photograph the open menu is about, and where it was clicked (the canvas's document).
    private var item: URL?
    private var point: CGPoint?
    private var presets: [PresetFile] = []

    init(lab: LabState) { self.lab = lab }

    func menu(at point: CGPoint?) -> NSMenu? {
        guard lab.workspace == .develop, model.mode == .photo, !model.cropping, model.alert == nil, let item = model.sourceItem else { return nil }
        self.item = item; self.point = point
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        let summary = model.library.summary(for: item)
        let editing = model.canChangeEdits
        let developed = model.image != nil

        // The zoom, about the place clicked.
        let ratio = model.zoomShown
        add(menu, "Fit to Window", #selector(fit), key: "0", on: model.fitImage)
        add(menu, "100 %", #selector(actualSize), key: "1", on: !model.fitImage && abs(ratio - 1) < 0.01)
        let zoom = NSMenu()
        for step in CanvasScale.steps {
            let entry = add(zoom, Self.zoomTitle(step), #selector(zoomTo(_:)), on: !model.fitImage && abs(ratio - step) < 0.01 * step)
            entry.representedObject = step
        }
        menu.addItem(withTitle: "Zoom", action: nil, keyEquivalent: "").submenu = zoom
        add(menu, "Zoom Tool", #selector(toggleLoupe), key: "z", modifiers: [], on: lab.developLoupe)
        menu.addItem(.separator())

        add(menu, "Copy Edits", #selector(copyEdits), key: "c", modifiers: [.command, .shift], enabled: editing)
        add(menu, "Copy Edits…", #selector(copyEditsChoosing), key: "c", modifiers: [.command, .shift, .option], enabled: editing)
        add(menu, "Paste Edits", #selector(pasteEdits), key: "v", modifiers: [.command, .shift], enabled: editing && model.copiedEdits != nil)
        add(menu, "Paste from Previous", #selector(pasteFromPrevious), key: "v", modifiers: [.command, .shift, .option], enabled: editing && model.previousEdits != nil)
        presets = model.presets
        for (title, action) in [("Apply Recipe", #selector(applyPreset(_:))), ("Apply Recipe with Auto WB & Exposure", #selector(applyPresetAdapting(_:)))] {
            let list = NSMenu()
            for (index, preset) in presets.enumerated() { add(list, preset.name, action).tag = index }
            list.addItem(.separator())
            add(list, "Apply Develop Settings Too", #selector(toggleRecipeDevelop), on: model.recipesApplyDevelop)
            let applying = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            if editing, model.canChangePresets, !presets.isEmpty { applying.submenu = list } else { applying.isEnabled = false }
        }
        add(menu, "Reset Edits", #selector(resetEdits), key: "r", modifiers: [.command, .shift], enabled: editing)
        add(menu, "New Version (Virtual Copy)", #selector(duplicate), key: "d", enabled: editing)
        menu.addItem(.separator())

        add(menu, "Before / After", #selector(beforeAfter), key: "y", modifiers: [], on: model.holdingOriginal, enabled: model.canShowOriginal)
        let compare = NSMenu()
        add(compare, "Before and After, Side by Side", #selector(compareBeforeAfter))
        add(compare, "Films on This Photograph", #selector(compareFilms))
        add(compare, "Recipes on This Photograph", #selector(compareRecipes))
        let versions = add(compare, "Versions", #selector(compareVersions))
        versions.isEnabled = !(model.library.duplicates[item.photoFile] ?? []).isEmpty
        menu.addItem(withTitle: "Compare", action: nil, keyEquivalent: "").submenu = compare
        menu.addItem(.separator())

        let keys = lab.keys
        add(menu, "Pick", #selector(pick), key: keys.key(.pick), modifiers: [], on: summary.flag == .pick)
        add(menu, "Reject", #selector(reject), key: keys.key(.reject), modifiers: [], on: summary.flag == .reject)
        add(menu, "Clear the Mark", #selector(unmark), key: keys.key(.unmark), modifiers: [], enabled: summary.flag != nil)
        let rating = NSMenu()
        for stars in 0...5 {
            let entry = add(rating, stars == 0 ? "None" : String(repeating: "★", count: stars), #selector(rate(_:)), key: "\(stars)", modifiers: [], on: summary.rating == stars)
            entry.tag = stars
        }
        menu.addItem(withTitle: "Rating", action: nil, keyEquivalent: "").submenu = rating
        menu.addItem(.separator())

        add(menu, "Rotate Left", #selector(rotateLeft), key: "r", modifiers: [.command, .option], enabled: developed)
        add(menu, "Rotate Right", #selector(rotateRight), key: "r", enabled: developed)
        add(menu, "Crop and Straighten", #selector(crop), key: "k", enabled: developed)
        add(menu, "Straighten Automatically", #selector(autoStraighten), enabled: developed)
        menu.addItem(.separator())

        add(menu, "Photograph Information", #selector(toggleInfo), key: "i", on: lab.infoVisible)
        menu.addItem(withTitle: "Caption", action: nil, keyEquivalent: "").submenu = lab.captionCommands.makeMenu()
        menu.addItem(.separator())

        add(menu, model.exportTitle, #selector(export), key: "e", modifiers: [.command, .shift], enabled: model.canExport)
        add(menu, "Show in Finder", #selector(reveal))
        menu.addItem(.separator())
        add(menu, "Move to Trash…", #selector(trash), enabled: model.canDelete)
        return menu
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                                        on: Bool = false, enabled: Bool = true) -> NSMenuItem {
        // Set here, as the menu is made: nothing validates it again.
        menu.autoenablesItems = false
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key == "\r" || key == " " ? "" : key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        entry.state = on ? .on : .off
        entry.isEnabled = enabled
        return entry
    }

    static func zoomTitle(_ ratio: CGFloat) -> String {
        if ratio >= 1 { return "\(Int((ratio * 100).rounded())) %" }
        let percent = ratio * 100
        // An eighth is 12.5 %; a third and two thirds are said whole.
        return abs(percent * 2 - (percent * 2).rounded()) < 0.01 && percent != percent.rounded() ? String(format: "%.1f %%", percent) : "\(Int(percent.rounded())) %"
    }

    private var targets: [URL] { item.map { [$0] } ?? [] }

    @objc private func fit() { model.zoom(fit: true) }
    @objc private func actualSize() { model.canvasScale.zoom(to: 1, at: point) }
    @objc private func zoomTo(_ sender: NSMenuItem) { if let step = sender.representedObject as? CGFloat { model.canvasScale.zoom(to: step, at: point) } }
    @objc private func toggleLoupe() { lab.developLoupe.toggle() }
    @objc private func copyEdits() { model.copyEdits(from: item) }
    @objc private func copyEditsChoosing() { model.copyEditsChoosing() }
    @objc private func pasteEdits() { model.pasteEdits(onto: targets) }
    @objc private func pasteFromPrevious() { model.pasteFromPrevious(onto: targets) }
    @objc private func applyPreset(_ sender: NSMenuItem) { if presets.indices.contains(sender.tag) { model.labApply(presets[sender.tag], to: targets) } }
    @objc private func applyPresetAdapting(_ sender: NSMenuItem) { if presets.indices.contains(sender.tag) { model.labApply(presets[sender.tag], to: targets, adapting: true) } }
    @objc private func toggleRecipeDevelop() { model.recipesApplyDevelop.toggle() }
    @objc private func resetEdits() { model.resetEdits(of: targets) }
    @objc private func duplicate() { model.duplicate(targets) }
    @objc private func beforeAfter() { model.holdOriginal(!model.holdingOriginal) }
    @objc private func compareBeforeAfter() { compare(.beforeAfter) }
    @objc private func compareFilms() { compare(.films) }
    @objc private func compareRecipes() { compare(.recipes) }
    @objc private func compareVersions() { compare(.versions) }
    private func compare(_ kind: CompareSetup.Kind) {
        guard let item else { return }
        lab.compare.items = [item]
        lab.show(.compare)
        lab.compareModel.setKind(kind)
    }
    @objc private func pick() { toggle(.pick) }
    @objc private func reject() { toggle(.reject) }
    private func toggle(_ flag: PhotoSidecar.Flag) {
        guard let item else { return }
        model.setFlag(model.library.summary(for: item).flag == flag ? nil : flag, targets: [item])
    }
    @objc private func unmark() { model.setFlag(nil, targets: targets) }
    @objc private func rate(_ sender: NSMenuItem) { model.setRating(sender.tag, targets: targets) }
    @objc private func rotateLeft() { model.quarterTurn(clockwise: false) }
    @objc private func rotateRight() { model.quarterTurn(clockwise: true) }
    @objc private func crop() { model.beginCrop() }
    @objc private func autoStraighten() { model.autoStraighten() }
    @objc private func toggleInfo() { lab.infoVisible.toggle() }
    @objc private func export() { model.exportPanel() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.photoFile)) }
    @objc private func trash() { model.requestDelete(targets, asking: true) }
}

// MARK: The photograph's metadata

/// Everything the file says about itself, in the order it's read on the panel: read from its tags, never written.
struct PhotoMetadata: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }
    struct Section: Equatable, Sendable, Identifiable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }
    var sections: [Section] = []

    nonisolated static func read(_ url: URL) -> PhotoMetadata {
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let kind = (source.flatMap { CGImageSourceGetType($0) } as String?).flatMap { UTType($0)?.localizedDescription }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return PhotoMetadata(properties: properties, url: url, kind: kind, bytes: values?.fileSize, modified: values?.contentModificationDate)
    }

    init(properties: [CFString: Any], url: URL? = nil, kind: String? = nil, bytes: Int? = nil, modified: Date? = nil) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        let facts = PhotoFacts(properties: properties)
        func number(_ value: Any?) -> Double? {
            guard let value = (value as? [Any])?.first ?? value, let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
            return number
        }
        func text(_ value: Any?) -> String? {
            let string = (value as? String) ?? (value as? [String])?.joined(separator: ", ") ?? (value as? NSNumber)?.stringValue
            guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        func short(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
        func day(_ date: Date) -> String {
            date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().second().locale(Locale(identifier: "en_GB")))
        }
        var sections: [Section] = []
        func section(_ title: String, _ rows: [(String, String?)]) {
            let present = rows.compactMap { row in row.1.map { Row(label: row.0, value: $0) } }
            if !present.isEmpty { sections.append(Section(title: title, rows: present)) }
        }

        var size: String?
        if let pixels = facts.pixels {
            let megapixels = pixels.width * pixels.height / 1_000_000
            size = "\(Int(pixels.width)) × \(Int(pixels.height))  (\(megapixels >= 10 ? String(format: "%.0f", megapixels) : String(format: "%.1f", megapixels)) MP)"
        }
        section("File", [
            ("Name", url?.lastPathComponent),
            ("Kind", kind),
            ("Size", bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }),
            ("Dimensions", size),
            ("Bit Depth", number(properties[kCGImagePropertyDepth]).map { "\(Int($0)) bits per channel" }),
            ("Colour Profile", text(properties[kCGImagePropertyProfileName])),
            ("Folder", url?.deletingLastPathComponent().path),
        ])

        section("Camera", [
            ("Camera", facts.camera),
            ("Lens", facts.lens),
            ("Body Serial", text(exif[kCGImagePropertyExifBodySerialNumber]) ?? text(aux[kCGImagePropertyExifAuxSerialNumber]) ?? text(dng[kCGImagePropertyDNGCameraSerialNumber])),
            ("Lens Serial", text(exif[kCGImagePropertyExifLensSerialNumber]) ?? text(aux[kCGImagePropertyExifAuxLensSerialNumber])),
            ("Firmware", text(tiff[kCGImagePropertyTIFFSoftware])),
        ])

        var focal35: String?
        if let equivalent = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]), equivalent > 0, equivalent != facts.focalLength { focal35 = "\(short(equivalent)) mm" }
        var bias: String?
        if let value = number(exif[kCGImagePropertyExifExposureBiasValue]) {
            bias = abs(value) < 0.005 ? "0 EV" : String(format: "%+.2f EV", value).replacingOccurrences(of: ".00", with: "").replacingOccurrences(of: "-", with: "−")
        }
        let programs = [1: "Manual", 2: "Program", 3: "Aperture Priority", 4: "Shutter Priority", 5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
        let meterings = [1: "Average", 2: "Centre-Weighted", 3: "Spot", 4: "Multi-Spot", 5: "Multi-Segment", 6: "Partial"]
        var flash: String?
        if let value = number(exif[kCGImagePropertyExifFlash]) { flash = Int(value) & 1 == 1 ? "Fired" : "Did Not Fire" }
        var balance: String?
        if let value = number(exif[kCGImagePropertyExifWhiteBalance]) { balance = Int(value) == 0 ? "Auto" : "Manual" }
        section("Exposure", [
            ("Shutter Speed", facts.exposure.map { $0 < 1 ? "\(PhotoFacts.shutter($0)) s" : PhotoFacts.shutter($0) }),
            ("Aperture", facts.aperture.map { "f/\(short($0))" }),
            ("ISO", facts.iso.map { "\(Int($0.rounded()))" }),
            ("Focal Length", facts.focalLength.map { "\(short($0)) mm" }),
            ("In 35 mm", focal35),
            ("Compensation", bias),
            ("Mode", number(exif[kCGImagePropertyExifExposureProgram]).flatMap { programs[Int($0)] }),
            ("Metering", number(exif[kCGImagePropertyExifMeteringMode]).flatMap { meterings[Int($0)] }),
            ("White Balance", balance),
            ("Flash", flash),
        ])

        var taken = facts.date.map(day)
        if taken != nil, let offset = text(exif[kCGImagePropertyExifOffsetTimeOriginal]) { taken! += "  (UTC\(offset))" }
        section("Date", [("Taken", taken), ("File Changed", modified.map(day))])

        section("Author", [
            ("Artist", text(tiff[kCGImagePropertyTIFFArtist]) ?? text(iptc[kCGImagePropertyIPTCByline])),
            ("Copyright", text(tiff[kCGImagePropertyTIFFCopyright]) ?? text(iptc[kCGImagePropertyIPTCCopyrightNotice])),
            ("Title", text(iptc[kCGImagePropertyIPTCObjectName])),
            ("Description", text(tiff[kCGImagePropertyTIFFImageDescription]) ?? text(iptc[kCGImagePropertyIPTCCaptionAbstract])),
            ("Keywords", text(iptc[kCGImagePropertyIPTCKeywords])),
        ])

        var place: String?
        if let latitude = number(gps[kCGImagePropertyGPSLatitude]), let longitude = number(gps[kCGImagePropertyGPSLongitude]) {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N", east = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            place = String(format: "%.5f° %@, %.5f° %@", latitude, north, longitude, east)
        }
        var altitude: String?
        if let metres = number(gps[kCGImagePropertyGPSAltitude]) {
            let below = number(gps[kCGImagePropertyGPSAltitudeRef]) == 1
            altitude = "\(below ? "−" : "")\(Int(metres.rounded())) m"
        }
        section("Place", [("Coordinates", place), ("Altitude", altitude)])
        self.sections = sections
    }

    /// The whole of it as text, for the pasteboard.
    var text: String {
        sections.map { section in ([section.title.uppercased()] + section.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n") }.joined(separator: "\n\n")
    }
}

/// The open photograph's metadata on a pane of glass at the canvas's top left (View › Photograph Information, ⌘I,
/// the toolbar's i): what the camera recorded, to read and to copy.
struct PhotoInfoPanel: View {
    let model: EditorModel
    let grid: Bool
    @State private var metadata: PhotoMetadata?
    @State private var read: URL?
    static let width: CGFloat = 292, margin: CGFloat = 10

    var body: some View {
        let lab = model.lab
        let file = model.sourceItem?.photoFile
        let shown = lab.infoVisible && !grid && !model.imageOnly && !model.cropping && file != nil
        ZStack(alignment: .topLeading) {
            if shown {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    // As tall as what it says; it scrolls only when the canvas is shorter.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollView { rows }.scrollIndicators(.never)
                    }
                }
                .frame(width: Self.width)
                .background(Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(Self.margin)
                .environment(\.colorScheme, .dark)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Photograph Information")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: shown)
        // A fitted photograph keeps clear of it; a zoomed one runs under it.
        .onAppear { model.canvasScale.leadingObstruction = shown ? Self.width + 2 * Self.margin : 0 }
        .onChange(of: shown) { _, shown in model.canvasScale.leadingObstruction = shown ? Self.width + 2 * Self.margin : 0 }
        .task(id: shown ? file : nil) {
            guard shown, let file else { return }
            if read != file { metadata = nil }
            let fresh = await Task.detached(priority: .userInitiated) { PhotoMetadata.read(file) }.value
            guard !Task.isCancelled else { return }
            metadata = fresh; read = file
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            CapsLabel("Information", size: 10.5, color: Theme.paper)
            Spacer(minLength: 8)
            QIconButton(symbol: "doc.on.doc", help: "Copy all of it as text") {
                guard let metadata else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(metadata.text, forType: .string)
            }
            QIconButton(symbol: "xmark", help: "Close (⌘I)") { model.lab.infoVisible = false }
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 38)
    }

    @ViewBuilder private var rows: some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 14) {
                if metadata.sections.isEmpty {
                    Text("This file says nothing about itself.").font(Theme.caps(12)).foregroundStyle(Theme.dim)
                }
                ForEach(metadata.sections) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        CapsLabel(section.title, size: 9.5)
                        ForEach(section.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.label).font(Theme.caps(11.5, weight: .regular)).foregroundStyle(Color(white: 0.62))
                                    .frame(width: 92, alignment: .leading)
                                Text(row.value).font(Theme.value(11.5)).foregroundStyle(Theme.paper)
                                    .textSelection(.enabled)
                                    .lineLimit(row.label == "Folder" ? 2 : 4).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(row.value)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading…").font(Theme.caps(12)).foregroundStyle(Theme.dim)
            }
            .padding(16)
        }
    }
}
