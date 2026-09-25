import Foundation

/// Fixtures live in `Tests/Fixtures` at the repository root, outside the test target, so they are
/// read from the source checkout instead of being flattened into the test bundle.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tests/Fixtures", directoryHint: .isDirectory)

    static func url(_ path: String) -> URL { root.appending(path: path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    /// A writable copy, for code under test that writes caches next to its input.
    static func temporaryCopy(of path: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "owe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url(path), to: destination)
        return destination
    }
}
