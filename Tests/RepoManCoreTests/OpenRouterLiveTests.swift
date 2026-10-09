import Foundation
import XCTest
@testable import RepoManCore
final class OpenRouterLiveTests: XCTestCase {
    func testGatewayReadinessWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["REPOMAN_RUN_AGENTBRIDGE_TESTS"] == "1" else {
            throw XCTSkip("Live gateway checks are opt-in.")
        }
        try await AgentBridgeClient().testConnection(token: ProcessInfo.processInfo.environment["AGENTBRIDGE_API_KEY"] ?? "")
    }
}
