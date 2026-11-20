// Qlick Lab — GPL-3.0-only.
import CoreGraphics
import Foundation

/// The red grease pencil of the contact sheet: a ring drawn round a picked frame and a cross over a rejected one.
///
/// Every mark is generated from a seed (the photograph's file name), so a frame always carries the same drawing,
/// on screen at any size and in print, and no two frames carry quite the same one. A stroke is a centre line with
/// a width at each point (the pencil's pressure); it is filled as an outline, so it can be drawn part-way for the
/// short animation of the gesture and stays vector in a PDF.
///
/// The hash and random generator are the reject cross's (`RejectCross`), so both families of marks vary alike.
enum GreasePencil {
    struct Stroke {
        var points: [CGPoint]
        var widths: [CGFloat]
        var opacity: Double

        /// The stroke's outline up to `progress` (0…1) of its length.
        func path(progress: CGFloat = 1) -> CGPath {
            let path = CGMutablePath()
            let count = max(2, Int((CGFloat(points.count - 1) * min(max(progress, 0), 1)).rounded()) + 1)
            guard points.count >= 2, count >= 2 else { return path }
            var left: [CGPoint] = [], right: [CGPoint] = []
            left.reserveCapacity(count); right.reserveCapacity(count)
            for i in 0..<count {
                let p = points[i], q = points[max(0, i - 1)], s = points[min(points.count - 1, i + 1)]
                let tx = s.x - q.x, ty = s.y - q.y
                let length = max(hypot(tx, ty), 0.0001), half = widths[i] / 2
                left.append(CGPoint(x: p.x - ty / length * half, y: p.y + tx / length * half))
                right.append(CGPoint(x: p.x + ty / length * half, y: p.y - tx / length * half))
            }
            path.addLines(between: left + cap(points[count - 1], widths[count - 1], from: left[count - 1], to: right[count - 1])
                          + right.reversed() + cap(points[0], widths[0], from: right[0], to: left[0]))
            path.closeSubpath()
            return path
        }

        private func cap(_ centre: CGPoint, _ width: CGFloat, from: CGPoint, to: CGPoint) -> [CGPoint] {
            let a0 = atan2(from.y - centre.y, from.x - centre.x)
            var a1 = atan2(to.y - centre.y, to.x - centre.x)
            while a1 < a0 { a1 += 2 * .pi }
            if a1 - a0 > 3.3 { a1 -= 2 * .pi }
            return (1..<6).map { k in
                let angle = a0 + (a1 - a0) * CGFloat(k) / 6
                return CGPoint(x: centre.x + cos(angle) * width / 2, y: centre.y + sin(angle) * width / 2)
            }
        }

        var bounds: CGRect {
            guard let first = points.first else { return .null }
            var rect = CGRect(origin: first, size: .zero)
            for p in points { rect = rect.union(CGRect(origin: p, size: .zero)) }
            let pad = (widths.max() ?? 0) / 2 + 1
            return rect.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// The pencil's weight for a frame this wide, in the same units as the frame.
    static func weight(forFrameWidth width: CGFloat) -> CGFloat { min(max(width / 62, 1.5), 4.8) }

    /// How far a ring reaches past its frame on each side, as a share of the frame's size.
    static let ringOutset = CGSize(width: 0.05, height: 0.19)

    // MARK: The ring round a pick

    /// A ring round `rect`: a slightly tilted, uneven ellipse that starts near the top, goes round once and runs past
    /// its start without quite meeting it, as a hand closes a circle. About one in five is gone round twice.
    static func ring(in rect: CGRect, seed: String, weight: CGFloat) -> [Stroke] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var random = RejectCross.Random(seed: RejectCross.hash("ring|" + seed))
        func span(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * random.next() }
        let rx = rect.width / 2 * span(0.97, 1.04), ry = rect.height / 2 * span(0.96, 1.05)
        let centre = CGPoint(x: rect.midX + span(-0.012, 0.012) * rect.width, y: rect.midY + span(-0.015, 0.015) * rect.height)
        let tilt = span(-0.07, 0.07)
        // Starts up and to the left or right of the top, as most hands do; either way round.
        let start = -CGFloat.pi / 2 + span(-0.9, 0.5)
        let direction: CGFloat = random.next() < 0.78 ? 1 : -1
        let twice = random.next() < 0.2
        let sweep = (twice ? 2 : 1) * 2 * CGFloat.pi + span(0.25, 0.75)
        // The hand drifts as it goes round, so the end passes inside or outside the start.
        let drift = span(0.035, 0.085) * (random.next() < 0.6 ? -1 : 1)
        // Squarer than an ellipse: a hand follows the frame's corners a little.
        let squareness = span(2.25, 2.9)
        let wobbleAmp = span(0.006, 0.014), wobbleFreq = span(1.6, 3.2), wobblePhase = span(0, 6.28)
        let lobeAmp = span(0.01, 0.03), lobePhase = span(0, 6.28)
        let pressureFreq = span(0.8, 1.9), pressurePhase = span(0, 6.28)
        let scale = span(0.92, 1.12)
        let n = twice ? 200 : 120
        var points: [CGPoint] = [], widths: [CGFloat] = []
        points.reserveCapacity(n + 1); widths.reserveCapacity(n + 1)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let angle = start + direction * sweep * t
            let radius = 1 + drift * (t - 0.5) + wobbleAmp * sin(wobbleFreq * angle + wobblePhase) + lobeAmp * sin(2 * angle + lobePhase)
            // A superellipse point at this angle.
            let c = cos(angle), s = sin(angle)
            let ex = 2 / squareness
            let x = rx * radius * (c < 0 ? -1 : 1) * pow(abs(c), ex), y = ry * radius * (s < 0 ? -1 : 1) * pow(abs(s), ex)
            points.append(CGPoint(x: centre.x + x * cos(tilt) - y * sin(tilt), y: centre.y + x * sin(tilt) + y * cos(tilt)))
            // Pressure: lands, settles, varies a little, and lifts off in a taper.
            let land = RejectCross.smooth(min(t / 0.05, 1)), lift = RejectCross.smooth(min((1 - t) / 0.09, 1))
            let pressure = 0.86 + 0.2 * sin(pressureFreq * angle + pressurePhase)
            widths.append(weight * scale * pressure * (0.45 + 0.55 * land) * (0.18 + 0.82 * lift))
        }
        var strokes = [Stroke(points: points, widths: widths, opacity: 0.93)]
        // The wax's uneven lay: a thinner, lighter pass riding inside the stroke.
        let offset = weight * span(0.12, 0.26)
        let streak = points.enumerated().map { index, p -> CGPoint in
            let q = points[max(0, index - 1)], s = points[min(n, index + 1)]
            let tx = s.x - q.x, ty = s.y - q.y, length = max(hypot(tx, ty), 0.0001)
            return CGPoint(x: p.x - ty / length * offset, y: p.y + tx / length * offset)
        }
        strokes.append(Stroke(points: streak, widths: widths.map { $0 * 0.34 }, opacity: 0.28))
        return strokes
    }

    /// The rectangle a frame's ring is drawn in.
    static func ringRect(around frame: CGRect) -> CGRect {
        frame.insetBy(dx: -frame.width * ringOutset.width, dy: -frame.height * ringOutset.height)
    }

    // MARK: The box round the current frame

    /// A box round `rect`, drawn in one go from near the top left: four sides that bow a little, corners turned
    /// rather than met, and an end that runs past the start, as a hand boxes a frame on a contact sheet.
    static func box(in rect: CGRect, seed: String, weight: CGFloat) -> [Stroke] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var random = RejectCross.Random(seed: RejectCross.hash("box|" + seed))
        func span(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * random.next() }
        let j = min(rect.width, rect.height) * 0.012 + 0.6
        func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + span(-j, j), y: y + span(-j, j)) }
        let corners = [corner(rect.minX, rect.minY), corner(rect.maxX, rect.minY), corner(rect.maxX, rect.maxY), corner(rect.minX, rect.maxY)]
        let radius = min(rect.width, rect.height) * span(0.02, 0.045) + 1.5
        let overshoot = span(0.03, 0.09) * rect.width
        var points: [CGPoint] = [], widths: [CGFloat] = []
        let perSide = 26
        for side in 0..<4 {
            let a = corners[side], b = corners[(side + 1) % 4]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let bow = length * span(-0.006, 0.006), phase = span(0, 6.28)
            // The first side starts a little along; the last runs past the first corner.
            let from: CGFloat = side == 0 ? span(0.02, 0.08) * length : radius
            let to: CGFloat = side == 3 ? length + overshoot * 0.5 : length - radius
            for i in 0...perSide {
                let d = from + (to - from) * CGFloat(i) / CGFloat(perSide), t = d / length
                let wave = sin(.pi * min(max(t, 0), 1)) * bow + sin(t * 9 + phase) * weight * 0.07
                points.append(CGPoint(x: a.x + ux * d - uy * wave, y: a.y + uy * d + ux * wave))
            }
        }
        let n = points.count - 1
        let scale = span(0.92, 1.1), frequency = span(2, 5), phase = span(0, 6.28)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let land = RejectCross.smooth(min(t / 0.03, 1)), lift = RejectCross.smooth(min((1 - t) / 0.05, 1))
            widths.append(weight * scale * (0.9 + 0.14 * sin(frequency * t * 6.28 + phase)) * (0.5 + 0.5 * land) * (0.2 + 0.8 * lift))
        }
        return [Stroke(points: points, widths: widths, opacity: 0.96)]
    }

    // MARK: The cross over a reject

    /// A cross over `rect`: two fast diagonals, each starting short of one corner and running past the other,
    /// bowed and a little unsteady. The reject cross is drawn with the same kind of outline (`RejectCross.outline`).
    static func cross(in rect: CGRect, seed: String, weight: CGFloat) -> [Stroke] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var random = RejectCross.Random(seed: RejectCross.hash("cross|" + seed))
        func span(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * random.next() }
        let inset = min(rect.width, rect.height) * 0.1
        let box = rect.insetBy(dx: inset * 1.5, dy: inset * 0.55)
        let diagonals = [(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)),
                         (CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY))]
        var strokes: [Stroke] = []
        for (k, (a, b)) in diagonals.enumerated() {
            let length = hypot(b.x - a.x, b.y - a.y)
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let jitter = length * 0.02
            let from = CGPoint(x: a.x + ux * length * span(0.0, 0.07) + span(-jitter, jitter), y: a.y + uy * length * span(0.0, 0.07) + span(-jitter, jitter))
            let to = CGPoint(x: b.x + ux * length * span(0.0, 0.08) + span(-jitter, jitter), y: b.y + uy * length * span(0.0, 0.08) + span(-jitter, jitter))
            let bow = length * span(0.012, 0.045) * (random.next() < 0.5 ? -1 : 1)
            let nx = -uy, ny = ux
            let control = CGPoint(x: (from.x + to.x) / 2 + nx * bow * 2, y: (from.y + to.y) / 2 + ny * bow * 2)
            let wobble = weight * span(0.1, 0.3), frequency = span(1.2, 2.8), phase = span(0, 6.28)
            let scale = (k == 1 ? span(0.84, 1.0) : span(0.95, 1.15))
            let n = 56
            var points: [CGPoint] = [], widths: [CGFloat] = []
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n), u = 1 - t
                let wave = sin(.pi * t) * wobble * sin(2 * .pi * frequency * t + phase)
                points.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x + nx * wave,
                                      y: u * u * from.y + 2 * u * t * control.y + t * t * to.y + ny * wave))
                // Lands hard, thins along the way and ends in a flick.
                let land = RejectCross.smooth(min(t / 0.08, 1)), lift = RejectCross.smooth(min((1 - t) / 0.3, 1))
                widths.append(weight * scale * (0.7 + 0.5 * land) * (0.12 + 0.88 * lift) * (1.08 - 0.2 * t))
            }
            strokes.append(Stroke(points: points, widths: widths, opacity: k == 0 ? 0.93 : 0.88))
            let offset = weight * span(0.14, 0.24)
            strokes.append(Stroke(points: points.map { CGPoint(x: $0.x + nx * offset, y: $0.y + ny * offset) }, widths: widths.map { $0 * 0.32 }, opacity: 0.26))
        }
        return strokes
    }
}
