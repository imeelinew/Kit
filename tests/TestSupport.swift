import Foundation

@MainActor
enum TestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private(set) static var assertions = 0

    static func expect(
        _ condition: @autoclosure () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        assertions += 1
        guard condition() else {
            throw Failure(description: "\(file):\(line): \(message)")
        }
    }

    static func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-suite-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    static func eventually(
        _ message: String, timeout: Duration = .seconds(10),
        until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(condition(), message)
    }
}
