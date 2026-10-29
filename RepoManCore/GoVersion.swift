import Foundation

/// Go canonical semantic versions, including pseudo-version ordering and +incompatible.
struct GoVersion: Comparable {
    let release: [Int]
    let prerelease: [String]
    init?(_ raw: String) {
        guard GoModuleInventory.version(raw) else { return nil }
        let plain = String(raw.dropFirst()).components(separatedBy: "+")[0]
        let parts = plain.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 <= 1_000_000 }) else { return nil }
        let identifiers = parts.count == 2 ? parts[1].components(separatedBy: ".") : []
        guard identifiers.allSatisfy({ token in
            !token.isEmpty && (!token.allSatisfy(\.isNumber) || token.count == 1 || !token.hasPrefix("0"))
        }) else { return nil }
        release = numbers; prerelease = identifiers
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.release != rhs.release { return lhs.release.lexicographicallyPrecedes(rhs.release) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an != bn { return an }
            if an, a.count != b.count { return a.count < b.count }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
    static func contains(_ raw: String, range: String) -> Bool? {
        guard let value = GoVersion(raw), range.utf8.count <= 2_048 else { return nil }
        let alternatives = range.components(separatedBy: "||")
        guard alternatives.count <= 16 else { return nil }
        var unknown = false
        for alternative in alternatives {
            let text = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "*" { return true }
            let terms = text.components(separatedBy: ",")
            guard !terms.isEmpty, terms.count <= 16 else { return nil }
            var included = true, supported = true
            for term in terms {
                guard let match = CheckSupport.captures(term.trimmingCharacters(in: .whitespacesAndNewlines),
                    #"^(>=|<=|==|=|!=|>|<)\s*(v?[0-9][0-9A-Za-z.+-]*)$"#).first else { supported = false; continue }
                let text = match[2] == "0" ? "v0.0.0" : match[2].hasPrefix("v") ? match[2] : "v" + match[2]
                guard let boundary = GoVersion(text) else { supported = false; continue }
                switch match[1] {
                case ">=": included = included && value >= boundary
                case ">": included = included && value > boundary
                case "<=": included = included && value <= boundary
                case "<": included = included && value < boundary
                case "==", "=": included = included && value == boundary
                case "!=": included = included && value != boundary
                default: supported = false
                }
            }
            if supported && included { return true }
            if !supported { unknown = true }
        }
        return unknown ? nil : false
    }
    static func risks(_ raw: String, module: String, manifest data: Data) throws -> [String] {
        guard let selected = GoVersion(raw), data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let declared = object["Module"] as? [String: Any], declared["Path"] as? String == module else {
            throw InspectionError.blocked("Native Go manifest identity is unavailable.")
        }
        var risks = Set<String>()
        if let raw = declared["Deprecated"] {
            guard let reason = raw as? String else { throw InspectionError.blocked("Go deprecation metadata is unsupported.") }
            if !reason.isEmpty { risks.insert("deprecated") }
        }
        if let raw = object["Retract"], !(raw is NSNull) {
            guard let intervals = raw as? [[String: Any]], intervals.count <= 256 else {
                throw InspectionError.blocked("Go retraction metadata exceeds verification limits.")
            }
            for interval in intervals {
                guard let low = interval["Low"] as? String, let high = interval["High"] as? String,
                      let lower = GoVersion(low), let upper = GoVersion(high), lower <= upper else {
                    throw InspectionError.blocked("Go retraction ranges are unsupported.")
                }
                if selected >= lower && selected <= upper { risks.insert("retracted") }
            }
        }
        return risks.sorted()
    }
}
