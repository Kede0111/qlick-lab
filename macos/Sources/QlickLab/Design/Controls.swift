// Qlick Lab — GPL-3.0-only. The controls shared with QLab: capital labels, Liquid Glass, the red main button,
// pills, icon buttons, segmented choices and the lab's mark. Their tokens are in Theme.swift.
import AppKit
import SwiftUI

/// QLab's small capital label.
struct CapsLabel: View {
    let text: String
    var size: CGFloat = 10.5
    var color: Color = Theme.dim
    init(_ text: String, size: CGFloat = 10.5, color: Color = Theme.dim) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Theme.caps(size)).tracking(size * 0.11).foregroundStyle(color).lineLimit(1)
    }
}

// MARK: Liquid Glass

extension View {
    /// A floating Liquid Glass surface (macOS 26+); a dark material with a hairline edge before that.
    /// Used for what floats over photographs or the sheet: bars, HUDs, panels. Never for the photographs themselves.
    @ViewBuilder func glass(_ shape: some InsettableShape = Capsule(), interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }

    /// Groups neighbouring glass shapes so they blend as one material (macOS 26+).
    @ViewBuilder func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

/// The one red button of a screen: its main action.
struct QPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caps(12, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(enabled ? Theme.accent : Theme.raised))
            .foregroundStyle(enabled ? Color.white : Theme.dim)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(Capsule())
    }
}

/// Thin pill for secondary actions; `active` fills it white, as QLab's.
struct QPillButtonStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caps(12))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(active ? Theme.paper : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .foregroundStyle(active ? Theme.film : Theme.paper)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// A square icon button for bars.
struct QIconButton: View {
    let symbol: String
    var help: String
    var active = false
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovered ? Theme.paper : Color(white: 0.72)))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(active ? 0.1 : hovered ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Two- or three-way choice: the selected segment is white on a faint track (red is kept for marks and actions).
struct QSegmented<T: Hashable>: View {
    let options: [(value: T, title: String, help: String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).font(Theme.caps(11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.film : Color(white: 0.75))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(on ? Theme.paper : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .animation(Theme.quick, value: selection)
    }
}

/// The app's mark: a grease-pencil ring, the gesture the whole lab is built on.
struct QMark: View {
    var size: CGFloat = 18
    /// The lab's logo (`LogoMark` in the asset catalogue). A build without the compiled catalogue (`swift run`)
    /// draws the red pencil ring instead.
    private static let logo: NSImage? = NSImage(named: "LogoMark")

    var body: some View {
        if let logo = Self.logo {
            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            ring
        }
    }

    private var ring: some View {
        Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
            for stroke in GreasePencil.ring(in: rect, seed: "Qlick Lab", weight: canvas.width / 9) {
                context.fill(Path(stroke.path()), with: .color(Theme.accent.opacity(stroke.opacity)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
