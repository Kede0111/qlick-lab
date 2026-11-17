// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Qlick Lab's icon, drawn by the lab's own code so it stays what the lab is: a frame of film ringed in red grease
/// pencil, on QLab's black. `QlickLab --qlick-icon <folder>` writes the icon set (`scripts/make_icon.sh`).
enum LabIcon {
    static func draw(_ context: CGContext, size: CGFloat) {
        let s = size / 1024
        context.saveGState()
        context.scaleBy(x: s, y: s)
        // Top-left origin, as the sheet's renderer.
        context.translateBy(x: 0, y: 1024)
        context.scaleBy(x: 1, y: -1)
        // macOS's icon tile.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        context.addPath(shape)
        context.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ground = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.115, alpha: 1), CGColor(gray: 0.02, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(ground, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

        // A strip of film across the tile, a little larger than it, tilted as it lies on the table.
        context.saveGState()
        context.translateBy(x: 512, y: 512)
        context.rotate(by: -0.075)
        context.translateBy(x: -512, y: -512)
        let layout = ContactSheetLayout(style: .classic, count: 3, width: 1500, frameWidth: 420, header: 0, showsNames: false, columns: 3, margin: 0)
        let strip = layout.strip(0)
        let window = layout.picture(1)
        context.translateBy(x: 512 - window.midX, y: 512 - window.midY)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(strip)
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        for top in [true, false] {
            for hole in layout.perforations(strip: strip, top: top) {
                context.addPath(CGPath(roundedRect: hole, cornerWidth: 5, cornerHeight: 5, transform: nil))
            }
        }
        context.fillPath()
        // The frames: light through a negative, no picture of anything.
        for index in 0..<3 {
            let picture = layout.picture(index)
            let light = CGGradient(colorsSpace: space, colors: [CGColor(gray: index == 1 ? 0.93 : 0.5, alpha: 1), CGColor(gray: index == 1 ? 0.66 : 0.3, alpha: 1)] as CFArray, locations: [0, 1])!
            context.saveGState()
            context.clip(to: picture)
            context.drawLinearGradient(light, start: CGPoint(x: picture.minX, y: picture.minY), end: CGPoint(x: picture.maxX, y: picture.maxY), options: [])
            context.restoreGState()
        }
        // The ring.
        let ring = window.insetBy(dx: -window.width * 0.085, dy: -window.height * 0.2)
        for stroke in GreasePencil.ring(in: ring, seed: "Qlick Lab icon 7", weight: 30) {
            context.setFillColor(SheetPalette.pencilRed.copy(alpha: CGFloat(stroke.opacity)) ?? SheetPalette.pencilRed)
            context.addPath(stroke.path())
            context.fillPath()
        }
        context.restoreGState()
        // The tile's edge catches a little light.
        context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.1))
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()
    }

    /// The icon from the project's own artwork (`assets/icon.png`, a square picture, edge to edge): set in macOS's
    /// rounded tile with its margin, for the `.icns` older macOS shows. macOS 26 and later round it themselves
    /// from `macos/AppIcon.icon`.
    static func draw(_ context: CGContext, size: CGFloat, artwork: CGImage) {
        let s = size / 1024
        context.saveGState()
        context.scaleBy(x: s, y: s)
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        placeArtwork(artwork, in: tile, context: context)
        // No line round the edge: it read as a grey border.
        context.restoreGState()
    }

    /// The artwork's black, under it.
    static let ground = CGColor(srgbRed: 3 / 255, green: 3 / 255, blue: 6 / 255, alpha: 1)
    /// How much of the tile the artwork takes: a little margin keeps its red dot clear of the rounded corner.
    static let artworkScale: CGFloat = 0.92

    /// `artwork` in `tile`, on its black: filled, never stretched (a picture that isn't quite square is cut at its
    /// sides), then a little smaller than the tile.
    static func placeArtwork(_ artwork: CGImage, in tile: CGRect, context: CGContext) {
        context.setFillColor(ground)
        context.fill(tile)
        let aspect = CGFloat(artwork.width) / CGFloat(max(artwork.height, 1))
        let fitted = aspect >= 1 ? CGSize(width: tile.height * aspect, height: tile.height) : CGSize(width: tile.width, height: tile.width / aspect)
        let size = CGSize(width: fitted.width * artworkScale, height: fitted.height * artworkScale)
        context.saveGState()
        context.clip(to: tile.insetBy(dx: tile.width * (1 - artworkScale) / 2, dy: tile.height * (1 - artworkScale) / 2))
        context.draw(artwork, in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }

    /// The square, edge to edge, for Icon Composer's file: macOS 26 and later cut their own rounded shape from it.
    static func fullBleed(_ artwork: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        placeArtwork(artwork, in: CGRect(x: 0, y: 0, width: 1024, height: 1024), context: context)
        return context.makeImage()
    }

    static func image(_ pixels: Int, artwork: CGImage? = nil) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        if let artwork { draw(context, size: CGFloat(pixels), artwork: artwork) } else { draw(context, size: CGFloat(pixels)) }
        return context.makeImage()
    }

    /// Writes `<folder>/AppIcon.appiconset` for the asset catalog and `<folder>/QlickLab.iconset` for `iconutil`:
    /// from `artwork` (a picture file) if given, else the icon the lab draws itself.
    static func write(to folder: URL, artwork source: URL? = nil) throws {
        var artwork: CGImage?
        if let source {
            guard let read = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(read, 0, nil) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            artwork = image
        }
        let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
        let catalog = folder.appendingPathComponent("AppIcon.appiconset"), iconset = folder.appendingPathComponent("QlickLab.iconset")
        for directory in [catalog, iconset] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var entries: [[String: String]] = []
        for (points, scale) in sizes {
            guard let image = image(points * scale, artwork: artwork) else { continue }
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            for directory in [catalog, iconset] {
                guard let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
        if let artwork, let square = fullBleed(artwork),
           let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("icon-square.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, square, nil)
            CGImageDestinationFinalize(destination)
        }
        let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: catalog.appendingPathComponent("Contents.json"))
    }
}
