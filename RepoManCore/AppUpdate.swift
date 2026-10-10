import CryptoKit
import Foundation

struct AppVersion: Comparable, Equatable, Sendable {
    let components: [Int]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.compactMap({ Int($0) }).count == 3 else { return nil }
        components = parts.compactMap { Int($0) }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct AppUpdateRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
    }

    func update(after installed: String, architecture: String) throws -> AppUpdateCandidate? {
        guard !draft, !prerelease, let version = AppVersion(tagName), let current = AppVersion(installed),
              version > current else { return nil }
        let name = "RepoMan-\(tagName)-macOS-\(architecture)-adhoc.dmg"
        guard let dmg = assets.first(where: { $0.name == name }),
              let checksum = assets.first(where: { $0.name == name + ".sha256" }),
              dmg.size > 0, dmg.size <= 512 * 1_024 * 1_024, checksum.size > 0, checksum.size <= 4_096,
              [dmg, checksum].allSatisfy({ asset in
                  asset.browserDownloadURL.absoluteString == "https://github.com/tsilva/repoman/releases/download/\(tagName)/\(asset.name)"
              }) else { throw AppUpdateError.message("The latest release has no complete, compatible DMG and checksum.") }
        return AppUpdateCandidate(version: String(tagName.dropFirst(tagName.hasPrefix("v") ? 1 : 0)), dmg: dmg, checksum: checksum)
    }
}

struct AppUpdateCandidate: Sendable {
    let version: String
    let dmg: AppUpdateRelease.Asset
    let checksum: AppUpdateRelease.Asset

    func verify(dmgURL: URL, checksumData: Data) throws {
        guard checksumData.count <= 4_096,
              let text = String(data: checksumData, encoding: .utf8) else {
            throw AppUpdateError.message("The release checksum is invalid.")
        }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, String(fields[1]) == dmg.name || String(fields[1]) == "*" + dmg.name,
              Self.isDigest(String(fields[0])) else { throw AppUpdateError.message("The release checksum is invalid.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: dmgURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == dmg.size else {
            throw AppUpdateError.message("The update download is incomplete.")
        }
        let handle = try FileHandle(forReadingFrom: dmgURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == String(fields[0]).lowercased() else {
            throw AppUpdateError.message("The downloaded DMG does not match the release checksum.")
        }
        if let digest = dmg.digest {
            guard digest == "sha256:" + actual else { throw AppUpdateError.message("The DMG does not match GitHub’s asset digest.") }
        }
    }

    private static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

enum AppUpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

final class AppUpdateClient: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        self.session = session ?? URLSession(configuration: configuration)
    }

    func check(installed: String, architecture: String) async throws -> AppUpdateCandidate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/tsilva/repoman/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RepoMan/\(installed)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.validate(response)
        guard data.count < 1_048_576 else { throw AppUpdateError.message("GitHub returned an oversized release response.") }
        return try JSONDecoder().decode(AppUpdateRelease.self, from: data).update(after: installed, architecture: architecture)
    }

    func download(_ update: AppUpdateCandidate, to directory: URL) async throws -> URL {
        let (checksum, checksumResponse) = try await session.data(from: update.checksum.browserDownloadURL)
        try Self.validate(checksumResponse)
        guard checksum.count == update.checksum.size else { throw AppUpdateError.message("The checksum download is incomplete.") }
        let (temporary, response) = try await session.download(from: update.dmg.browserDownloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        let destination = directory.appendingPathComponent(update.dmg.name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try await Task.detached(priority: .utility) { try update.verify(dmgURL: destination, checksumData: checksum) }.value
        return destination
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AppUpdateError.message("GitHub could not provide the update. Check your connection and try again.")
        }
    }
}
