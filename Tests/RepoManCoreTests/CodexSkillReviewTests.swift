import XCTest
@testable import RepoManCore
final class CodexSkillReviewTests: XCTestCase {
    func testCodexReviewUsesGatewayAndRetainsModelReasoningAndSchema() async throws {
        let client = AgentBridgeClient(transport: { request in
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            XCTAssertNotEqual(request.url?.host, "openrouter.ai")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "codex/gpt-6.1-sol")
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
            XCTAssertNil(body["provider"])
            XCTAssertNotNil(body["response_format"])
            let answers: [String: Any] = ["rules": [
                "opening.identity": ["verdict": "uncertain", "reason": "Insufficient evidence", "evidenceDocument": "", "evidenceQuote": ""],
                "structure.concise": ["verdict": "uncertain", "reason": "Insufficient evidence", "evidenceDocument": "", "evidenceQuote": ""]]]
            let content = String(decoding: try JSONSerialization.data(withJSONObject: answers), as: UTF8.self)
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await client.evaluate(.init(contract: RepositoryReadmeChecks.contract(), documents: [.init(id: "README.md", text: "Synthetic evidence")], configuration: .init()), token: "")
        XCTAssertEqual(result.count, 2)
    }
}
