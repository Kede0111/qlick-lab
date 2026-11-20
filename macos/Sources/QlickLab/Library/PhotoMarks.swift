import SwiftUI

/// A thumbnail's marks in the strip and the grid (§4.4, round 7): stars drawn
/// by hand at the bottom left (`HandStar`, round 22), a reject's hand-drawn X from corner to corner
/// (`CrossMark`), and the yellow dot of an edited photograph at the top
/// right. Each is its own shape, never only a colour, in cream with a dark
/// halo so it reads on a bright sky. Unrated, unflagged, unedited
/// photographs show none. Lay it over the picture. A pick's box (round 20)
/// reaches past the picture, so the grid and the strip draw it in a layer
/// above the thumbnails (`BoxInk`).
struct PhotoMarks: View {
    let summary: LibrarySummary
    /// The file's name: it seeds the reject's cross and the stars, so
    /// each is drawn a little differently, and the same way every time.
    let name: String
    /// Qlick Lab: the stack it stands for or tops (`ProjectStore.stackBadge`): how many, and whether it's open.
    var stack: (count: Int, open: Bool)? = nil

    var body: some View {
        ZStack {
            if summary.flag == .reject {
                CrossMark(name: name)
            }
            if summary.rating > 0 {
                HStack(spacing: HandStar.gap) {
                    ForEach(0..<min(summary.rating, 5), id: \.self) { index in
                        HandStarShape(name: name, index: index)
                            .fill(Theme.paper)
                            .frame(width: HandStar.size, height: HandStar.size)
                    }
                }
                .padding([.leading, .bottom], 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The halo: drop-shadow 1.5 pt black at 0.95, then 4 pt at 0.45.
        .shadow(color: .black.opacity(0.95), radius: 0.75)
        .shadow(color: .black.opacity(0.45), radius: 2)
        .overlay(alignment: .topLeading) {
            // Qlick Lab: the colour label, a round sticker at the top left.
            if let label = summary.label { LabelDot(label: label, size: 10).padding([.top, .leading], 9) }
        }
        .overlay(alignment: .topTrailing) {
            // The same dot that marks edits in the panel; no halo.
            if summary.edited {
                Circle().fill(Theme.accent).frame(width: 7, height: 7).padding([.top, .trailing], 11)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let stack { StackBadge(count: stack.count, open: stack.open).padding([.bottom, .trailing], 7) }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The picture's opacity under the marks: rejects are greyed, more so
    /// in the strip (0.22, or 0.5 for the current frame) than the grid (0.4).
    static func rejectOpacity(inStrip: Bool, current: Bool) -> Double {
        inStrip ? (current ? 0.5 : 0.22) : 0.4
    }

    static func help(_ name: String, summary: LibrarySummary, readOnly: Bool) -> String {
        var lines = [summary.words.title.isEmpty ? name : "\(summary.words.title) (\(name))"]
        if let label = summary.label { lines.append("\(LabelNames.name(label)) label") }
        if !summary.words.keywords.isEmpty { lines.append(summary.words.keywords.joined(separator: ", ")) }
        if let problem = summary.problem { lines.append(problem) }
        if readOnly { lines.append("Ratings and edits can’t be saved in this folder: it’s read-only.") }
        return lines.joined(separator: "\n")
    }

    static func accessibilityLabel(_ name: String, summary: LibrarySummary) -> String {
        var parts = [name]
        if summary.rating > 0 { parts.append(summary.rating == 1 ? "1 star" : "\(summary.rating) stars") }
        if let flag = summary.flag { parts.append(flag == .pick ? "Pick" : "Rejected") }
        if let label = summary.label { parts.append("\(LabelNames.name(label)) label") }
        if !summary.words.keywords.isEmpty { parts.append("Keywords: " + summary.words.keywords.joined(separator: ", ")) }
        if summary.edited { parts.append("Edited") }
        return parts.joined(separator: ", ")
    }
}

/// A stack's badge on the photograph standing for it, in every view of the photographs: two cards and how many.
/// Filled while the stack is closed, outlined once it's open.
struct StackBadge: View {
    let count: Int
    let open: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack").font(.system(size: 8.5, weight: .semibold))
            Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(open ? Theme.paper : Color.black)
        .padding(.horizontal, 5).frame(height: 16)
        .background(Capsule().fill(open ? Color.black.opacity(0.6) : Theme.paper))
        .overlay(Capsule().strokeBorder(open ? Theme.paper.opacity(0.7) : Color.black.opacity(0.35), lineWidth: 1))
        .help(open ? "A stack of \(count), open" : "A stack of \(count) photographs")
    }
}
