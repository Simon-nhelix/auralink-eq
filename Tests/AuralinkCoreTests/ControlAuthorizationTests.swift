import XCTest
@testable import AuralinkCore

final class ControlAuthorizationTests: XCTestCase {
    func testCreatesAndReusesPrivateTokenFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-control-auth-\(UUID().uuidString)", isDirectory: true)
        let tokenFile = root.appendingPathComponent("control-token")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ControlAuthorization.loadOrCreateToken(environment: [:], fileURL: tokenFile)
        let second = try ControlAuthorization.loadOrCreateToken(environment: [:], fileURL: tokenFile)

        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.utf8.count, ControlAuthorization.minimumTokenLength)
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEnvironmentTokenTakesPrecedence() throws {
        let token = String(repeating: "a", count: 64)
        let resolved = try ControlAuthorization.loadOrCreateToken(
            environment: [ControlAuthorization.tokenEnvironmentVariable: token],
            fileURL: URL(fileURLWithPath: "/path/that/must/not/be/read")
        )
        XCTAssertEqual(resolved, token)
    }

    func testAuthorizationRequiresMatchingBearerToken() {
        let token = String(repeating: "b", count: 64)
        XCTAssertTrue(ControlAuthorization.isAuthorized(
            headers: ["Authorization": "Bearer \(token)"],
            token: token
        ))
        XCTAssertFalse(ControlAuthorization.isAuthorized(headers: [:], token: token))
        XCTAssertFalse(ControlAuthorization.isAuthorized(
            headers: ["authorization": "Bearer \(String(repeating: "c", count: 64))"],
            token: token
        ))
    }

    func testRejectsShortOrWhitespaceTokens() {
        XCTAssertNil(ControlAuthorization.normalizedToken("short"))
        XCTAssertNil(ControlAuthorization.normalizedToken(String(repeating: "a", count: 31) + " "))
        XCTAssertNil(ControlAuthorization.normalizedToken(String(repeating: "한", count: 32)))
        XCTAssertNotNil(ControlAuthorization.normalizedToken(String(repeating: "z", count: 32)))
    }
}
