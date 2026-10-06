import Foundation

/// Persistent storage owned by RepoMan. Overrides apply only to its child process.
public struct CodexStorage: Sendable {
    public static var defaultHomeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoMan/Codex", isDirectory: true)
    }

    public let homeDirectory: URL
    private let legacyHomeDirectory: URL

    public init(homeDirectory: URL = Self.defaultHomeDirectory, legacyHomeDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.legacyHomeDirectory = legacyHomeDirectory ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    var skillHomeDirectories: [URL] { [homeDirectory, legacyHomeDirectory] }

    var environment: [String: String] { ["CODEX_HOME": homeDirectory.path] }
    // File storage ensures login/logout never uses Desktop's keychain credential slot.
    var arguments: [String] { ["-c", "cli_auth_credentials_store=\"file\""] }

    public func signInCommand(executable: URL) -> String {
        "env CODEX_HOME=\(Self.quote(homeDirectory.path)) \(Self.quote(executable.path)) -c 'cli_auth_credentials_store=\"file\"' login"
    }

    func prepareHomeDirectory() throws {
        let fm = FileManager.default
        let home = homeDirectory.resolvingSymlinksInPath().path
        let legacy = legacyHomeDirectory.resolvingSymlinksInPath().path
        guard home != legacy, !home.hasPrefix(legacy + "/"), !legacy.hasPrefix(home + "/") else {
            throw RepairError.blocked("RepoMan's Codex storage must be separate from the existing Codex home.")
        }
        try fm.createDirectory(at: homeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homeDirectory.path)
    }

    func prepare(for task: RepairTask) throws {
        try prepareHomeDirectory()
        let fm = FileManager.default
        guard let id = task.threadID, task.codexStorageVersion == nil else { return }
        // Only legacy task records can import a transcript, never credentials/configuration.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw RepairError.blocked("The saved Codex thread identifier is invalid.")
        }
        if let existing = try transcript(id: id, under: homeDirectory) {
            try validate(existing, id: id, repositoryURL: task.repositoryURL)
            return
        }
        guard let source = try transcript(id: id, under: legacyHomeDirectory) else {
            throw RepairError.blocked("The saved Codex conversation could not be found for migration to RepoMan's private storage. Its local message history is still saved in RepoMan.")
        }
        try validate(source, id: id, repositoryURL: task.repositoryURL)
        let legacyRoot = legacyHomeDirectory.standardizedFileURL.path + "/"
        // Archived legacy transcripts become usable private copies on explicit continuation.
        let relative = source.standardizedFileURL.path.dropFirst(legacyRoot.count).split(separator: "/").dropFirst().joined(separator: "/")
        let destination = homeDirectory.appendingPathComponent("sessions").appendingPathComponent(relative)
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do { try fm.moveItem(at: temporary, to: destination) }
        catch { if !fm.fileExists(atPath: destination.path) { throw error } }
    }

    private func transcript(id: String, under root: URL) throws -> URL? {
        let fm = FileManager.default
        var matches: [URL] = []
        for name in ["sessions", "archived_sessions"] {
            let sessions = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: sessions.path) else { continue }
            var enumerationError: Error?
            guard let files = fm.enumerator(at: sessions, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                            options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw RepairError.blocked("Could not inspect saved Codex conversations.") }
            for case let file as URL in files where file.lastPathComponent.hasSuffix("-\(id).jsonl") {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      file.resolvingSymlinksInPath().path.hasPrefix(sessions.resolvingSymlinksInPath().path + "/") else { continue }
                matches.append(file)
            }
            if let enumerationError { throw enumerationError }
        }
        guard matches.count <= 1 else { throw RepairError.blocked("Multiple transcripts were found for the saved Codex conversation.") }
        return matches.first
    }

    private func validate(_ file: URL, id: String, repositoryURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var header = Data()
        while header.count < 1_048_576, let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: 10) { header.append(chunk.prefix(upTo: end)); break }
            header.append(chunk)
        }
        let record = try JSONDecoder().decode(JSONValue.self, from: header)
        guard record["type"].string == "session_meta", record["payload"]["id"].string == id,
              let cwd = record["payload"]["cwd"].string,
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == repositoryURL.resolvingSymlinksInPath().path else {
            throw RepairError.blocked("The saved Codex transcript does not match this repository and thread.")
        }
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
