import Foundation

enum GA4TrafficWindow: String, CaseIterable, Hashable, Sendable {
    case sevenDays
    case realtime

    var refreshInterval: TimeInterval { self == .realtime ? 60 : 3600 }
}

struct GA4TrafficConfiguration: Decodable, Sendable {
    let reportReader: String
    let realtimeReader: String?
    let repositories: [String: Binding]

    struct Binding: Decodable, Sendable {
        let propertyId: String
        let hostnames: [String]?
        let streamIds: [String]?
    }

    static func repositoryKey(for remote: String?) -> String? {
        GitHubCI.repository(remote).map { "\($0.owner)/\($0.name)".lowercased() }
    }

    static func load(from url: URL) throws -> Self? {
        let input: FileHandle
        do {
            guard try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw GA4TrafficError.invalidConfiguration
            }
            input = try FileHandle(forReadingFrom: url)
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        defer { try? input.close() }
        let limit = 128 * 1024
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GA4TrafficError.invalidConfiguration }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func query(for repository: String, window: GA4TrafficWindow) -> GA4TrafficQuery? {
        guard let binding = repositories[repository],
              binding.propertyId.range(of: #"^[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil else { return nil }
        switch window {
        case .sevenDays:
            let hosts = binding.hostnames ?? []
            guard binding.hostnames?.isEmpty != true, hosts.count <= 12,
                  hosts.allSatisfy({ $0.utf8.count <= 253 && $0.range(of: #"^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9])?$"#, options: .regularExpression) != nil }) else { return nil }
            return GA4TrafficQuery(reader: reportReader, propertyId: binding.propertyId, window: window,
                                   filterValues: Set(hosts.map { $0.lowercased() }).sorted())
        case .realtime:
            let streams = binding.streamIds ?? []
            guard let realtimeReader, binding.streamIds?.isEmpty != true,
                  binding.hostnames == nil || !streams.isEmpty,
                  streams.count <= 16,
                  streams.allSatisfy({ $0.range(of: #"^[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil }) else { return nil }
            return GA4TrafficQuery(reader: realtimeReader, propertyId: binding.propertyId, window: window,
                                   filterValues: Set(streams).sorted())
        }
    }
}

struct GA4TrafficReading: Equatable, Sendable {
    let count: Int?
    let observedAt: Date?
    let isStale: Bool

    static let unavailable = Self(count: nil, observedAt: nil, isStale: false)
}

enum GA4TrafficError: Error {
    case invalidConfiguration, readerUnavailable, invalidReport
}

enum GA4TrafficFilter {
    /// Apply before aggregation so distinct users and every derived metric share the same audience.
    /// countryId is supported by both the historical and Realtime Data APIs.
    static func excludingPortugal(matching scope: [String: Any]? = nil) -> [String: Any] {
        let exclusion: [String: Any] = ["notExpression": ["filter": [
            "fieldName": "countryId",
            "stringFilter": ["matchType": "EXACT", "value": "PT", "caseSensitive": false]
        ]]]
        guard let scope else { return exclusion }
        return ["andGroup": ["expressions": [scope, exclusion]]]
    }
}

struct GA4TrafficQuery: Hashable, Sendable {
    let reader: String
    let propertyId: String
    let window: GA4TrafficWindow
    let filterValues: [String]

    func request() throws -> Data {
        var report: [String: Any] = ["metrics": [["name": "activeUsers"]], "limit": 1]
        if window == .sevenDays {
            report["dateRanges"] = [["startDate": "7daysAgo", "endDate": "yesterday"]]
        }
        let scope: [String: Any]? = filterValues.isEmpty ? nil : ["filter": [
                "fieldName": window == .realtime ? "streamId" : "hostName",
                "inListFilter": ["values": filterValues, "caseSensitive": window == .realtime]
        ]]
        report["dimensionFilter"] = GA4TrafficFilter.excludingPortugal(matching: scope)
        return try JSONSerialization.data(withJSONObject: report)
    }

    func load() throws -> Int {
        let executable = URL(fileURLWithPath: reader).resolvingSymlinksInPath()
        guard reader.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path),
              try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw GA4TrafficError.readerUnavailable
        }
        let request = try request()
        // A small prefilled pipe gives the reader EOF without depending on its startup or writes after exit.
        guard request.count <= 4096 else { throw GA4TrafficError.invalidConfiguration }
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let output = try GitHubCLI.run(["--request-json", propertyId], executable: executable, timeout: 35,
                                       standardInput: input.fileHandleForReading,
                                       environment: ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        return try Self.decode(output)
    }

    static func decode(_ data: Data) throws -> Int {
        let report = try JSONDecoder().decode(Report.self, from: data)
        let rows = report.rows ?? []
        guard report.metricHeaders.map(\.name) == ["activeUsers"],
              report.dimensionHeaders?.isEmpty != false,
              report.metadata?.subjectToThresholding != true, report.metadata?.dataLossFromOtherRow != true,
              (report.rowCount ?? 0) == rows.count, rows.count <= 1 else { throw GA4TrafficError.invalidReport }
        guard let row = rows.first else { return 0 }
        guard row.metricValues.count == 1, let count = Int(row.metricValues[0].value), count >= 0 else {
            throw GA4TrafficError.invalidReport
        }
        return count
    }

    private struct Report: Decodable {
        let metricHeaders: [Header]
        let dimensionHeaders: [Header]?
        let rows: [Row]?
        let rowCount: Int?
        let metadata: Metadata?

        struct Header: Decodable { let name: String }
        struct Row: Decodable {
            let metricValues: [Value]
            struct Value: Decodable { let value: String }
        }
        struct Metadata: Decodable {
            let subjectToThresholding: Bool?
            let dataLossFromOtherRow: Bool?
        }
    }
}
