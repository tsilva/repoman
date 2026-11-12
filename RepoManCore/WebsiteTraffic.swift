import Foundation

enum WebsiteTrafficPeriod: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var title: String { "Last \(rawValue) days" }
}

struct WebsiteTrafficTotals: Equatable, Sendable {
    let users: Int
    let sessions: Int
    let pageviews: Int
    let engagedSessions: Int
    var engagement: Double? { sessions > 0 ? Double(engagedSessions) / Double(sessions) : nil }
    static let zero = Self(users: 0, sessions: 0, pageviews: 0, engagedSessions: 0)

    static func change(_ current: Int, from previous: Int) -> Double? {
        previous > 0 ? Double(current - previous) / Double(previous) : nil
    }
}

struct WebsiteTrafficDay: Equatable, Sendable, Identifiable {
    let id: String
    let sessions: Int
}

struct WebsiteTrafficReport: Equatable, Sendable {
    let current: WebsiteTrafficTotals
    let previous: WebsiteTrafficTotals
    let days: [WebsiteTrafficDay]
    let previousDays: [WebsiteTrafficDay]
    let timeZone: String
    let fetchedAt: Date
    var sessionChange: Double? { WebsiteTrafficTotals.change(current.sessions, from: previous.sessions) }
}

/// Each row has one exact production hostname. Identical property/host bindings are fetched once.
struct WebsiteTrafficSite: Identifiable, Hashable, Sendable {
    let repository: String
    let hostname: String
    let query: WebsiteTrafficQuery?
    var id: String { query.map { "\($0.propertyId)/\(hostname)" } ?? "unavailable/\(repository)/\(hostname)" }

    static func sites(in configuration: GA4TrafficConfiguration) -> [Self] {
        var seen = Set<String>()
        let sites = configuration.repositories.keys.sorted().flatMap { repository -> [Self] in
            guard let binding = configuration.repositories[repository] else { return [] }
            let validated = configuration.query(for: repository, window: .sevenDays)
            let hosts = binding.hostnames ?? []
            guard !hosts.isEmpty else {
                return [Self(repository: repository, hostname: repository, query: nil)]
            }
            return hosts.sorted().compactMap { host in
                let hostname = host.lowercased()
                let query = validated.map {
                    WebsiteTrafficQuery(reader: $0.reader, propertyId: $0.propertyId, hostname: hostname)
                }
                let site = Self(repository: repository, hostname: hostname, query: query)
                guard seen.insert(site.id).inserted else { return nil }
                return site
            }
        }
        // Conflicting property mappings cannot both contribute to portfolio totals for the same host.
        return Dictionary(grouping: sites, by: \.hostname).values.map { group in
            let site = group[0]
            return group.count == 1 ? site : Self(repository: group.map(\.repository).sorted().joined(separator: ", "),
                                                  hostname: site.hostname, query: nil)
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }
}

struct WebsiteTrafficQuery: Hashable, Sendable {
    let reader: String
    let propertyId: String
    let hostname: String
    static let metricNames = ["activeUsers", "sessions", "screenPageViews", "engagedSessions"]

    func request(period: WebsiteTrafficPeriod, previous: Bool = false, daily: Bool = false) throws -> Data {
        let count = period.rawValue
        let start = daily || previous ? count * 2 : count
        let end = previous && !daily ? "\(count + 1)daysAgo" : "yesterday"
        var report: [String: Any] = [
            "dateRanges": [["startDate": "\(start)daysAgo", "endDate": end]],
            "metrics": (daily ? ["sessions"] : Self.metricNames).map { ["name": $0] },
            // An exact-host group retains full-window distinct users and gives empty reports explicit headers.
            "dimensions": [["name": daily ? "date" : "hostName"]],
            "dimensionFilter": GA4TrafficFilter.excludingPortugal(matching: ["filter": ["fieldName": "hostName", "stringFilter": [
                "matchType": "EXACT", "value": hostname, "caseSensitive": false
            ]]]),
            "limit": daily ? count * 2 : 1,
            "returnPropertyQuota": true
        ]
        if daily { report["dimensions"] = [["name": "date"]] }
        return try JSONSerialization.data(withJSONObject: report)
    }

    func load(period: WebsiteTrafficPeriod) throws -> WebsiteTrafficReport {
        let startedAt = Date()
        let currentData = try run(request(period: period))
        let current = try Self.decodeTotals(currentData, hostname: hostname)
        try Task.checkCancellation()
        let metadata = try JSONDecoder().decode(Response.self, from: currentData).metadata
        guard let zoneName = metadata?.timeZone, let zone = TimeZone(identifier: zoneName) else {
            throw GA4TrafficError.invalidReport
        }
        let previous = try Self.decodeTotals(run(request(period: period, previous: true)), hostname: hostname)
        try Task.checkCancellation()
        let dailyData = try run(request(period: period, daily: true))
        let days = try Self.decodeDays(dailyData, period: period, timeZone: zone, now: startedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Do not mix relative windows from different property calendar days across midnight.
        guard calendar.isDate(startedAt, inSameDayAs: Date()) else { throw GA4TrafficError.invalidReport }
        return WebsiteTrafficReport(current: current, previous: previous,
                                    days: Array(days.suffix(period.rawValue)),
                                    previousDays: Array(days.prefix(period.rawValue)),
                                    timeZone: zoneName, fetchedAt: Date())
    }

    func breakdown(period: WebsiteTrafficPeriod, dimension: String) throws -> [(String, Int)] {
        guard ["sessionDefaultChannelGroup", "landingPagePlusQueryString"].contains(dimension) else {
            throw GA4TrafficError.invalidConfiguration
        }
        guard var body = try JSONSerialization.jsonObject(with: request(period: period)) as? [String: Any] else {
            throw GA4TrafficError.invalidConfiguration
        }
        body["dimensions"] = [["name": dimension]]
        body["metrics"] = [["name": "sessions"]]
        body["limit"] = 5
        body["orderBys"] = [["metric": ["metricName": "sessions"], "desc": true]]
        let response = try Self.response(run(JSONSerialization.data(withJSONObject: body)), metrics: ["sessions"],
                                         dimensions: [dimension], maximumRows: 5, allowMoreRows: true)
        return try (response.rows ?? []).map { row in
            guard row.dimensionValues?.count == 1, row.metricValues.count == 1,
                  let count = Int(row.metricValues[0].value), count >= 0 else { throw GA4TrafficError.invalidReport }
            return (row.dimensionValues![0].value, count)
        }
    }

    private func run(_ request: Data) throws -> Data {
        let executable = URL(fileURLWithPath: reader).resolvingSymlinksInPath()
        guard reader.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path),
              try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              request.count <= 4096 else { throw GA4TrafficError.readerUnavailable }
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        return try GitHubCLI.run(["--request-json", propertyId], executable: executable, timeout: 35,
                                standardInput: input.fileHandleForReading,
                                environment: ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
    }

    static func decodeTotals(_ data: Data, hostname: String? = nil) throws -> WebsiteTrafficTotals {
        let response = try response(data, metrics: metricNames, dimensions: ["hostName"], maximumRows: 1)
        guard let row = response.rows?.first else { return .zero }
        guard row.metricValues.count == 4, row.dimensionValues?.count == 1,
              hostname == nil || row.dimensionValues?.first?.value.lowercased() == hostname?.lowercased()
        else { throw GA4TrafficError.invalidReport }
        let values = try row.metricValues.map { value -> Int in
            guard let number = Int(value.value), number >= 0 else { throw GA4TrafficError.invalidReport }
            return number
        }
        guard values[3] <= values[1] else { throw GA4TrafficError.invalidReport }
        return WebsiteTrafficTotals(users: values[0], sessions: values[1], pageviews: values[2], engagedSessions: values[3])
    }

    static func decodeDays(_ data: Data, period: WebsiteTrafficPeriod, timeZone: TimeZone, now: Date) throws -> [WebsiteTrafficDay] {
        let response = try response(data, metrics: ["sessions"], dimensions: ["date"], maximumRows: period.rawValue * 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        let today = calendar.startOfDay(for: now)
        let keys = (1...period.rawValue * 2).reversed().map {
            formatter.string(from: calendar.date(byAdding: .day, value: -$0, to: today)!)
        }
        let allowed = Set(keys)
        var values: [String: Int] = [:]
        for row in response.rows ?? [] {
            guard row.dimensionValues?.count == 1, row.metricValues.count == 1,
                  let key = row.dimensionValues?.first?.value, allowed.contains(key), values[key] == nil,
                  let count = Int(row.metricValues[0].value), count >= 0 else { throw GA4TrafficError.invalidReport }
            values[key] = count
        }
        return keys.map { WebsiteTrafficDay(id: $0, sessions: values[$0] ?? 0) }
    }

    private static func response(_ data: Data, metrics: [String], dimensions: [String], maximumRows: Int,
                                 allowMoreRows: Bool = false) throws -> Response {
        let report = try JSONDecoder().decode(Response.self, from: data)
        let count = report.rows?.count ?? 0
        guard report.metricHeaders.map(\.name) == metrics, (report.dimensionHeaders ?? []).map(\.name) == dimensions,
              count <= maximumRows, allowMoreRows ? (report.rowCount ?? 0) >= count : (report.rowCount ?? 0) == count,
              report.metadata?.subjectToThresholding != true, report.metadata?.dataLossFromOtherRow != true,
              !(report.metadata?.samplingMetadatas ?? []).contains(where: { $0.samplesReadCount != $0.samplingSpaceSize })
        else { throw GA4TrafficError.invalidReport }
        return report
    }

    private struct Response: Decodable {
        let metricHeaders: [Header]
        let dimensionHeaders: [Header]?
        let rows: [Row]?
        let rowCount: Int?
        let metadata: Metadata?
        struct Header: Decodable { let name: String }
        struct Value: Decodable { let value: String }
        struct Row: Decodable { let metricValues: [Value]; let dimensionValues: [Value]? }
        struct Metadata: Decodable {
            let timeZone: String?
            let subjectToThresholding: Bool?
            let dataLossFromOtherRow: Bool?
            let samplingMetadatas: [Sampling]?
        }
        struct Sampling: Decodable { let samplesReadCount: String; let samplingSpaceSize: String }
    }
}
