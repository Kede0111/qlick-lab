// Qlick Lab — GPL-3.0-only.
// Written from `spektrafilm-io::border::geometry` by the test `border_geometry_swift_is_current`:
// don't edit it; change the Rust and run `QLICK_UPDATE_GENERATED=1 cargo test -p spektrafilm-io border_geometry`.

/// The border's numbers, the same the exporter uses.
enum BorderGeometry {
    static let matWidth: Double = 0.03
    static let keylineWidth: Double = 0.004
    static let filmInset: Double = 0.003
    static let filmInsetMin: Double = 1
    static let filmCorner: Double = 0.025
    static let filmCornerMin: Double = 2
    static let instagramFilmMargin: Double = 0.03
    static let fullFrameRatio: Double = 1.5
    static let halfFrameRatio: Double = 1.3333333333333333
    static let frameRatioTolerance: Double = 0.01
}
