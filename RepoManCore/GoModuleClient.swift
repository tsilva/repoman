import Foundation

/// Only installed native Go metadata commands run, on temporary copies containing no source code.
enum GoModuleClient {
    static func read(_ module: String, _ sum: String, _ root: URL, _ timeout: TimeInterval,
                     environment sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
        guard timeout > 0, let executable = executable(excluding: root, environment: sourceEnvironment) else { throw unavailable() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let mod = directory.appendingPathComponent("go.mod"), sums = directory.appendingPathComponent("go.sum")
        try Data(module.utf8).write(to: mod); try Data(sum.utf8).write(to: sums)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: mod.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: sums.path)
        var environment = sourceEnvironment.filter { key, _ in
            ["PATH", "HOME", "TMPDIR", "GOPATH", "GOMODCACHE", "GOCACHE", "GOENV", "GOPRIVATE", "GONOPROXY", "GONOSUMDB"].contains(key)
        }
        if let path = environment["GOENV"], path != "off" {
            guard path.hasPrefix("/") else { throw unavailable() }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix("/"), !inside(url, root) else { throw unavailable() }
        }
        environment.merge(["GOTOOLCHAIN": "local", "GOPROXY": "off", "GOSUMDB": "off", "GOWORK": "off",
                           "GOFLAGS": "", "GOVCS": "*:off", "GOTELEMETRY": "off", "CGO_ENABLED": "0"]) { _, value in value }
        let start = Date()
        let envData = try run(executable, ["env", "-json", "GOPRIVATE", "GONOPROXY", "GONOSUMDB", "GOMODCACHE", "GOCACHE", "GOVERSION"],
                              directory: directory, environment: environment, timeout: min(3, timeout))
        guard let settings = try JSONSerialization.jsonObject(with: envData) as? [String: String],
              settings.count == 6, compatible(settings["GOVERSION"] ?? ""), let cache = settings["GOMODCACHE"], cache.hasPrefix("/"),
              let buildCache = settings["GOCACHE"], buildCache.hasPrefix("/"),
              !inside(URL(fileURLWithPath: cache).resolvingSymlinksInPath(), root),
              !inside(URL(fileURLWithPath: buildCache).resolvingSymlinksInPath(), root) else { throw unavailable() }
        let patterns = ["GOPRIVATE", "GONOPROXY", "GONOSUMDB"].flatMap { (settings[$0] ?? "").split(separator: ",").map(String.init) }
        environment.merge(["GOENV": "off", "GOMODCACHE": cache, "GOCACHE": buildCache, "GONOPROXY": "none", "GONOSUMDB": "none"]) { _, value in value }
        let remaining = timeout - Date().timeIntervalSince(start)
        guard remaining > 0 else { throw unavailable() }
        let output = try run(executable, ["list", "-m", "-mod=readonly", "-json", "all"], directory: directory, environment: environment, timeout: remaining)
        guard try Data(contentsOf: mod) == Data(module.utf8), try Data(contentsOf: sums) == Data(sum.utf8) else { throw unavailable() }
        return try JSONSerialization.data(withJSONObject: ["modules": objects(output), "privatePatterns": patterns])
    }
    static func manifest(_ text: String, excluding root: URL, timeout: TimeInterval) throws -> Data {
        guard text.utf8.count <= 1_048_576, timeout > 0, let executable = executable(excluding: root) else { throw unavailable() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-manifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("go.mod")
        try Data(text.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR"].contains($0.key) }
        environment.merge(["GOTOOLCHAIN": "local", "GOPROXY": "off", "GOSUMDB": "off", "GOWORK": "off", "GOENV": "off",
                           "GOFLAGS": "", "GOVCS": "*:off", "GOTELEMETRY": "off", "CGO_ENABLED": "0"]) { _, value in value }
        let start = Date()
        let version = try run(executable, ["env", "GOVERSION"], directory: directory, environment: environment, timeout: min(3, timeout))
        guard compatible(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw unavailable() }
        let remaining = timeout - Date().timeIntervalSince(start)
        guard remaining > 0 else { throw unavailable() }
        let result = try run(executable, ["mod", "edit", "-json"], directory: directory, environment: environment, timeout: remaining)
        guard try Data(contentsOf: path) == Data(text.utf8) else { throw unavailable() }
        return result
    }
    private static func compatible(_ version: String) -> Bool {
        guard let match = CheckSupport.captures(version, #"^go1\.([0-9]{1,3})(?:\.[0-9]{1,3})?$"#).first,
              let minor = Int(match[1]) else { return false }
        return minor >= 18
    }
    static func executable(excluding root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        for part in (environment["PATH"] ?? "").split(separator: ":").prefix(64) where part.hasPrefix("/") {
            let file = URL(fileURLWithPath: String(part)).appendingPathComponent("go").resolvingSymlinksInPath()
            if !inside(file, root), FileManager.default.isExecutableFile(atPath: file.path),
               let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                let magic = (try? handle.read(upToCount: 4)) ?? Data()
                // Installed native executables only; repository/shell wrappers are not metadata tools.
                if [Data([0x7f, 0x45, 0x4c, 0x46]), Data([0xcf, 0xfa, 0xed, 0xfe]),
                    Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xca, 0xfe, 0xba, 0xbe]),
                    Data([0xbe, 0xba, 0xfe, 0xca])].contains(magic) { return file }
            }
        }
        return nil
    }
    private static func inside(_ path: URL, _ root: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL.path
        return root == "/" || path.path == root || path.path.hasPrefix(root + "/")
    }
    static func objects(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= 2_097_152 else { throw unavailable() }
        var result: [[String: Any]] = [], start: Int?, depth = 0, quoted = false, escape = false
        let bytes = [UInt8](data)
        for (index, byte) in bytes.enumerated() {
            if start == nil {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard byte == 123 else { throw unavailable() }
                start = index
            }
            if quoted {
                if escape { escape = false }
                else if byte == 92 { escape = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1; guard depth <= 64 else { throw unavailable() } }
            else if byte == 125 {
                depth -= 1
                if depth == 0, let first = start {
                    guard result.count < 2_048,
                          let object = try JSONSerialization.jsonObject(with: Data(bytes[first...index])) as? [String: Any] else { throw unavailable() }
                    result.append(object); start = nil
                }
            }
        }
        guard start == nil, !quoted, depth == 0, !result.isEmpty else { throw unavailable() }
        return result
    }
    private static func run(_ executable: URL, _ arguments: [String], directory: URL,
                            environment: [String: String], timeout: TimeInterval) throws -> Data {
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        let capture = GoOutput()
        let drained = DispatchSemaphore(value: 0)
        try process.run()
        Thread.detachNewThread {
            var bytes = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                bytes.append(chunk.prefix(max(0, 2_097_153 - bytes.count)))
            }
            capture.set(bytes); drained.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw unavailable()
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0,
              capture.value.count <= 2_097_152 else { throw unavailable() }
        return capture.value
    }
    private static func unavailable() -> InspectionError { .blocked("Installed offline Go metadata could not be verified; no package/toolchain installation or repository code execution was attempted.") }
}

private final class GoOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
}
