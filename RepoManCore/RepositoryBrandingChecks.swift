import CryptoKit
import Foundation
import ImageIO

enum RepositoryBrandingChecks {
    static let assetsID = "branding.assets"
    static let provenanceID = "branding.provenance"
    private static let recordPath = "image-assets/provenance.json"
    private static let currentModels: Set<String> = ["gpt-image-2.5-sunburst", "gpt-image-2.5-sunburst-2026-09-08"]

    private enum Profile: String, Decodable {
        case web, apple, android, desktop
    }

    private enum Role: String, CaseIterable, Decodable {
        case readmeLogo = "readme-logo"
        case favicon
        case socialPreview = "social-preview"
        case appleIcon = "apple-icon"
        case androidIcon = "android-icon"
        case desktopIcon = "desktop-icon"

        var profile: Profile? {
            switch self {
            case .readmeLogo: nil
            case .favicon, .socialPreview: .web
            case .appleIcon: .apple
            case .androidIcon: .android
            case .desktopIcon: .desktop
            }
        }
    }

    private struct Record: Decodable {
        struct Source: Decodable {
            let path: String
            let sha256: String
            let model: String?
            let generatedAt: Date?
            let evidence: String?
        }

        struct Export: Decodable {
            let role: Role
            let path: String
            let sha256: String
            let source: String
        }

        let version: Int
        let profiles: Set<Profile>
        let sources: [Source]
        let exports: [Export]
    }

    static func checks() -> [RepositoryCheck] {
        [
            check(assetsID, "Required branding assets") { try assetFindings($0) },
            check(provenanceID, "Recorded branding provenance") { try provenanceFindings($0) },
        ]
    }

    private static func check(_ id: String, _ title: String,
                              evaluate: @escaping @Sendable (RepositoryInspectionContext) throws -> RepositoryCheckResult) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: .documentation, symbol: "photo", evaluate: { context in
            let snapshot = context.snapshot
            let names = [snapshot.name, GitHubCI.repository(snapshot.remoteURL)?.name].compactMap { $0 }
            if names.contains(where: { name in
                let normalized = name.lowercased()
                return normalized.hasPrefix("private-") || normalized.hasPrefix("sandbox-")
            }) {
                return .skipped("Branding is optional for private- and sandbox- repositories.")
            }
            let policy = try RepositoryCheckPolicy.load(context)
            let result = try evaluate(context)
            let findings = context.applyingExceptions(result.detectedFindings, policy: policy)
            if case .partial(_, let reason) = result { return .partial(findings, reason) }
            return .findings(findings)
        })
    }

    private static func readRecord(_ context: RepositoryInspectionContext) throws -> Record? {
        guard try context.isTracked(recordPath), try context.exists(recordPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try context.readBrandingFile(recordPath, maximumBytes: 65_536)
        guard let record = try? decoder.decode(Record.self, from: data), record.version == 1,
              record.sources.count <= 16, record.exports.count <= 32,
              Set(record.sources.map(\.path)).count == record.sources.count,
              Set(record.exports.map(\.role)).count == record.exports.count,
              Set(record.exports.map(\.path)).count == record.exports.count,
              record.sources.allSatisfy({ validPath($0.path) && validDigest($0.sha256) }),
              record.exports.allSatisfy({ validPath($0.path) && validDigest($0.sha256) }),
              Set(record.sources.map(\.path)).isDisjoint(with: record.exports.map(\.path)) else {
            throw InspectionError.blocked("Invalid branding provenance record at " + recordPath + ". Expected version 1, unique source and export paths, and SHA-256 digests.")
        }
        return record
    }

    private static func validPath(_ path: String) -> Bool {
        path.utf8.count <= 240 && !path.contains("\\") &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func inventory(_ context: RepositoryInspectionContext) throws -> Set<String> {
        let names = [
            "README*", "readme*", "logo.png", "index.html", "vercel.json", "netlify.toml",
            "next.config.*", "astro.config.*", "svelte.config.*", "nuxt.config.*",
            "AndroidManifest.xml", "*.xcodeproj/project.pbxproj", "AppIcon.appiconset/*.png",
            "AppIcon.appiconset/Contents.json", "*.icon/icon.json", "*.icon/Assets/*.png",
            "tauri.conf.json", "electron-builder.*", "favicon.*", "opengraph-image.*", "og-image.*",
            "og-image-1200x630.png", "ic_launcher.png", "ic_launcher.webp", "icon.icns", "icon.ico",
        ]
        return try Set(context.trackedPaths(matching: names.map { ":(glob,icase)**/" + $0 }).filter { path in
            !path.split(separator: "/").dropLast().contains {
                ["fixtures", "test", "tests", "examples", "vendor", "node_modules", "third_party", "third-party"].contains($0.lowercased())
            }
        })
    }

    private static func requiredRoles(_ paths: Set<String>, record: Record?,
                                      context: RepositoryInspectionContext, reasons: inout [String]) -> [Role] {
        var profiles = record?.profiles ?? []
        for path in paths {
            let name = (path as NSString).lastPathComponent.lowercased()
            if ["vercel.json", "netlify.toml"].contains(name) ||
                ["next.config.", "astro.config.", "svelte.config.", "nuxt.config."].contains(where: name.hasPrefix) ||
                ["index.html", "public/index.html", "src/index.html"].contains(path.lowercased()) {
                profiles.insert(.web)
            }
            if path.hasSuffix("/AppIcon.appiconset/Contents.json") || path.hasSuffix(".icon/icon.json") {
                profiles.insert(.apple)
            }
            if name == "tauri.conf.json" || name.hasPrefix("electron-builder.") { profiles.insert(.desktop) }
        }
        if !profiles.contains(.web) {
            do {
                if try !WebsiteDomains.load(context).isEmpty { profiles.insert(.web) }
            } catch { reasons.append("Web profile: " + error.localizedDescription) }
        }
        if !profiles.contains(.apple) {
            let projects = paths.filter { $0.hasSuffix(".xcodeproj/project.pbxproj") }.sorted()
            for path in projects.prefix(16) {
                do {
                    let project = try context.readText(path)
                    if CheckSupport.matches(project, #"\bproductType\s*=\s*"com\.apple\.product-type\.application";"#) {
                        profiles.insert(.apple)
                        break
                    }
                } catch { reasons.append("Apple profile: " + error.localizedDescription) }
            }
            if !profiles.contains(.apple), projects.count > 16 { reasons.append("Apple profile: More than 16 Xcode projects.") }
        }
        if !profiles.contains(.android) {
            let manifests = paths.filter { ($0 as NSString).lastPathComponent == "AndroidManifest.xml" }.sorted()
            for path in manifests.prefix(16) {
                do {
                    let manifest = try context.readText(path)
                        .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
                    if CheckSupport.matches(manifest, #"<category\s[^>]*["']android\.intent\.category\.(?:LEANBACK_)?LAUNCHER["']"#) {
                        profiles.insert(.android)
                        break
                    }
                } catch { reasons.append("Android profile: " + error.localizedDescription) }
            }
            if !profiles.contains(.android), manifests.count > 16 { reasons.append("Android profile: More than 16 manifests.") }
        }
        return Role.allCases.filter { $0.profile.map { profiles.contains($0) } ?? true }
    }

    private static func candidates(_ role: Role, paths: Set<String>) -> [String] {
        paths.filter { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            switch role {
            case .readmeLogo: return false
            case .favicon:
                return name.hasPrefix("favicon.") && webLocation(path)
            case .socialPreview:
                return ["opengraph-image.", "og-image."].contains(where: name.hasPrefix) && webLocation(path) ||
                    path == "image-assets/web-seo/og-image-1200x630.png"
            case .appleIcon:
                return name.hasSuffix(".png") && (path.contains("/AppIcon.appiconset/") || path.contains(".icon/Assets/"))
            case .androidIcon:
                return ["ic_launcher.png", "ic_launcher.webp"].contains(name) && path.contains("/res/mipmap")
            case .desktopIcon: return ["icon.icns", "icon.ico"].contains(name)
            }
        }.sorted()
    }

    private static func webLocation(_ path: String) -> Bool {
        let directories = path.split(separator: "/").dropLast()
        return directories.isEmpty || directories.contains { ["public", "static", "app", "www"].contains($0) } ||
            path.hasPrefix("image-assets/web-seo/")
    }

    private static func assetFindings(_ context: RepositoryInspectionContext) throws -> RepositoryCheckResult {
        let paths = try inventory(context)
        var reasons: [String] = []
        let record: Record?
        do { record = try readRecord(context) }
        catch {
            record = nil
            reasons.append(error.localizedDescription)
        }
        var findings: [RepositoryFinding] = []
        let roles = requiredRoles(paths, record: record, context: context, reasons: &reasons)
        for role in roles {
            do {
                let declared = record?.exports.first(where: { $0.role == role })?.path
                if role == .readmeLogo {
                    if let issue = try readmeLogoFinding(context, paths: paths, declared: declared) {
                        findings.append(issue)
                    }
                    continue
                }
                let options = declared.map { [$0] } ?? candidates(role, paths: paths)
                var found = false
                for path in options.prefix(32) {
                    guard try context.isTracked(path), try context.exists(path) else { continue }
                    let data = try context.readBrandingFile(path, maximumBytes: 16 * 1_024 * 1_024)
                    if imageMatches(data, path: path, role: role) {
                        found = true
                        break
                    }
                }
                if !found {
                    if options.count > 32 {
                        reasons.append(role.rawValue + ": More than 32 candidate assets.")
                    } else {
                        findings.append(finding(context, assetsID, role.rawValue, "Required branding asset missing or invalid",
                                                "Expected a tracked, readable " + role.rawValue + " image" + (declared.map { " at " + $0 } ?? "") + "."))
                    }
                }
            } catch { reasons.append(role.rawValue + ": " + error.localizedDescription) }
        }
        return reasons.isEmpty ? .findings(findings) : .partial(findings, reasons.joined(separator: "\n"))
    }

    private static func readmeLogoFinding(_ context: RepositoryInspectionContext, paths: Set<String>,
                                          declared: String?) throws -> RepositoryFinding? {
        let path = "logo.png"
        let subject = Role.readmeLogo.rawValue
        let url = context.snapshot.url.appendingPathComponent(path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return finding(context, assetsID, subject, "README logo is missing", "Add logo.png at the repository root.")
        } catch {
            throw InspectionError.blocked("The root logo.png could not be inspected.")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value != 0 else {
            return finding(context, assetsID, subject, "README logo is invalid", "Root logo.png must be a nonempty regular PNG file.")
        }
        let data = try context.readBrandingFile(path, maximumBytes: 16 * 1_024 * 1_024)
        guard imageMatches(data, path: path, role: .readmeLogo) else {
            return finding(context, assetsID, subject, "README logo is invalid", "Root logo.png does not contain a readable PNG image.")
        }
        guard paths.contains(path) else {
            return finding(context, assetsID, subject, "README logo is untracked", "Root logo.png exists locally and needs to be tracked in Git.")
        }
        if let declared, declared != path {
            return finding(context, assetsID, subject, "README logo declaration is invalid",
                           "The readme-logo export in image-assets/provenance.json must point to root logo.png.")
        }
        guard try readmeReferencesLogo(context, paths: paths) else {
            return finding(context, assetsID, "readme-reference", "README logo is not wired",
                           "Reference the root logo.png as an image in the tracked root README.")
        }
        return nil
    }

    private static func readmeReferencesLogo(_ context: RepositoryInspectionContext, paths: Set<String>) throws -> Bool {
        let readmes = paths.filter { !$0.contains("/") && RepositoryIssueCatalog.isReadme($0) }
        guard let path = readmes.contains("README.md") ? "README.md" : readmes.sorted().first,
              try context.exists(path) else { return false }
        let text = RepositoryHygieneChecks.markdownProse(try context.readText(path))
            .replacingOccurrences(of: #"(?s)<!--.*?-->|\x60[^\x60\n]*\x60"#, with: "", options: .regularExpression)
        let repository = GitHubCI.repository(context.snapshot.remoteURL)
        let patterns = [
            #"(?im)<img\b[^>]*\ssrc\s*=\s*["']([^"'\s]+)["']"#,
            #"!\[[^\]\n]*\]\(\s*<?([^\s>)]+)>?(?:\s|\))"#,
            #"(?m)^\s*\.\.\s+image::\s+(\S+)\s*$"#,
            #"(?m)^\s*image::([^\[\s]+)\["#,
        ]
        if patterns.contains(where: { pattern in
            CheckSupport.captures(text, pattern).contains { isRootLogoReference($0[1], repository: repository) }
        }) { return true }
        let labels = Set(CheckSupport.captures(text, #"(?m)^ {0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]+)>?"#)
            .filter { isRootLogoReference($0[2], repository: repository) }.map { $0[1].lowercased() })
        return CheckSupport.captures(text, #"!\[([^\]\n]+)\](?:\[([^\]\n]*)\]|(?![\[(]))"#)
            .contains { match in
                let label = match.count > 2 && !match[2].isEmpty ? match[2] : match[1]
                return labels.contains(label.lowercased())
            }
    }

    private static func isRootLogoReference(_ target: String, repository: GitHubCI.Repository?) -> Bool {
        if target == "logo.png" || target == "./logo.png" { return true }
        guard let repository, let url = URLComponents(string: target), url.scheme == "https",
              url.host?.lowercased() == "raw.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil, !url.percentEncodedPath.contains("%") else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4 || (parts.count == 6 && parts[2] == "refs" && ["heads", "tags"].contains(parts[3])) else {
            return false
        }
        return parts[0].lowercased() == repository.owner.lowercased() &&
            parts[1].lowercased() == repository.name.lowercased() && parts.last == "logo.png"
    }

    private static func imageMatches(_ data: Data, path: String, role: Role) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "svg", role == .favicon {
            guard data.count <= 1_048_576, let xml = String(data: data, encoding: .utf8),
                  !xml.contains("<!DOCTYPE") else { return false }
            let parser = XMLParser(data: data)
            let root = SVGRoot()
            parser.delegate = root
            parser.shouldResolveExternalEntities = false
            return parser.parse() && root.isSVG
        }
        let types = ["png": "public.png", "jpg": "public.jpeg", "jpeg": "public.jpeg", "webp": "org.webmproject.webp",
                     "ico": "com.microsoft.ico", "icns": "com.apple.icns"]
        let allowed: Set<String>
        switch role {
        case .readmeLogo, .appleIcon: allowed = ["png"]
        case .favicon: allowed = ["png", "ico"]
        case .socialPreview: allowed = ["png", "jpg", "jpeg", "webp"]
        case .androidIcon: allowed = ["png", "webp"]
        case .desktopIcon: allowed = ["png", "ico", "icns"]
        }
        guard allowed.contains(ext), let expected = types[ext],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == expected,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return false }
        return role != .socialPreview || (width >= 600 && height >= 315 && abs(Double(width) / Double(height) - 1200.0 / 630.0) < 0.06)
    }

    private final class SVGRoot: NSObject, XMLParserDelegate {
        var isSVG = false
        private var seenRoot = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard !seenRoot else { return }
            seenRoot = true
            isSVG = elementName == "svg"
        }
    }

    private static func provenanceFindings(_ context: RepositoryInspectionContext) throws -> RepositoryCheckResult {
        guard let record = try readRecord(context) else {
            let absence = "No tracked " + recordPath + ". ImageGen model and export lineage are unknown."
            return .partial([], ([absence] + (try legacySourceEvidence(context))).joined(separator: "\n"))
        }
        var unknown: [String] = []
        let roles = requiredRoles(try inventory(context), record: record, context: context, reasons: &unknown)
        let sources = Dictionary(uniqueKeysWithValues: record.sources.map { ($0.path, $0) })
        var checked = Set<String>()
        var findings: [RepositoryFinding] = []

        func verify(_ path: String, expected: String, original: Bool = false) {
            guard checked.insert(path).inserted else { return }
            do {
                guard try context.isTracked(path), try context.exists(path) else {
                    findings.append(finding(context, provenanceID, path, "Branding file missing from Git",
                                            "The provenance record refers to a missing or untracked file."))
                    return
                }
                let bytes = try context.readBrandingFile(path, maximumBytes: 16 * 1_024 * 1_024)
                let actual = fingerprint(bytes)
                if actual != expected {
                    findings.append(finding(context, provenanceID, path, "Branding fingerprint changed",
                                            "SHA-256 differs from the provenance record. Current SHA-256: " + actual))
                }
                if original, CGImageSourceCreateWithData(bytes as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) != true {
                    findings.append(finding(context, provenanceID, path + "#image", "Invalid original branding image",
                                            "Preserve the original raster generation output in the provenance record."))
                }
            } catch { unknown.append(error.localizedDescription) }
        }

        for role in roles where !record.exports.contains(where: { $0.role == role }) {
            unknown.append(role.rawValue + ": No export lineage recorded.")
        }
        var usedSources = Set<String>()
        for export in record.exports {
            verify(export.path, expected: export.sha256)
            guard let source = sources[export.source] else {
                findings.append(finding(context, provenanceID, export.path, "Branding source is undeclared",
                                        "The export must reference a source in the same provenance record."))
                continue
            }
            usedSources.insert(source.path)
        }
        for source in record.sources where usedSources.contains(source.path) {
            verify(source.path, expected: source.sha256, original: true)
            guard let model = source.model, model != "gpt-image", model != "chatgpt-image-latest",
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = source.generatedAt, date <= Date(),
                  let evidence = source.evidence, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unknown.append(source.path + ": Exact model, generation time or evidence is unavailable.")
                continue
            }
            if !currentModels.contains(model) {
                findings.append(finding(context, provenanceID, source.path, "Recorded model outside branding baseline",
                                        "Expected a recorded GPT Image 2.5 Sunburst generation."))
            }
        }
        return unknown.isEmpty ? .findings(findings) : .partial(findings, unknown.joined(separator: "\n"))
    }

    private static func legacySourceEvidence(_ context: RepositoryInspectionContext) throws -> [String] {
        let names = ["logo-source.png", "icon-source.png", "social-source.png"]
        let paths = try context.trackedPaths(matching: names.map { ":(glob)**/sources/" + $0 }).sorted()
        var lines: [String] = []
        for path in paths.prefix(8) where validPath(path) {
            do {
                let bytes = try context.readBrandingFile(path, maximumBytes: 16 * 1_024 * 1_024)
                let credentials = hasPNGCredentials(bytes) ? " Embedded Content Credentials data present, signature and model unverified." : ""
                lines.append(path + ": SHA-256 " + fingerprint(bytes) + "." + credentials)
            } catch {
                lines.append(error.localizedDescription)
            }
        }
        if paths.count > 8 { lines.append("Additional legacy sources exceed the inspection limit.") }
        return lines
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasPNGCredentials(_ data: Data) -> Bool {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.starts(with: signature) else { return false }
        var offset = signature.count
        while data.count - offset >= 12 {
            let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            let type = data[(offset + 4)..<(offset + 8)]
            if length > 0, type.elementsEqual("caBX".utf8) { return true }
            if type.elementsEqual("IEND".utf8) { return false }
            offset += 12 + length
        }
        return false
    }

    private static func finding(_ context: RepositoryInspectionContext, _ id: String, _ subject: String,
                                _ title: String, _ evidence: String) -> RepositoryFinding {
        CheckSupport.finding(context, id, subject, title, evidence, .documentation, "photo")
    }
}
