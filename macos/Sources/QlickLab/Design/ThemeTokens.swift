// Qlick Lab — GPL-3.0-only.
// Generated from macos/design-tokens.json by DesignTokensTests: don't edit by hand.
// QLICK_UPDATE_GENERATED=1 swift test --filter DesignTokensTests writes it again.
import CoreGraphics

extension Theme {
    /// The colour tokens as sRGB 0xRRGGBB, for AppKit, the contrast tests and the hex lookups.
    enum Hex {
        /// The sheet the photograph lies on (canvas, grid).
        static let bg: UInt32 = 0x0a0a0b
        /// The inspector and the lab's surfaces, a shade lighter than the sheet; also the alert sheet.
        static let panel: UInt32 = 0x131314
        /// The film's black: the strip, the tray, the leader, the contact sheet.
        static let film: UInt32 = 0x000000
        /// Hairlines between sections and modules.
        static let line: UInt32 = 0x28282a
        /// Slider track, outlines, separators, outlined buttons. Only on things whose words or shape already say what they are.
        static let track: UInt32 = 0x444447
        /// The faintest words and marks: disabled hints, empty states.
        static let faint: UInt32 = 0x525252
        /// Values at their default, hints, secondary words, capital labels.
        static let dim: UInt32 = 0x8a8a8f
        /// Control labels.
        static let label: UInt32 = 0xb9b9be
        /// What's being read: names, changed values, the focus box.
        static let paper: UInt32 = 0xf0f0f0
        /// The lab's red, the pencil: the active, the selected, the main action. Never decoration. The sRGB value is the Display P3 red brought into sRGB.
        static let accent: UInt32 = 0xf8000a
        /// Errors and warnings, always as words.
        static let warn: UInt32 = 0xffa64d
        /// Words on the red.
        static let onAccent: UInt32 = 0xffffff
        /// A tile not yet developed.
        static let blank: UInt32 = 0x1a1a1c
        /// A raised surface: a disabled main button, a lifted card.
        static let raised: UInt32 = 0x1d1d1d
    }

    /// The colours that have a Display P3 value of their own, as (red, green, blue).
    enum P3 {
        static let accent: (CGFloat, CGFloat, CGFloat) = (0.89, 0.11, 0.14)
    }

    /// Corner radii, continuous, in points.
    enum Radius {
        /// A button, a tile, a settings row.
        static let control: CGFloat = 14
        /// A dialog.
        static let dialog: CGFloat = 22
        /// A floating panel.
        static let floating: CGFloat = 26
        /// A recipe's thumbnail, an icon button.
        static let thumbnail: CGFloat = 7
    }

    /// Motion: one spring, one quick ease-out.
    enum Motion {
        /// The spring's response, in seconds.
        static let springResponse: CGFloat = 0.34
        /// The spring's damping fraction: no bounce.
        static let springDamping: CGFloat = 0.86
        /// A quick ease-out, in seconds.
        static let quick: CGFloat = 0.16
    }

    /// The capital label (`CapsLabel`).
    enum Caps {
        /// A capital label's size, in points (medium weight).
        static let size: CGFloat = 11
        /// A capital label's letter spacing, times its size.
        static let tracking: CGFloat = 0.11
    }
}
