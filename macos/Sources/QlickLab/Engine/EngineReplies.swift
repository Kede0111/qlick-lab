// Qlick Lab — GPL-3.0-only.
import Foundation

/// The engine's replies the lab reads most, typed: the keys of each are named once, here, instead of as strings
/// wherever a reply is read.
///
/// `init(_:)` reads a reply as the lab always has: a missing key, or one of another type, reads as 0, false, "" or
/// [] (`JSONValue`'s accessors), so the app behaves the same whatever the helper says. `Decodable` is the strict
/// reading: the keys the helper always sends must be there with their types. The contract tests decode the real
/// helper's replies that way (`EngineContractTests`), so a key renamed on one side fails a test, not the app.
protocol EngineReply: Decodable {
    init(_ json: JSONValue)
    /// The keys every such reply has, and their kinds.
    static var required: [String: JSONValue.Kind] { get }
}

extension EngineReply {
    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        for (key, kind) in Self.required where json[key].kind != kind {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "\(Self.self): \"\(key)\" is \(json[key].kind), not \(kind)"))
        }
        self.init(json)
    }
}

extension JSONValue {
    enum Kind: String, Sendable { case object, array, string, number, bool, null }
    var kind: Kind {
        switch self {
        case .object: .object
        case .array: .array
        case .string: .string
        case .number: .number
        case .bool: .bool
        case .null: .null
        }
    }
}

/// `render`'s reply (`Command::Render` in crates/spektrafilm-native/src/main.rs).
struct RenderReply: EngineReply, Equatable, Sendable {
    /// The preview buffer's pixels.
    var width: Double, height: Double
    /// The developed frame, before the display's limit.
    var outputWidth: Double, outputHeight: Double
    /// The photograph at the preview's size, and at its working size.
    var photoWidth: Double, photoHeight: Double
    var workingWidth: Double, workingHeight: Double
    /// The source as read, whole even from a reduced read.
    var sourceWidth: Double, sourceHeight: Double
    var raw: Bool
    var exportResolution: Bool
    var lensCorrectionSupported: Bool
    /// A smaller source answered while a larger one is read.
    var refining: Bool
    var backend: String
    var displayColorSpace: String
    var elapsedMs: Double
    /// The part of the frame developed (left, top, width, height), when only a part was; empty otherwise.
    var region: [Double]
    var filmHistogram: JSONValue
    var inputColour: JSONValue

    init(_ json: JSONValue) {
        width = json["width"].double; height = json["height"].double
        outputWidth = json["output_width"].double; outputHeight = json["output_height"].double
        photoWidth = json["photo_width"].double; photoHeight = json["photo_height"].double
        workingWidth = json["working_width"].double; workingHeight = json["working_height"].double
        sourceWidth = json["source_width"].double; sourceHeight = json["source_height"].double
        raw = json["raw"].bool
        exportResolution = json["export_resolution"].bool
        lensCorrectionSupported = json["lens_correction_supported"].bool
        refining = json["refining"].bool
        backend = json["backend"].string
        displayColorSpace = json["display_color_space"].string
        elapsedMs = json["elapsed_ms"].double
        region = json["region"].array.map(\.double)
        filmHistogram = json["film_histogram"]
        inputColour = json["input_colour"]
    }

    static let required: [String: JSONValue.Kind] = [
        "width": .number, "height": .number, "output_width": .number, "output_height": .number,
        "photo_width": .number, "photo_height": .number, "working_width": .number, "working_height": .number,
        "source_width": .number, "source_height": .number, "raw": .bool, "export_resolution": .bool,
        "lens_correction_supported": .bool, "refining": .bool, "backend": .string, "display_color_space": .string,
        "elapsed_ms": .number,
    ]
}

/// `thumbnail`'s reply: a developed thumbnail, or with `decode_only` the photograph's size alone.
struct ThumbnailReply: EngineReply, Equatable, Sendable {
    /// The thumbnail buffer's pixels; 0 for a decode alone.
    var width: Double, height: Double
    var displayColorSpace: String
    /// The photograph's whole size, even from a reduced read.
    var sourceWidth: Double, sourceHeight: Double
    /// Whether the photograph is a RAW: said by a decode alone.
    var raw: Bool
    /// What the RAW says its preview is in, when asked (`preview_colour_space`): a name or null.
    var previewColourSpace: JSONValue

    var sourceSize: CGSize { CGSize(width: sourceWidth, height: sourceHeight) }

    init(_ json: JSONValue) {
        width = json["width"].double; height = json["height"].double
        displayColorSpace = json["display_color_space"].string
        sourceWidth = json["source_width"].double; sourceHeight = json["source_height"].double
        raw = json["raw"].bool
        previewColourSpace = json["preview_colour_space"]
    }

    static let required: [String: JSONValue.Kind] = ["source_width": .number, "source_height": .number]
}
