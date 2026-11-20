// Qlick Lab — GPL-3.0-only. What a save or an export writes: format, bit depth, colour space, size, and the save
// panel's controls for them.
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

/// The engine picks the encoder from the file extension.
enum OutputFormat: String, CaseIterable {
    case png, jpeg, tiff, heif

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .heif: .heic
        }
    }
    var title: String {
        switch self {
        case .png: "PNG (lossless)"
        case .jpeg: "JPEG (smaller)"
        case .tiff: "TIFF (lossless)"
        case .heif: "HEIF 10-bit (smaller, more tones)"
        }
    }

    /// The format of the last save or export, offered first next time.
    static var last: OutputFormat {
        get { UserDefaults.standard.string(forKey: "outputFormat").flatMap(OutputFormat.init) ?? .png }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "outputFormat") }
    }
}

/// How a save encodes the file: bits per channel, colour space, and JPEG
/// quality. `colorSpace` is the space the file is in: ProPhoto RGB at 8 bits
/// is already replaced by Adobe RGB (`effectiveSpace`).
struct SaveSettings: Equatable {
    /// As colour names them, which the engine takes.
    static let colorSpaces = ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB"]
    /// ProPhoto RGB bands at 8 bits, so it needs 16; Adobe RGB stands in.
    static let prophoto = 3, prophotoFallback = 2
    static let qualityRange = 1...100

    /// nil is the format's default: 16 for TIFF, 8 for PNG and JPEG.
    var bitDepth: Int? = nil
    var colorSpace = 0
    var jpegQuality = 95
    /// Qlick Lab: the finishing step's choices (`ExportFinisher`).
    var sharpening = OutputSharpening.none
    var sharpeningAmount = SharpeningAmount.standard
    var metadata = ExportMetadata.all

    static func effectiveSpace(_ chosen: Int, bitDepth: Int) -> Int {
        let chosen = min(max(chosen, 0), colorSpaces.count - 1)
        return chosen == prophoto && bitDepth == 8 ? prophotoFallback : chosen
    }
    var spaceName: String { Self.colorSpaces[min(max(colorSpace, 0), Self.colorSpaces.count - 1)] }
    var isSRGB: Bool { colorSpace == 0 }

    /// The `save_options` of a save command.
    var json: JSONValue {
        var options: [String: JSONValue] = ["jpeg_quality": .number(Double(jpegQuality)), "color_space": .string(spaceName)]
        if let bitDepth { options["bit_depth"] = .number(Double(bitDepth)) }
        return .object(options)
    }
    /// The exporter's arguments.
    var arguments: [String] {
        ["--jpeg-quality", "\(jpegQuality)", "--color-space", spaceName] + (bitDepth.map { ["--bit-depth", "\($0)"] } ?? [])
    }
    /// For the save panel's message; nil for sRGB in an sRGB preview. The
    /// preview develops in `previewSpace`; afterwards it follows this save.
    func summary(export: Bool, previewSpace: String) -> String? {
        let follows = spaceName == previewSpace ? "" : "; the preview then shows \(spaceName)"
        if export { return isSRGB && follows.isEmpty ? nil : "Develops in \(spaceName) and embeds its profile\(follows)" }
        if spaceName == previewSpace { return isSRGB ? nil : "Keeps the preview's \(spaceName) colours and embeds its profile" }
        return "Converts the \(previewSpace) preview to \(spaceName), clipping colours outside the smaller space\(follows)"
    }

    /// The colour space last picked, which may be ProPhoto RGB at 8 bits.
    static var chosenSpace: Int {
        get { UserDefaults.standard.string(forKey: "colorSpace").flatMap { colorSpaces.firstIndex(of: $0) } ?? 0 }
        set { UserDefaults.standard.set(colorSpaces[min(max(newValue, 0), colorSpaces.count - 1)], forKey: "colorSpace") }
    }
    /// The bit depth last picked for `format`; JPEG is always 8-bit.
    static func bitDepth(for format: OutputFormat) -> Int {
        switch format {
        case .jpeg: 8
        // The engine writes 16 bits, which the HEIF keeps 10 of.
        case .heif: 16
        case .png: UserDefaults.standard.integer(forKey: "bitDepth.png") == 16 ? 16 : 8
        case .tiff: UserDefaults.standard.integer(forKey: "bitDepth.tiff") == 8 ? 8 : 16
        }
    }
    static func setBitDepth(_ depth: Int, for format: OutputFormat) {
        if format != .jpeg, format != .heif { UserDefaults.standard.set(depth, forKey: "bitDepth.\(format.rawValue)") }
    }
    static var lastQuality: Int {
        get { let q = UserDefaults.standard.integer(forKey: "jpegQuality"); return qualityRange.contains(q) ? q : 95 }
        set { UserDefaults.standard.set(newValue, forKey: "jpegQuality") }
    }
}

/// The size a save or export is fitted to, like `Fit` in
/// `spektrafilm-io::resize`: full size, or a number of pixels on the long or
/// short edge of the finished file, border included. Never enlarged.
struct ExportSize: Equatable {
    enum Edge: String, CaseIterable {
        case full, long, short
        var title: String {
            switch self {
            case .full: "Full Size"
            case .long: "Long Edge"
            case .short: "Short Edge"
            }
        }
    }
    var edge: Edge
    var pixels: Int

    static let full = ExportSize(edge: .full, pixels: 2048)
    static let pixelRange = 16...65_535

    /// The `fit` of a save command; nil at full size.
    var json: JSONValue? {
        switch edge {
        case .full: nil
        case .long: .object(["long_edge": .number(Double(pixels))])
        case .short: .object(["short_edge": .number(Double(pixels))])
        }
    }
    /// The exporter's arguments.
    var arguments: [String] {
        switch edge {
        case .full: []
        case .long: ["--long-edge", "\(pixels)"]
        case .short: ["--short-edge", "\(pixels)"]
        }
    }
    /// For the save panel's message; nil at full size.
    var summary: String? {
        edge == .full ? nil : "Fits \(pixels) px on the \(edge == .long ? "long" : "short") edge"
    }

    /// The size of the last save or export, offered first next time.
    static var last: ExportSize {
        get {
            let defaults = UserDefaults.standard
            let edge = defaults.string(forKey: "exportEdge").flatMap(Edge.init) ?? .full
            let pixels = defaults.integer(forKey: "exportEdgePixels")
            return ExportSize(edge: edge, pixels: pixelRange.contains(pixels) ? pixels : full.pixels)
        }
        set {
            UserDefaults.standard.set(newValue.edge.rawValue, forKey: "exportEdge")
            UserDefaults.standard.set(newValue.pixels, forKey: "exportEdgePixels")
        }
    }

    /// What a Size field's text means: its digits, or the default when there
    /// are none, clamped to the range. The field's formatter doesn't enforce
    /// the range while typing, so partial entries such as "2" stay in the
    /// field and this settles the value.
    static func pixels(from text: String) -> Int {
        let value = Int(text.filter(\.isNumber)) ?? full.pixels
        return min(max(value, pixelRange.lowerBound), pixelRange.upperBound)
    }
}

/// The save panel's Format, Bit Depth, Colour Space, JPEG Quality and Size
/// controls, and for exports the Engine pop-up. Changing the format
/// restricts the panel to that type, which also rewrites the extension in
/// the name field, and shows its bit depth (JPEG's fixed) and, for JPEG
/// only, the quality. ProPhoto RGB needs 16 bits: at 8 it is disabled and
/// Adobe RGB stands in until 16 bits bring it back. Changing anything
/// updates the message.
@MainActor final class FormatPicker: NSObject, NSTextFieldDelegate {
    let popup = NSPopUpButton()
    let enginePopup: NSPopUpButton?
    let depthPopup = NSPopUpButton()
    let spacePopup = NSPopUpButton()
    let qualitySlider = NSSlider(value: 95, minValue: Double(SaveSettings.qualityRange.lowerBound),
                                         maxValue: Double(SaveSettings.qualityRange.upperBound), target: nil, action: nil)
    let qualityLabel = NSTextField(labelWithString: "")
    var qualityRow: NSStackView!
    let stack = NSStackView()
    let edgePopup = NSPopUpButton()
    let pixelsField = NSTextField()
    /// Qlick Lab: output sharpening, its strength, and the metadata kept.
    let sharpenPopup = NSPopUpButton()
    let amountPopup = NSPopUpButton()
    let metadataPopup = NSPopUpButton()
    let qualityTitle = NSTextField(labelWithString: "Quality:")
    let message: (ExportEngine?, ExportSize, SaveSettings) -> String
    private weak var panel: NSSavePanel?
    /// A folder chooser picks no file type.
    let restrictsType: Bool
    /// Called when the format changes.
    var formatChanged: () -> Void = {}
    /// The colour space picked, and each lossless format's bit depth.
    var chosenSpace = SaveSettings.chosenSpace
    var depths: [OutputFormat: Int] = [.png: SaveSettings.bitDepth(for: .png), .tiff: SaveSettings.bitDepth(for: .tiff)]
    var format: OutputFormat { OutputFormat.allCases[max(popup.indexOfSelectedItem, 0)] }
    /// nil for Save Preview.
    var engine: ExportEngine? { enginePopup.map { ExportEngine.allCases[max($0.indexOfSelectedItem, 0)] } }
    var size: ExportSize {
        ExportSize(edge: ExportSize.Edge.allCases[max(edgePopup.indexOfSelectedItem, 0)],
                   pixels: ExportSize.pixels(from: pixelsField.stringValue))
    }
    var settings: SaveSettings {
        let depth = format == .heif ? 16 : depths[format] ?? 8
        return SaveSettings(bitDepth: depth, colorSpace: SaveSettings.effectiveSpace(chosenSpace, bitDepth: depth),
                            jpegQuality: Int(qualitySlider.doubleValue.rounded()),
                            sharpening: OutputSharpening.allCases[max(sharpenPopup.indexOfSelectedItem, 0)],
                            sharpeningAmount: SharpeningAmount.allCases[max(amountPopup.indexOfSelectedItem, 0)],
                            metadata: ExportMetadata.allCases[max(metadataPopup.indexOfSelectedItem, 0)])
    }

    /// `extraRows` go below the size: a batch's naming rows.
    init(panel: NSSavePanel, selected: OutputFormat, engine: ExportEngine?, size: ExportSize, restrictsType: Bool = true, extraRows: [NSView] = [],
         message: @escaping (ExportEngine?, ExportSize, SaveSettings) -> String) {
        self.panel = panel
        self.message = message
        self.restrictsType = restrictsType
        enginePopup = engine.map { _ in NSPopUpButton() }
        super.init()
        popup.addItems(withTitles: OutputFormat.allCases.map(\.title))
        popup.selectItem(at: OutputFormat.allCases.firstIndex(of: selected) ?? 0)
        popup.target = self; popup.action = #selector(changed)
        var rows = [NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])]
        depthPopup.addItems(withTitles: ["8-bit", "16-bit", "10-bit"])
        depthPopup.target = self; depthPopup.action = #selector(depthChanged)
        rows.append(NSStackView(views: [NSTextField(labelWithString: "Bit Depth:"), depthPopup]))
        spacePopup.addItems(withTitles: SaveSettings.colorSpaces)
        spacePopup.autoenablesItems = false
        spacePopup.item(at: SaveSettings.prophoto)?.toolTip = "ProPhoto RGB needs 16 bits; 8 bits would band."
        spacePopup.target = self; spacePopup.action = #selector(spaceChanged)
        spacePopup.toolTip = "The colour space the file is saved in, with its ICC profile: chosen in Print."
        // Qlick Lab: one door for the output colour space, in Print; the panel shows it.
        spacePopup.isEnabled = false
        rows.append(NSStackView(views: [NSTextField(labelWithString: "Colour Space:"), spacePopup]))
        qualitySlider.doubleValue = Double(SaveSettings.lastQuality)
        qualitySlider.isContinuous = true
        qualitySlider.target = self; qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        qualityLabel.alignment = .right
        qualityLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        qualityRow = NSStackView(views: [qualityTitle, qualitySlider, qualityLabel])
        rows.append(qualityRow)
        if let enginePopup, let engine {
            enginePopup.addItems(withTitles: ExportEngine.allCases.map(\.title))
            enginePopup.selectItem(at: ExportEngine.allCases.firstIndex(of: engine) ?? 0)
            enginePopup.target = self; enginePopup.action = #selector(engineChanged)
            enginePopup.toolTip = "Reference develops the photo again with extra precision. Fast uses the preview's result and looks the same."
            rows.append(NSStackView(views: [NSTextField(labelWithString: "Engine:"), enginePopup]))
        }
        edgePopup.addItems(withTitles: ExportSize.Edge.allCases.map(\.title))
        edgePopup.selectItem(at: ExportSize.Edge.allCases.firstIndex(of: size.edge) ?? 0)
        edgePopup.target = self; edgePopup.action = #selector(sizeChanged)
        edgePopup.toolTip = "Fits the finished file, border included, to this many pixels. Never enlarges."
        // No minimum or maximum here: `size` reads `stringValue` on every
        // keystroke, which checks the text against the formatter, and a
        // range would clear every partial number ("1" on the way to "1600").
        // `size` clamps instead, and leaving the field shows the result.
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        pixelsField.formatter = formatter
        pixelsField.integerValue = size.pixels
        pixelsField.alignment = .right
        pixelsField.delegate = self
        pixelsField.setAccessibilityLabel("Size in pixels")
        pixelsField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        pixelsField.isEnabled = size.edge != .full
        rows.append(NSStackView(views: [NSTextField(labelWithString: "Size:"), edgePopup, pixelsField, NSTextField(labelWithString: "px")]))
        let defaults = UserDefaults.standard
        sharpenPopup.addItems(withTitles: OutputSharpening.allCases.map(\.title))
        sharpenPopup.selectItem(at: OutputSharpening.allCases.firstIndex { $0.rawValue == defaults.string(forKey: "qlick.exportSharpen") } ?? 0)
        sharpenPopup.target = self; sharpenPopup.action = #selector(finishingChanged)
        sharpenPopup.toolTip = "Sharpens the finished file for where it's shown, after it's sized."
        amountPopup.addItems(withTitles: SharpeningAmount.allCases.map(\.title))
        amountPopup.selectItem(at: SharpeningAmount.allCases.firstIndex { $0.rawValue == defaults.string(forKey: "qlick.exportSharpenAmount") } ?? 1)
        amountPopup.target = self; amountPopup.action = #selector(finishingChanged)
        rows.append(NSStackView(views: [NSTextField(labelWithString: "Sharpen For:"), sharpenPopup, amountPopup]))
        metadataPopup.addItems(withTitles: ExportMetadata.allCases.map(\.title))
        metadataPopup.selectItem(at: ExportMetadata.allCases.firstIndex { $0.rawValue == defaults.string(forKey: "qlick.exportMetadata") } ?? 0)
        metadataPopup.target = self; metadataPopup.action = #selector(finishingChanged)
        metadataPopup.toolTip = "What the file keeps of the camera's information: all of it, all but where it was taken, or none."
        rows.append(NSStackView(views: [NSTextField(labelWithString: "Metadata:"), metadataPopup]))
        rows.forEach(stack.addArrangedSubview)
        extraRows.forEach(stack.addArrangedSubview)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = stack
        if restrictsType { panel.allowedContentTypes = [selected.type] }
        sync()
    }

    /// Stores the choices for the next save.
    func remember() {
        SaveSettings.chosenSpace = chosenSpace
        for (format, depth) in depths { SaveSettings.setBitDepth(depth, for: format) }
        SaveSettings.lastQuality = settings.jpegQuality
        UserDefaults.standard.set(settings.sharpening.rawValue, forKey: "qlick.exportSharpen")
        UserDefaults.standard.set(settings.sharpeningAmount.rawValue, forKey: "qlick.exportSharpenAmount")
        UserDefaults.standard.set(settings.metadata.rawValue, forKey: "qlick.exportMetadata")
    }
    @objc func finishingChanged() { sync() }

    /// Brings the bit depth, colour space and quality controls in line with
    /// the format, then the message.
    func sync() {
        let current = settings
        depthPopup.selectItem(at: format == .heif ? 2 : current.bitDepth == 16 ? 1 : 0)
        depthPopup.item(at: 2)?.isHidden = format != .heif
        depthPopup.isEnabled = format != .jpeg && format != .heif
        depthPopup.toolTip = format == .jpeg ? "JPEG is 8-bit only." : format == .heif ? "HEIF is saved with 10 bits a channel: four times JPEG's tones, at about its size." : nil
        amountPopup.isEnabled = current.sharpening != .none
        qualityTitle.stringValue = format == .heif ? "HEIF Quality:" : "JPEG Quality:"
        spacePopup.item(at: SaveSettings.prophoto)?.isEnabled = current.bitDepth == 16
        spacePopup.selectItem(at: current.colorSpace)
        qualityLabel.stringValue = "\(current.jpegQuality)"
        qualityRow.isHidden = format != .jpeg && format != .heif
        stack.setFrameSize(stack.fittingSize)
        panel?.message = message(engine, size, current)
    }

    @objc func changed() {
        if restrictsType { panel?.allowedContentTypes = [format.type] }
        sync()
        formatChanged()
    }
    @objc func depthChanged() {
        if format != .jpeg { depths[format] = depthPopup.indexOfSelectedItem == 1 ? 16 : 8 }
        sync()
    }
    @objc func spaceChanged() { chosenSpace = max(spacePopup.indexOfSelectedItem, 0); sync() }
    @objc func qualityChanged() { qualityLabel.stringValue = "\(settings.jpegQuality)" }
    @objc func engineChanged() { panel?.message = message(engine, size, settings) }
    @objc func sizeChanged() {
        pixelsField.isEnabled = size.edge != .full
        if pixelsField.isEnabled {
            // Show the value that will be used, should the field have been
            // left blank or out of range, then focus it for typing.
            pixelsField.integerValue = size.pixels
            panel?.makeFirstResponder(pixelsField)
        }
        panel?.message = message(engine, size, settings)
    }
    func controlTextDidChange(_ notification: Notification) { panel?.message = message(engine, size, settings) }
    /// The message again, after a row of the caller's changed.
    func refreshMessage() { panel?.message = message(engine, size, settings) }
    /// Leaving the field writes back the clamped value, so a blank or
    /// out-of-range entry never sits beside a different export size.
    func controlTextDidEndEditing(_ notification: Notification) {
        let pixels = size.pixels
        if pixelsField.integerValue != pixels || pixelsField.stringValue.isEmpty { pixelsField.integerValue = pixels }
        panel?.message = message(engine, size, settings)
    }
}
