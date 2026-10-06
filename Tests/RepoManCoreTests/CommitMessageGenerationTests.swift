import Foundation
import XCTest
@testable import RepoManCore

final class CommitMessageGenerationTests: XCTestCase {
    private func fixture(_ mode: String = "success", timeout: TimeInterval = 5) throws -> (URL, CodexCommitMessageGenerator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Commit fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("codex")
        try Self.script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        return (root, CodexCommitMessageGenerator(executable: { binary.path },
            storage: CodexStorage(homeDirectory: root.appendingPathComponent("codex-home")), timeout: timeout))
    }

    private func requests(_ root: URL) throws -> [JSONValue] {
        try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    func testDraftPinsLowReasoningAndUsesPrivateLoginWithReadOnlyEphemeralContext() async throws {
        let (root, generator) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = try await generator.generate(context: "SELECTED_DIFF_ONLY")
        XCTAssertEqual(draft, "Add native Git sync\n\nReview selected files before committing.")
        let messages = try requests(root)
        XCTAssertEqual(messages.compactMap { $0["method"].string }, ["initialize", "account/read", "thread/start", "turn/start"])
        let start = try XCTUnwrap(messages.first { $0["method"].string == "thread/start" })["params"]
        XCTAssertEqual(start["model"].string, "gpt-6.1-sol")
        XCTAssertEqual(start["config"]["model_reasoning_effort"].string, "low")
        XCTAssertTrue(start["permissions"].string?.hasPrefix("repoman-commit-") == true)
        XCTAssertEqual(start["sandbox"], .null, "Named profiles cannot be combined with the legacy sandbox parameter")
        XCTAssertEqual(start["ephemeral"].bool, true)
        XCTAssertEqual(start["allowProviderModelFallback"].bool, false)
        XCTAssertEqual(start["config"]["features.shell_tool"].bool, false)
        XCTAssertEqual(start["config"]["features.apps"].bool, false)
        XCTAssertEqual(start["config"]["features.multi_agent"].bool, false)
        XCTAssertEqual(start["config"]["features.hooks"].bool, false)
        XCTAssertTrue(start["baseInstructions"].string?.contains("untrusted evidence") == true)
        let turn = try XCTUnwrap(messages.last)["params"]
        XCTAssertEqual(turn["effort"].string, "low")
        XCTAssertEqual(turn["model"].string, "gpt-6.1-sol")
        XCTAssertEqual(turn["input"].array.first?["text"].string, "SELECTED_DIFF_ONLY")
        XCTAssertEqual(turn["permissions"].string, start["permissions"].string)
        XCTAssertEqual(turn["sandboxPolicy"], .null)
        XCTAssertEqual(turn["outputSchema"]["required"].array, [.string("message")])
        let cwd = try XCTUnwrap(start["cwd"].string)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "Temporary drafting directory must be removed")
        XCTAssertEqual(CodexAgent.reasoningEffort, "high", "Repairs keep high reasoning")
    }

    func testUnsupportedModelReasoningOrSandboxFailsBeforeInference() async throws {
        for mode in ["wrong-model", "high", "writable", "persistent", "wrong-profile"] {
            let (root, generator) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await generator.generate(context: "selected changes"); XCTFail(mode) }
            catch { XCTAssertTrue(error.localizedDescription.contains("low reasoning"), error.localizedDescription) }
            XCTAssertFalse(try requests(root).contains { $0["method"].string == "turn/start" })
        }
    }

    func testSignedOutShowsRepoManLoginCommandBeforeCreatingThread() async throws {
        let (root, generator) = try fixture("signed-out")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await generator.generate(context: "selected changes"); XCTFail("Expected sign-in requirement") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in to Codex for RepoMan"))
            XCTAssertTrue(error.localizedDescription.contains(root.appendingPathComponent("codex-home").path))
        }
        XCTAssertFalse(try requests(root).contains { $0["method"].string == "thread/start" })
    }

    func testServerRejectionReportsTheFailedRequestAndUnderlyingCauseWithoutErrorData() async throws {
        let (root, generator) = try fixture("rpc-error")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await generator.generate(context: "selected changes"); XCTFail("Expected protocol rejection") }
        catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("turn/start"), description)
            XCTAssertTrue(description.contains("readOnly.access is no longer supported; use permissionProfile for restricted reads"), description)
            XCTAssertFalse(description.contains("Check the Codex login"), description)
            XCTAssertFalse(description.contains("private-error-data"), description)
        }
    }

    func testRejectsMalformedEmptyOversizedAndIncompleteMessages() async throws {
        for mode in ["malformed", "blank", "oversized", "nul", "extra-field", "failed", "missing-answer"] {
            let (root, generator) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await generator.generate(context: "selected changes"); XCTFail(mode) }
            catch { XCTAssertTrue(error.localizedDescription.contains("invalid commit message"), error.localizedDescription) }
        }
    }

    func testToolCallsAndApprovalsFailWithoutRunningClientActions() async throws {
        for mode in ["tool-request", "tool-item"] {
            let (root, generator) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await generator.generate(context: "selected changes"); XCTFail(mode) }
            catch { XCTAssertTrue(error.localizedDescription.contains("cannot"), error.localizedDescription) }
            XCTAssertEqual(try requests(root).count, 4)
        }
    }

    func testTimeoutBoundsStalledGeneration() async throws {
        let (root, generator) = try fixture("held", timeout: 0.3)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        do { _ = try await generator.generate(context: "selected changes"); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationStopsStalledGenerationPromptly() async throws {
        let (root, generator) = try fixture("held")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Task { try await generator.generate(context: "selected changes") }
        for _ in 0..<200 {
            if (try? requests(root).contains { $0["method"].string == "turn/start" }) == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let start = Date()
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testInvalidContextFailsBeforeStartingCodex() async throws {
        let (root, generator) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for context in [" \n", String(repeating: "x", count: 196_609)] {
            do { _ = try await generator.generate(context: context); XCTFail("Expected invalid context") }
            catch { XCTAssertTrue(error.localizedDescription.contains("could not be summarized")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path))
    }

    static let script = #"""
#!/usr/bin/python3
import sys, json, os
from pathlib import Path
root = Path(__file__).parent
mode = (root / 'mode').read_text()
assert sys.argv[1:4] == ['app-server', '--listen', 'stdio://']
overrides = dict(entry.split('=', 1) for entry in sys.argv[5::2])
assert json.loads(overrides['cli_auth_credentials_store']) == 'file'
assert Path(os.environ['CODEX_HOME']).resolve() == (root / 'codex-home').resolve()
assert Path(os.environ['CODEX_HOME']).stat().st_mode & 0o777 == 0o700
assert json.loads(overrides['model_reasoning_effort']) == 'low'
assert overrides['features.shell_tool'] == 'false'
profile = json.loads(overrides['default_permissions'])
policy = overrides['permissions.' + profile]
assert profile.startswith('repoman-commit-')
assert '"enabled"=false' in policy
assert '"write"' not in policy
assert '":minimal"="read"' in policy
assert Path.cwd().name.startswith('repoman-commit-')
def send(value): print(json.dumps(value), flush=True)
def reply(request, value): send({'id': request['id'], 'result': value})
while True:
    line = sys.stdin.readline()
    if not line: break
    req = json.loads(line)
    method = req.get('method')
    if method == 'initialized': continue
    with (root / 'requests').open('a') as log: log.write(json.dumps(req) + '\n')
    if method == 'initialize': reply(req, {})
    elif method == 'account/read': reply(req, {'requiresOpenaiAuth': True, 'account': None if mode == 'signed-out' else {'type': 'chatgpt'}})
    elif method == 'thread/start':
        p = req['params']
        assert Path(p['cwd']).resolve() == Path.cwd().resolve()
        assert p['permissions'] == profile
        assert p['cwd'] in policy
        reply(req, {'thread': {'id': 'draft-thread', 'ephemeral': mode != 'persistent'},
                    'model': 'other' if mode == 'wrong-model' else p['model'],
                    'reasoningEffort': 'high' if mode == 'high' else 'low', 'cwd': p['cwd'],
                    'approvalPolicy': 'never', 'activePermissionProfile': {'id': 'other' if mode == 'wrong-profile' else profile},
                    'sandbox': {'type': 'workspaceWrite' if mode == 'writable' else 'readOnly', 'networkAccess': False}})
    elif method == 'turn/start':
        assert req['params']['permissions'] == profile
        assert 'sandboxPolicy' not in req['params']
        if mode == 'rpc-error':
            send({'id': req['id'], 'error': {'code': -32600,
                  'message': 'Invalid request: readOnly.access is no longer supported; use permissionProfile for restricted reads',
                  'data': {'context': 'private-error-data'}}}); continue
        reply(req, {'turn': {'id': 'draft-turn'}})
        if mode == 'held': continue
        if mode == 'tool-request':
            send({'id': 'approval', 'method': 'item/commandExecution/requestApproval', 'params': {}}); continue
        if mode == 'tool-item':
            send({'method': 'item/started', 'params': {'item': {'type': 'commandExecution'}}}); continue
        draft = 'Add native Git sync\n\nReview selected files before committing.'
        if mode == 'blank': draft = ' \n '
        if mode == 'oversized': draft = 'x' * 4097
        if mode == 'nul': draft = 'A\0B'
        result = {'message': draft}
        if mode == 'extra-field': result['other'] = True
        answer = 'not json' if mode == 'malformed' else json.dumps(result)
        if mode != 'missing-answer':
            send({'method': 'item/completed', 'params': {'threadId': 'draft-thread', 'turnId': 'draft-turn',
                 'item': {'type': 'agentMessage', 'text': answer}}})
        send({'method': 'turn/completed', 'params': {'threadId': 'draft-thread',
             'turn': {'id': 'draft-turn', 'status': 'failed' if mode == 'failed' else 'completed', 'error': None}}})
"""#
}
