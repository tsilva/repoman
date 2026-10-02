import Foundation
import XCTest
@testable import RepoManCore

final class OpenRouterLiveTests: XCTestCase {
    func testTestKeyAuthenticates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REPOMAN_RUN_OPENROUTER_TESTS"] == "1" else {
            throw XCTSkip("Live OpenRouter tests are opt-in; normal tests use no real key.")
        }
        let token: String
        if let configured = environment["OPENROUTER_TEST_API_KEY"] {
            token = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let keyFile = root.appendingPathComponent(".openrouter-test-key")
            guard FileManager.default.fileExists(atPath: keyFile.path) else {
                throw XCTSkip("Set OPENROUTER_TEST_API_KEY or run Tools/setup-openrouter-test-key.sh.")
            }
            let handle = try FileHandle(forReadingFrom: keyFile)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 514) ?? Data()
            guard data.count <= 513, let value = String(data: data, encoding: .utf8) else {
                throw RepairError.blocked("The OpenRouter test key file is invalid.")
            }
            token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.hasPrefix("sk-or-"), token.count <= 512, !token.contains(where: { $0.isWhitespace }) else {
            throw RepairError.blocked("Configure a valid OpenRouter test key.")
        }
        // GET /key checks authentication only. It never generates tokens or submits repository content.
        try await OpenRouterClient().testConnection(token: token)
    }
}
