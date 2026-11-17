// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds how far a photograph leans, to level it at a click in the crop tool.
///
/// The straight edges of a photograph (a horizon, a roof line, the side of a wall) mostly lie along its two axes
/// when it's level. So every strong edge votes for the small angle that separates it from the nearest axis, the
/// near-horizontal ones and the near-vertical ones apart; the angle most of them agree on is the lean. Texture
/// votes for every angle alike and only raises the floor. With no clear agreement, the system's horizon detector
/// is asked instead.
enum AutoStraighten {
    struct Estimate: Equatable, Sendable {
        /// How far the photograph leans, in degrees clockwise on screen. Straightening it is turning it back.
        var lean: Double
        /// How much the peak stands over the other angles: about 1 is no agreement at all.
        var strength: Double
        var source: Source
        enum Source: String, Sendable { case horizontals, verticals, both, horizon }
    }

    /// The largest lean looked for: further than this, what is level and what is upright can't be told apart.
    static let limit = 15.0
    /// The lean a hand-held photograph usually has, in degrees: how fast a larger one loses credit.
    static let usual = 4.0
    /// Lines this far over the floor need no second opinion.
    static let clear = 2.0
    /// The long side the photograph is read at.
    static let longSide = 800
    /// A peak this much over the floor is a line to trust.
    static let trusted = 1.35

    /// The lean of `image`, or nil with nothing straight enough to go by.
    nonisolated static func estimate(_ image: CGImage) -> Estimate? {
        guard let (gray, width, height) = luminance(image) else { return nil }
        return choose(lines: estimate(gray: gray, width: width, height: height)) { horizon(image) }
    }

    /// Clear lines are believed outright. Faint ones give way to the horizon detector when it sees one, unless it
    /// asks for a large turn they don't back: far from level, it has more often found a slope or a wire.
    nonisolated static func choose(lines: Estimate?, horizon: () -> Estimate?) -> Estimate? {
        if let lines, lines.strength >= clear { return lines }
        guard let horizon = horizon() else { return lines }
        guard let lines else { return horizon }
        return abs(horizon.lean - lines.lean) < 1 || abs(horizon.lean) <= 5 ? horizon : lines
    }

    /// The lines' own vote, on a grey picture of `width` by `height`, rows from the top.
    ///
    /// Each family of edges (those along the width, those along the height) is tried at every angle of the range,
    /// a tenth of a degree apart: at the right one, the pixels of a long straight edge all fall on the same line,
    /// and the sum of the squared counts along the lines is at its highest. A long edge so counts for far more
    /// than the same number of scattered pixels.
    nonisolated static func estimate(gray: [Float], width: Int, height: Int) -> Estimate? {
        guard width > 16, height > 16, gray.count == width * height else { return nil }
        let steps = Int(limit * 10) * 2 + 1, middle = steps / 2
        var flatX: [Float] = [], flatY: [Float] = [], uprightX: [Float] = [], uprightY: [Float] = []
        // Scharr's 3 × 3: its direction is truer than Sobel's.
        var energy = [Float](repeating: 0, count: gray.count), across = [Bool](repeating: false, count: gray.count)
        var total = 0.0
        for y in 1..<height - 1 {
            let above = (y - 1) * width, row = y * width, below = (y + 1) * width
            for x in 1..<width - 1 {
                let a = gray[above + x - 1], b = gray[above + x], c = gray[above + x + 1]
                let d = gray[row + x - 1], f = gray[row + x + 1]
                let g = gray[below + x - 1], h = gray[below + x], i = gray[below + x + 1]
                let dx = 3 * (c - a) + 10 * (f - d) + 3 * (i - g)
                let dy = 3 * (g - a) + 10 * (h - b) + 3 * (i - c)
                let e = dx * dx + dy * dy
                energy[row + x] = e; total += Double(e)
                // The gradient lies across the edge: within the range (and a margin) of an axis, or it's neither.
                let ratio = min(abs(dx), abs(dy)) / max(abs(dx), abs(dy), 1e-6)
                across[row + x] = ratio < 0.5
            }
        }
        guard total > 0 else { return nil }
        // Only edges well over the picture's average count, and only their crest: one pixel wide.
        let floor = Float(4 * total / Double((width - 2) * (height - 2)))
        for y in 2..<height - 2 {
            for x in 2..<width - 2 {
                let index = y * width + x, e = energy[index]
                guard e > floor, across[index] else { continue }
                let a = gray[index - width - 1], c = gray[index - width + 1], g = gray[index + width - 1], i = gray[index + width + 1]
                let dx = 3 * (c - a) + 10 * (gray[index + 1] - gray[index - 1]) + 3 * (i - g)
                let dy = 3 * (g - a) + 10 * (gray[index + width] - gray[index - width]) + 3 * (i - c)
                if abs(dy) > abs(dx) {
                    let before = energy[index - width], after = energy[index + width]
                    guard e >= before, e > after else { continue }
                    // The crest between the pixels, so a line's place doesn't step with the pixel rows.
                    flatX.append(Float(x)); flatY.append(Float(y) + 0.5 * (before - after) / (before - 2 * e + after))
                } else {
                    let before = energy[index - 1], after = energy[index + 1]
                    guard e >= before, e > after else { continue }
                    uprightX.append(Float(x) + 0.5 * (before - after) / (before - 2 * e + after)); uprightY.append(Float(y))
                }
            }
        }
        let reach = Int((Double(width * width + height * height)).squareRoot()) + 4
        /// How well the points line up at each angle. `along`/`cross`: a line of the family leaning by θ
        /// clockwise keeps `cross · cos θ − along · sin θ` constant.
        func scores(along: [Float], cross: [Float]) -> [Double] {
            var scores = [Double](repeating: 0, count: steps)
            guard along.count > 40 else { return scores }
            var lines = [Float](repeating: 0, count: 2 * reach + 4)
            for step in 0..<steps {
                let theta = Double(step - middle) / 10 * .pi / 180
                let cosine = Float(cos(theta)), sine = Float(sin(theta))
                for index in lines.indices { lines[index] = 0 }
                for index in along.indices {
                    let place = cross[index] * cosine - along[index] * sine + Float(reach) + 1
                    // Spread smoothly over four lines, so the sum of squares doesn't favour angles where the
                    // points fall on whole lines (the pixel rows themselves, at no lean at all).
                    let low = Int(place)
                    let t = place - Float(low), u = 1 - t
                    lines[low - 1] += u * u * u / 6
                    lines[low] += (3 * t * t * t - 6 * t * t + 4) / 6
                    lines[low + 1] += (3 * u * u * u - 6 * u * u + 4) / 6
                    lines[low + 2] += t * t * t / 6
                }
                var sum = 0.0
                for count in lines where count > 0 { sum += Double(count * count) }
                scores[step] = sum
            }
            return scores
        }
        // Edges along the width: x runs along them, y across. Along the height: y along, and x across, which
        // a clockwise lean moves the other way.
        let flat = likely(scores(along: flatX, cross: flatY))
        let upright = likely(scores(along: uprightY, cross: uprightX.map { -$0 }))
        return choose(flat: peak(flat), upright: peak(upright), flatScores: flat, uprightScores: upright)
    }

    private nonisolated static func choose(flat: (angle: Double, strength: Double)?, upright: (angle: Double, strength: Double)?,
                                           flatScores: [Double], uprightScores: [Double]) -> Estimate? {
        switch (flat, upright) {
        case (nil, nil): return nil
        case (let found?, nil): return Estimate(lean: found.angle, strength: found.strength, source: .horizontals)
        case (nil, let found?): return Estimate(lean: found.angle, strength: found.strength, source: .verticals)
        case (let a?, let b?):
            // Both agree: the clearer one's angle (uprights that converge pull a mean aside), trusted the more.
            if abs(a.angle - b.angle) < 0.8 {
                return Estimate(lean: a.strength * 1.5 >= b.strength ? a.angle : b.angle, strength: a.strength + b.strength - 1, source: .both)
            }
            // They don't (a slanting wire, a wall that converges): the angle the two families like best together.
            let both = zip(relative(flatScores), relative(uprightScores)).map { $0 * $1 }
            if let joint = peak(both, trusted: 1.5) {
                return Estimate(lean: joint.angle, strength: joint.strength, source: .both)
            }
            return a.strength >= b.strength ? Estimate(lean: a.angle, strength: a.strength, source: .horizontals)
                : Estimate(lean: b.angle, strength: b.strength, source: .verticals)
        }
    }

    /// Scores over their own median, with what stands out weighed by how likely such a lean is: photographs are
    /// mostly off by a degree or two, and a long line far from level is more often a wire, a slope or a roof
    /// than the horizon.
    private nonisolated static func likely(_ scores: [Double]) -> [Double] {
        let middle = scores.count / 2
        return relative(scores).enumerated().map { index, score in
            let lean = Double(index - middle) / 10
            return 1 + max(score - 1, 0) * exp(-0.5 * (lean / usual) * (lean / usual))
        }
    }

    /// Scores over their own median.
    private nonisolated static func relative(_ scores: [Double]) -> [Double] {
        let median = scores.sorted()[scores.count / 2]
        return median > 0 ? scores.map { $0 / median } : scores
    }

    /// The angle the scores agree on (a tenth of a degree apart about the middle), if it stands out.
    private nonisolated static func peak(_ scores: [Double], trusted: Double = AutoStraighten.trusted) -> (angle: Double, strength: Double)? {
        let steps = scores.count, middle = steps / 2
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        let median = scores.sorted()[steps / 2]
        guard median > 0 else { return nil }
        let strength = scores[best] / median
        // At the very edge of the range the true peak may lie beyond it.
        guard strength >= trusted, best > 2, best < steps - 3 else { return nil }
        // The top of the parabola through the peak and its neighbours.
        let left = scores[best - 1], right = scores[best + 1], top = scores[best]
        let bend = left - 2 * top + right
        let shift = bend < 0 ? 0.5 * (left - right) / bend : 0
        return ((Double(best - middle) + min(max(shift, -0.5), 0.5)) / 10, strength)
    }

    /// The system's horizon detector, for photographs with no straight edge to go by (a seascape in haze).
    nonisolated static func horizon(_ image: CGImage) -> Estimate? {
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let found = request.results?.first else { return nil }
        // In radians; checked against photographs turned by a known angle.
        let lean = Double(found.angle) * 180 / .pi
        guard abs(lean) <= limit else { return nil }
        return Estimate(lean: lean, strength: Double(found.confidence), source: .horizon)
    }

    /// The picture in grey, `longSide` at most, rows from the top.
    nonisolated static func luminance(_ image: CGImage) -> (gray: [Float], width: Int, height: Int)? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height, 1)))
        let width = max(Int((Double(image.width) * scale).rounded()), 1), height = max(Int((Double(image.height) * scale).rounded()), 1)
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (bytes.map { Float($0) }, width, height)
    }

    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    /// What the canvas shows (a developed frame's surface, or an image), as an image to read.
    nonisolated static func image(from shown: AnyObject) -> CGImage? {
        if CFGetTypeID(shown) == CGImage.typeID { return (shown as! CGImage) }
        guard let surface = shown as? IOSurface else { return nil }
        let picture = CIImage(ioSurface: surface)
        let scale = min(1, CGFloat(longSide) / max(picture.extent.width, picture.extent.height, 1))
        let small = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
