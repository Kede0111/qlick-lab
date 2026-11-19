import XCTest
@testable import QlickLab

/// The app and the engine's helper name the same commands: `EngineCommand` against
/// crates/spektrafilm-native/commands.txt, which the helper's own test reads too.
final class EngineContractTests: XCTestCase {
    func testCommandsMatchTheSharedList() throws {
        let list = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("crates/spektrafilm-native/commands.txt")
        let names = try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(EngineCommand.allCases.map(\.rawValue), names)
    }
}
