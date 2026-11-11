import Foundation
import XCTest
@testable import RepoManCore

final class WebsiteTrafficTests: XCTestCase {
    private let query = WebsiteTrafficQuery(reader: "/reader", propertyId: "123", hostname: "site.example")

    func testComparisonWindowsDoNotOverlapAndKeepProductionFilter() throws {
        for period in WebsiteTrafficPeriod.allCases {
            func body(previous: Bool = false, daily: Bool = false) throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: query.request(period: period, previous: previous, daily: daily)) as? [String: Any])
            }
            let current = try body(), previous = try body(previous: true), daily = try body(daily: true)
            XCTAssertEqual(current["dateRanges"] as? [[String: String]],
                           [["startDate": "\(period.rawValue)daysAgo", "endDate": "yesterday"]])
            XCTAssertEqual(previous["dateRanges"] as? [[String: String]],
                           [["startDate": "\(period.rawValue * 2)daysAgo", "endDate": "\(period.rawValue + 1)daysAgo"]])
            XCTAssertEqual(daily["dimensions"] as? [[String: String]], [["name": "date"]])
            let filter = try XCTUnwrap((current["dimensionFilter"] as? [String: Any])?["filter"] as? [String: Any])
            XCTAssertEqual(filter["fieldName"] as? String, "hostName")
            XCTAssertEqual(filter["stringFilter"] as? [String: AnyHashable],
                           ["matchType": "EXACT", "value": "site.example", "caseSensitive": false])
        }
    }

    func testSitesDeduplicateExactBindingsAndNeverInventProductionHosts() {
        let configuration = GA4TrafficConfiguration(reportReader: "/reader", realtimeReader: nil, repositories: [
            "owner/site": .init(propertyId: "123", hostnames: ["site.example", "www.site.example"], streamIds: nil),
            "owner/duplicate": .init(propertyId: "123", hostnames: ["SITE.example"], streamIds: nil),
            "owner/unknown": .init(propertyId: "123", hostnames: nil, streamIds: nil),
            "owner/invalid": .init(propertyId: "bad", hostnames: ["invalid.example"], streamIds: nil)
        ])
        let sites = WebsiteTrafficSite.sites(in: configuration)
        XCTAssertEqual(sites.count, 4)
        XCTAssertEqual(sites.compactMap(\.query).count, 2)
        XCTAssertEqual(sites.filter { $0.hostname == "site.example" }.count, 1)
        XCTAssertNil(sites.first { $0.hostname == "owner/unknown" }?.query)
        XCTAssertNil(sites.first { $0.hostname == "invalid.example" }?.query)
    }

    func testTotalsUseDistinctFullWindowUsersAndWeightedEngagementInputs() throws {
        let data = totals(values: [42, 100, 220, 60])
        let result = try WebsiteTrafficQuery.decodeTotals(data)
        XCTAssertEqual(result.users, 42)
        XCTAssertEqual(result.sessions, 100)
        XCTAssertEqual(result.engagement, 0.6)
        XCTAssertNil(WebsiteTrafficTotals.zero.engagement)
        XCTAssertNil(WebsiteTrafficTotals.change(12, from: 0))
        XCTAssertEqual(WebsiteTrafficTotals.change(0, from: 12), -1)
        XCTAssertEqual(WebsiteTrafficTotals.change(150, from: 100), 0.5)
    }

    func testConflictingPropertiesForOneHostCannotDoubleCountPortfolio() {
        let configuration = GA4TrafficConfiguration(reportReader: "/reader", realtimeReader: nil, repositories: [
            "owner/site": .init(propertyId: "123", hostnames: ["site.example"], streamIds: nil),
            "owner/other": .init(propertyId: "456", hostnames: ["site.example"], streamIds: nil)
        ])
        let sites = WebsiteTrafficSite.sites(in: configuration)
        XCTAssertEqual(sites.count, 1)
        XCTAssertNil(sites.first?.query)
    }

    func testEmptyIsZeroButTruncationThresholdingSamplingAndInvalidCountsAreRejected() throws {
        let empty = try JSONSerialization.data(withJSONObject: ["metricHeaders": WebsiteTrafficQuery.metricNames.map { ["name": $0] }, "dimensionHeaders": [["name": "hostName"]], "rowCount": 0])
        XCTAssertEqual(try WebsiteTrafficQuery.decodeTotals(empty), .zero)
        for data in [totals(values: [1, 2, 3, -1]), totals(values: [1, 2, 3, 3]),
                     totals(values: [1, 2, 3, 1], metadata: ["subjectToThresholding": true]),
                     totals(values: [1, 2, 3, 1], metadata: ["dataLossFromOtherRow": true]),
                     totals(values: [1, 2, 3, 1], metadata: ["samplingMetadatas": [["samplesReadCount": "1", "samplingSpaceSize": "2"]]])] {
            XCTAssertThrowsError(try WebsiteTrafficQuery.decodeTotals(data))
        }
        var truncated = try XCTUnwrap(JSONSerialization.jsonObject(with: totals(values: [1, 2, 3, 1])) as? [String: Any])
        truncated["rowCount"] = 2
        XCTAssertThrowsError(try WebsiteTrafficQuery.decodeTotals(JSONSerialization.data(withJSONObject: truncated)))
    }

    func testDailySeriesFillsGapsAndUsesPropertyCalendarAcrossDST() throws {
        // Europe/Lisbon changes clocks on 25 October; calendar days must still have exactly one point each.
        let now = ISO8601DateFormatter().date(from: "2026-11-11T00:30:00Z")!
        let zone = TimeZone(identifier: "Europe/Lisbon")!
        let data = daily([("20261110", 8), ("20261025", 12)])
        let days = try WebsiteTrafficQuery.decodeDays(data, period: .month, timeZone: zone, now: now)
        XCTAssertEqual(days.count, 60)
        XCTAssertEqual(days.first?.id, "20260912")
        XCTAssertEqual(days.last?.id, "20261110")
        XCTAssertEqual(Set(days.map(\.id)).count, 60)
        XCTAssertEqual(days.first { $0.id == "20261025" }?.sessions, 12)
        XCTAssertEqual(days.first { $0.id == "20261026" }?.sessions, 0)
        XCTAssertEqual(Array(days.suffix(30)).first?.id, "20261012")
        XCTAssertThrowsError(try WebsiteTrafficQuery.decodeDays(daily([("20261111", 1)]), period: .month, timeZone: zone, now: now))
        XCTAssertThrowsError(try WebsiteTrafficQuery.decodeDays(daily([("20261110", 1), ("20261110", 2)]), period: .month, timeZone: zone, now: now))
    }

    func testReaderSupportsCompleteOverviewAndTopFiveBreakdowns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = directory.appendingPathComponent("reader")
        let script = #"""
        #!/usr/bin/python3
        import json,sys
        assert sys.argv[1:] == ['--request-json', '123']
        body=json.load(sys.stdin)
        assert body['dimensionFilter']['filter']['stringFilter']['value']=='site.example'
        dims=body.get('dimensions',[])
        if dims[0]['name']=='hostName':
            result={'metricHeaders':body['metrics'],'dimensionHeaders':dims,'rows':[{'dimensionValues':[{'value':'site.example'}],'metricValues':[{'value':str(n)} for n in [42,100,220,60]]}],'rowCount':1}
        elif dims[0]['name']=='date':
            result={'metricHeaders':body['metrics'],'dimensionHeaders':dims,'rowCount':0}
        else:
            # The service can report more matching rows than a requested top-five result.
            result={'metricHeaders':body['metrics'],'dimensionHeaders':dims,'rows':[{'dimensionValues':[{'value':'Direct'}],'metricValues':[{'value':'12'}]}],'rowCount':20}
        result['metadata']={'timeZone':'Europe/Lisbon'}
        print(json.dumps(result))
        """#
        try script.write(to: reader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        let query = WebsiteTrafficQuery(reader: reader.path, propertyId: "123", hostname: "site.example")
        let result = try query.load(period: .month)
        XCTAssertEqual(result.current.users, 42)
        XCTAssertEqual(result.previous.sessions, 100)
        XCTAssertEqual(result.days.count, 30)
        XCTAssertEqual(result.previousDays.count, 30)
        let breakdown = try query.breakdown(period: .month, dimension: "sessionDefaultChannelGroup")
        XCTAssertEqual(breakdown.first?.0, "Direct")
        XCTAssertEqual(breakdown.first?.1, 12)
        XCTAssertThrowsError(try query.breakdown(period: .month, dimension: "unreviewed"))
    }

    private func totals(values: [Int], metadata: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["metricHeaders": WebsiteTrafficQuery.metricNames.map { ["name": $0] },
            "dimensionHeaders": [["name": "hostName"]], "rowCount": 1,
            "rows": [["dimensionValues": [["value": "site.example"]], "metricValues": values.map { ["value": String($0)] }]], "metadata": metadata])
    }

    private func daily(_ rows: [(String, Int)]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["metricHeaders": [["name": "sessions"]], "dimensionHeaders": [["name": "date"]],
            "rowCount": rows.count, "rows": rows.map { ["dimensionValues": [["value": $0.0]], "metricValues": [["value": String($0.1)]]] }])
    }
}
