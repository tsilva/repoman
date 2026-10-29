import Foundation

/// Anonymous public-registry reads. No package contents, credentials or persistent cache are used.
final class PublicRegistryRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var cancelled = false
    private let maximumBytes: Int
    private init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    static func read(_ url: URL, timeout: TimeInterval = 20, maximumBytes: Int = 67_108_864,
                     configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        guard url.scheme == "https", ["registry.npmjs.org", "pypi.org"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil,
              maximumBytes > 0, timeout > 0 else { throw InspectionError.blocked("Unsupported public registry request.") }
        let operation = PublicRegistryRequest(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in operation.start(url, timeout, configuration, continuation) }
        }, onCancel: { operation.cancel() })
    }
    private func start(_ url: URL, _ timeout: TimeInterval, _ configuration: URLSessionConfiguration,
                       _ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "RepoMan/dependency-release-age"]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = timeout
        let task = session.dataTask(with: request); self.task = task
        lock.unlock(); task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); let current = continuation; continuation = nil
        let session = self.session; self.session = nil; task = nil; data = Data(); lock.unlock()
        session?.invalidateAndCancel(); current?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel); finish(.failure(InspectionError.blocked("Public registry response was unavailable or exceeded the inspection limit."))); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        if chunk.count > maximumBytes - data.count {
            lock.unlock(); finish(.failure(InspectionError.blocked("Public registry response exceeded the inspection limit."))); return
        }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(InspectionError.blocked("Public registry redirects require review; no redirected request was sent.")))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(InspectionError.blocked("Public registry evidence could not be read completely."))); return }
        lock.lock(); let result = data; lock.unlock(); finish(.success(result))
    }
}

enum RegistryReleaseEvidence {
    struct Verdict: Sendable {
        var publishedAt: Date?
        var eligibleAt: Date?
        var ageEligible: Bool?
        var risks: [String] = []
        var unknownReason: String?
    }
    static func date(_ raw: String) -> Date? {
        guard let match = CheckSupport.captures(raw, #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#).first,
              let whole = ISO8601DateFormatter().date(from: match[1] + match[3]) else { return nil }
        // Foundation's fractional parser truncates to milliseconds. Preserve registry microseconds,
        // conservatively rounding submicrosecond publication evidence upward.
        let digits = match[2], head = String(digits.prefix(6))
        var micros = Int(head + String(repeating: "0", count: max(0, 6 - head.count))) ?? 0
        if digits.dropFirst(6).contains(where: { $0 != "0" }) { micros += 1 }
        return whole.addingTimeInterval(Double(micros) / 1_000_000)
    }
    static func timestamp(_ date: Date) -> String {
        let seconds = floor(date.timeIntervalSince1970)
        let micros = Int(((date.timeIntervalSince1970 - seconds) * 1_000_000).rounded())
        let carry = micros == 1_000_000 ? 1.0 : 0.0
        let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds + carry))
        return String(whole.dropLast()) + String(format: ".%06dZ", micros == 1_000_000 ? 0 : micros)
    }
    static func url(_ entry: DependencyLockInventory.Entry) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let name = entry.name.addingPercentEncoding(withAllowedCharacters: allowed)!
        if entry.ecosystem == "npm" { return URL(string: "https://registry.npmjs.org/" + name)! }
        let version = entry.version.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: "https://pypi.org/pypi/" + name + "/" + version + "/json")!
    }
    static func evaluate(_ entries: [DependencyLockInventory.Entry], document: [String: Any], at: Date) -> Verdict {
        guard let entry = entries.first, entries.allSatisfy({ $0.identity == entry.identity && $0.source != "unsupported" }) else {
            return Verdict(unknownReason: "Dependency source is unsupported or cannot be verified.")
        }
        var result = Verdict()
        let published: Date?
        if entry.ecosystem == "npm" {
            guard document["name"] as? String == entry.name,
                  let versions = document["versions"] as? [String: [String: Any]], let version = versions[entry.version],
                  version["version"] as? String == entry.version, version["name"] as? String == entry.name,
                  let dist = version["dist"] as? [String: Any], entries.allSatisfy({ matchesPublicArtifact($0, dist: dist) }) else {
                return Verdict(unknownReason: "Public npm package identity or locked artifact provenance could not be verified.")
            }
            if let deprecated = version["deprecated"] {
                guard let text = deprecated as? String else { return Verdict(unknownReason: "npm deprecation metadata is unsupported.") }
                if !text.isEmpty { result.risks.append("deprecated") }
            }
            published = (document["time"] as? [String: String])?[entry.version].flatMap(date)
        } else {
            guard let info = document["info"] as? [String: Any], let name = info["name"] as? String,
                  (try? DependencyLockInventory.normalizedName(name, ecosystem: "pypi")) == entry.name,
                  info["version"] as? String == entry.version,
                  let files = document["urls"] as? [[String: Any]], !files.isEmpty else {
                return Verdict(unknownReason: "PyPI release identity or complete artifact evidence is missing.")
            }
            if files.contains(where: { DependencyLockInventory.boolean($0["yanked"]) == true }) { result.risks.append("yanked") }
            guard files.allSatisfy({ DependencyLockInventory.boolean($0["yanked"]) != nil }) else {
                result.unknownReason = "PyPI yanking evidence is incomplete."; return result
            }
            let dates = files.compactMap { ($0["upload_time_iso_8601"] as? String).flatMap(date) }
            published = dates.count == files.count ? dates.max() : nil
        }
        guard let published, published <= at else {
            result.unknownReason = "Publication timestamps are missing, invalid or later than the observation time."; return result
        }
        result.publishedAt = published; result.eligibleAt = published.addingTimeInterval(7 * 86_400)
        result.ageEligible = at >= result.eligibleAt!
        return result
    }
    private static func matchesPublicArtifact(_ entry: DependencyLockInventory.Entry, dist: [String: Any]) -> Bool {
        if let locked = entry.tarball {
            guard let published = dist["tarball"] as? String,
                  DependencyLockInventory.publicNPMTarball(locked), DependencyLockInventory.publicNPMTarball(published),
                  let a = URL(string: locked), let b = URL(string: published), a.path == b.path else { return false }
        }
        if let locked = entry.integrity {
            let supplied = integrities(locked)
            guard !supplied.isEmpty else { return false }
            if let raw = dist["integrity"] {
                guard let text = raw as? String else { return false }
                let known = integrities(text)
                return !known.isEmpty && supplied.isSubset(of: known)
            }
            if let hex = dist["shasum"] as? String, CheckSupport.matches(hex, #"^[0-9a-fA-F]{40}$"#) {
                let bytes = stride(from: 0, to: 40, by: 2).compactMap { index -> UInt8? in
                    let a = hex.index(hex.startIndex, offsetBy: index), b = hex.index(a, offsetBy: 2)
                    return UInt8(hex[a..<b], radix: 16)
                }
                return supplied.isSubset(of: ["sha1-" + Data(bytes).base64EncodedString()])
            }
            return false
        }
        guard let locked = entry.tarball, let published = dist["tarball"] as? String,
              DependencyLockInventory.publicNPMTarball(locked), DependencyLockInventory.publicNPMTarball(published),
              let a = URL(string: locked), let b = URL(string: published) else { return false }
        return a.path == b.path
    }
    private static func integrities(_ raw: String) -> Set<String> {
        let sizes = ["sha1":20, "sha256":32, "sha384":48, "sha512":64]
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        let values: [String] = tokens.compactMap { token in
            let parts = token.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2, let size = sizes[parts[0]], let bytes = Data(base64Encoded: parts[1]), bytes.count == size else { return nil }
            return parts[0] + "-" + bytes.base64EncodedString()
        }
        return values.count == tokens.count ? Set(values) : []
    }
}
