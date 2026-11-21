// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import CoreImage
import IOSurface
import SwiftUI

/// Print's colour check: where the photograph's colours reach past the output colour space, and where they lie on the
/// CIE 1931 xy chromaticity diagram.
///
/// The check develops the photograph once more, in ProPhoto RGB (the widest), with the Lab's second helper
/// (`LabDeveloper`), only while Show out-of-gamut is ticked. That picture, brought into the output space with no
/// clipping (extended range), has values under 0 or over 1 exactly where the output space can't hold the colour: there
/// the engine's gamut compression changes it to fit. Nothing in the engine or the preview changes for it.
enum Gamut {
    /// The marks' colour: a cyan that reads on any photograph and is never the lab's red.
    static let markHex: UInt32 = 0x18d4f0
    static var mark: Color { Theme.color(markHex) }

    /// How far past 0 or 1 a linear value is out (the 8-bit picture's own rounding stays in).
    static let tolerance: Float = 0.004

    struct Check: Equatable, Sendable {
        /// The marks, as large as the picture checked: the cyan where a colour is out, clear elsewhere.
        var marks: CGImage?
        /// The share of the picture out of the space, 0…1.
        var fraction: Double
        /// The picture's colours on the xy diagram, a few thousand at most.
        var cloud: [Gamut.Dot]
        static func == (a: Check, b: Check) -> Bool { a.fraction == b.fraction && a.cloud == b.cloud && (a.marks == nil) == (b.marks == nil) }
    }

    /// The output space by name, as `SaveSettings.colorSpaces` names it.
    static func space(_ name: String) -> CGColorSpace? {
        switch name {
        case "sRGB": CGColorSpace(name: CGColorSpace.sRGB)
        case "Display P3": CGColorSpace(name: CGColorSpace.displayP3)
        case "Adobe RGB (1998)": CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case "ProPhoto RGB": CGColorSpace(name: CGColorSpace.rommrgb)
        default: nil
        }
    }

    /// Checks `image` (a picture developed in a wider space) against the space named `name`; `marking` makes the marks.
    nonisolated static func check(_ image: CGImage, against name: String, marking: Bool) -> Check? {
        guard let base = space(name), let linear = CGColorSpaceCreateExtendedLinearized(base) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let floats = pixels(image, in: linear) else { return nil }
        var marks: [UInt8] = marking ? Array(repeating: 0, count: width * height * 4) : []
        let (r, g, b) = Theme.components(markHex)
        var out = 0
        let low = -tolerance, high = 1 + tolerance
        for i in 0..<(width * height) {
            let o = i * 4
            let (x, y, z) = (floats[o], floats[o + 1], floats[o + 2])
            if x < low || y < low || z < low || x > high || y > high || z > high {
                out += 1
                if marking {
                    marks[o] = UInt8(r * 255); marks[o + 1] = UInt8(g * 255); marks[o + 2] = UInt8(b * 255); marks[o + 3] = 255
                }
            }
        }
        var image8: CGImage?
        if marking, let provider = CGDataProvider(data: Data(marks) as CFData) {
            image8 = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return Check(marks: image8, fraction: Double(out) / Double(width * height), cloud: cloud(image))
    }

    /// The picture's colours as xy chromaticities, on a grid of at most `most` points; black and near-black left out.
    /// A colour of the photograph on the diagram: where it lies (xy), and its own colour at full brightness, in linear
    /// Rec. 2020 (so a dark red is drawn red, readable on the panel).
    struct Dot: Equatable, Sendable {
        var x: CGFloat, y: CGFloat
        var r: Float, g: Float, b: Float
        var point: CGPoint { CGPoint(x: x, y: y) }
    }

    nonisolated static func cloud(_ image: CGImage, most: Int = 2500) -> [Dot] {
        // Linear Rec. 2020, unclipped, then to XYZ by its matrix (D65).
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020), let floats = pixels(image, in: linear) else { return [] }
        let count = image.width * image.height
        let step = max(1, count / most)
        var points: [Dot] = []
        for i in stride(from: 0, to: count, by: step) {
            let o = i * 4
            let (r, g, b) = (Double(floats[o]), Double(floats[o + 1]), Double(floats[o + 2]))
            let x = 0.6370 * r + 0.1446 * g + 0.1689 * b
            let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
            let z = 0.0281 * g + 1.0610 * b
            let sum = x + y + z
            guard y > 0.01, sum > 0 else { continue }
            let peak = max(r, g, b, 1e-6)
            points.append(Dot(x: x / sum, y: y / sum, r: Float(max(r, 0) / peak), g: Float(max(g, 0) / peak), b: Float(max(b, 0) / peak)))
        }
        return points
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The preview on screen as a small picture, in its own colour space (the surface's tag), for the cloud.
    nonisolated static func picture(_ surface: IOSurface, longSide: CGFloat) -> CGImage? {
        let image = CIImage(ioSurface: surface)
        let scale = min(1, longSide / max(image.extent.width, image.extent.height, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent.integral, format: .RGBAh,
                                     colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
    }

    /// The picture's pixels as 32-bit float RGBA in `space`, unclipped.
    nonisolated private static func pixels(_ image: CGImage, in space: CGColorSpace) -> [Float]? {
        let width = image.width, height = image.height
        var floats = [Float](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let drawn = floats.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16,
                                          space: space, bitmapInfo: info.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? floats : nil
    }

    // MARK: The diagram's data

    /// The spectral locus of the CIE 1931 2° observer, 380 to 700 nm: the edge of the colours an eye sees.
    static let locus: [CGPoint] = [
        (0.1741, 0.0050), (0.1733, 0.0048), (0.1714, 0.0051), (0.1689, 0.0069), (0.1644, 0.0109), (0.1566, 0.0177),
        (0.1440, 0.0297), (0.1241, 0.0578), (0.1096, 0.0868), (0.0913, 0.1327), (0.0687, 0.2007), (0.0454, 0.2950),
        (0.0235, 0.4127), (0.0082, 0.5384), (0.0039, 0.6548), (0.0139, 0.7502), (0.0389, 0.8120), (0.0743, 0.8338),
        (0.1142, 0.8262), (0.1547, 0.8059), (0.2296, 0.7543), (0.3016, 0.6923), (0.3731, 0.6245), (0.4441, 0.5547),
        (0.5125, 0.4866), (0.5752, 0.4242), (0.6270, 0.3725), (0.6658, 0.3340), (0.6915, 0.3083), (0.7079, 0.2920),
        (0.7190, 0.2809), (0.7260, 0.2740), (0.7300, 0.2700), (0.7334, 0.2666), (0.7347, 0.2653),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    /// Each output space's primaries, red, green and blue, in xy.
    static func primaries(_ name: String) -> [CGPoint]? {
        let values: [(Double, Double)]
        switch name {
        case "sRGB": values = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
        case "Display P3": values = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
        case "Adobe RGB (1998)": values = [(0.64, 0.33), (0.21, 0.71), (0.15, 0.06)]
        case "ProPhoto RGB": values = [(0.7347, 0.2653), (0.1596, 0.8404), (0.0366, 0.0001)]
        default: return nil
        }
        return values.map { CGPoint(x: $0.0, y: $0.1) }
    }
}

/// The CIE 1931 xy diagram, in a fine line: the horseshoe of the colours an eye sees, the output space's triangle (in
/// paper), the screen's (Display P3, dashed), and the photograph's colours as a cloud of their own colours.
struct GamutDiagram: View {
    let space: String
    let cloud: [Gamut.Dot]

    var body: some View {
        Canvas { context, size in
            // x from 0 to 0.8, y from 0 to 0.9, y up.
            let inset: CGFloat = 6
            let scale = min((size.width - inset * 2) / 0.8, (size.height - inset * 2) / 0.9)
            func p(_ point: CGPoint) -> CGPoint { CGPoint(x: inset + point.x * scale, y: size.height - inset - point.y * scale) }
            func polygon(_ points: [CGPoint]) -> Path {
                var path = Path()
                for (i, point) in points.enumerated() { if i == 0 { path.move(to: p(point)) } else { path.addLine(to: p(point)) } }
                path.closeSubpath()
                return path
            }
            context.stroke(polygon(Gamut.locus), with: .color(Theme.dim), lineWidth: 1)
            // Qlick Lab: each colour of the photograph in its own colour (wide colours as far as the screen shows),
            // under the outlines, which stay readable over it.
            let wide = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
            for dot in cloud {
                let at = p(dot.point)
                let colour = CGColor(colorSpace: wide, components: [CGFloat(dot.r), CGFloat(dot.g), CGFloat(dot.b), 0.9]) ?? CGColor(gray: 0.7, alpha: 0.5)
                context.fill(Path(ellipseIn: CGRect(x: at.x - 1, y: at.y - 1, width: 2, height: 2)), with: .color(Color(cgColor: colour)))
            }
            if let screen = Gamut.primaries("Display P3") {
                context.stroke(polygon(screen), with: .color(Theme.faint), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let output = Gamut.primaries(space) {
                context.stroke(polygon(output), with: .color(Theme.paper), lineWidth: 1.2)
            }
            // The white point, D65.
            let white = p(CGPoint(x: 0.3127, y: 0.3290))
            context.fill(Path(ellipseIn: CGRect(x: white.x - 1.5, y: white.y - 1.5, width: 3, height: 3)), with: .color(Theme.paper))
        }
        .aspectRatio(0.8 / 0.9, contentMode: .fit)
        .accessibilityLabel("Chromaticity diagram: the visible colours, \(space)'s triangle, the screen's, and the photograph's colours")
    }
}
