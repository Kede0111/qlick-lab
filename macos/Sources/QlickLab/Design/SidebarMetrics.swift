// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The sidebar's one set of measures, for the Library, the Lab and Print alike: compact, precise, discreet. Entries
/// in 13 pt (Medium when selected, never bold), small capital headings, 30 pt rows, a fixed icon column, a 0.5 pt
/// hairline between groups, red only on what's open.
enum SidebarMetrics {
    static let width: CGFloat = 220
    static let minimumWidth: CGFloat = 200

    /// Entries and list rows.
    static let entrySize: CGFloat = 13
    static let rowHeight: CGFloat = 30
    /// From the row's edge to the icon column.
    static let inset: CGFloat = 10
    /// The icon column, the same for every row, so the words line up.
    static let iconColumn: CGFloat = 20
    /// `LabSymbol` points: about 15 pt drawn, thin.
    static let iconPoints: CGFloat = 11
    /// From the icon column to the word.
    static let gap: CGFloat = 8
    /// Where the words start, from the row's edge.
    static var textLeading: CGFloat { inset + iconColumn + gap }

    /// Section headings: small capitals, spaced, dimmed.
    static let headingSize: CGFloat = 11
    static let headingTracking: CGFloat = 1.5
    static let headingTop: CGFloat = 18
    static let headingBottom: CGFloat = 6

    /// The selected row: a rounded rectangle, white at 8 %.
    static let radius: CGFloat = 7
    static let selectedFill: Double = 0.08
    static let hoverFill: Double = 0.04

    /// Between groups: a 0.5 pt hairline, white at 8 %, inset to the words.
    static let hairline: CGFloat = 0.5
    static let hairlineOpacity: Double = 0.08
    static let hairlinePadding: CGFloat = 11

    static func font(selected: Bool) -> Font { .system(size: entrySize, weight: selected ? .medium : .regular) }
    static func text(selected: Bool, dim: Bool = false) -> Color { selected ? Theme.paper : dim ? Theme.dim : Color(white: 0.8) }
    static func icon(selected: Bool, dim: Bool = false) -> Color { selected ? Theme.accent : dim ? Theme.faint : Theme.dim }
}

/// An entry of the sidebar (a room, the Archives, the Boxes): its thin icon in the icon column, its word, a count or a
/// note at the end, and an accessory (a +); open, on the rounded highlight with its icon in red.
struct SidebarEntry<Accessory: View>: View {
    let symbol: String
    let title: String
    var on = false
    var trailing: String? = nil
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovered = false

    init(symbol: String, title: String, on: Bool = false, trailing: String? = nil, action: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.on = on; self.trailing = trailing; self.action = action; self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: SidebarMetrics.gap) {
                    LabSymbol(symbol: symbol, points: SidebarMetrics.iconPoints, weight: .light, color: SidebarMetrics.icon(selected: on))
                        .frame(width: SidebarMetrics.iconColumn)
                    Text(title).font(SidebarMetrics.font(selected: on)).foregroundStyle(SidebarMetrics.text(selected: on)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let trailing {
                        Text(trailing).font(Theme.value(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    }
                }
                .padding(.leading, SidebarMetrics.inset).padding(.trailing, 6)
                .frame(height: SidebarMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            accessory().padding(.trailing, 4)
        }
        .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
            .fill(Color.white.opacity(on ? SidebarMetrics.selectedFill : hovered ? SidebarMetrics.hoverFill : 0)))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A section's heading: small capitals, spaced, dimmed (LIBRARY, LAB, PRINT, BOXES), with an optional accessory.
struct SidebarSectionHeading<Accessory: View>: View {
    let title: String
    var first = false
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, first: Bool = false, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title; self.first = first; self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased()).font(.system(size: SidebarMetrics.headingSize, weight: .semibold))
                .tracking(SidebarMetrics.headingTracking).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 4)
            accessory().padding(.trailing, 4)
        }
        .padding(.leading, SidebarMetrics.inset)
        .padding(.top, first ? 6 : SidebarMetrics.headingTop).padding(.bottom, SidebarMetrics.headingBottom)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The hairline between the sidebar's groups, inset to the words.
struct SidebarHairline: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(SidebarMetrics.hairlineOpacity)).frame(height: SidebarMetrics.hairline)
            .padding(.leading, SidebarMetrics.textLeading).padding(.trailing, 4)
            .padding(.vertical, SidebarMetrics.hairlinePadding)
            .accessibilityHidden(true)
    }
}

/// The + beside an entry or a heading of the sidebar.
struct SidebarAddButton: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.dim)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}
