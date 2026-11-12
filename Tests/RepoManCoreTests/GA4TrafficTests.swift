import Foundation
import XCTest
@testable import RepoManCore

final class GA4TrafficTests: XCTestCase {
    func testMissingConfigurationDisablesTraffic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try GA4TrafficConfiguration.load(from: url))
    }

    func testSharedPropertyUsesDifferentFiltersForEachWindow() throws {
        let config = GA4TrafficConfiguration(reportReader: "/core", realtimeReader: "/live", repositories: [
            "owner/site": .init(propertyId: "123", hostnames: ["site.example", "www.site.example"], streamIds: ["456"]),
            "owner/other": .init(propertyId: "123", hostnames: ["other.example"], streamIds: nil)
        ])
        let historical = try XCTUnwrap(config.query(for: "owner/site", window: .sevenDays))
        XCTAssertEqual(historical.reader, "/core")
        let report = try request(historical)
        XCTAssertEqual(report["dateRanges"] as? [[String: String]], [["startDate": "7daysAgo", "endDate": "yesterday"]])
        XCTAssertEqual(try filter(report)["fieldName"] as? String, "hostName")
        XCTAssertEqual((try filter(report)["inListFilter"] as? [String: Any])?["values"] as? [String],
                       ["site.example", "www.site.example"])
        XCTAssertNil(report["dimensions"])

        let realtime = try XCTUnwrap(config.query(for: "owner/site", window: .realtime))
        XCTAssertEqual(realtime.reader, "/live")
        let liveReport = try request(realtime)
        XCTAssertNil(liveReport["dateRanges"])
        XCTAssertEqual(try filter(liveReport)["fieldName"] as? String, "streamId")
        XCTAssertNil(config.query(for: "owner/other", window: .realtime))
    }

    func testReaderReceivesRequestAndReturnsAggregate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("reader")
        let fixture = #"""
        #!/bin/sh
        set -eu
        test "$1" = --request-json
        test "$2" = 123
        body=$(cat)
        printf '%s' "$body" | grep -q activeUsers
        case "$0" in
          */historical) printf '%s' "$body" | grep -q 7daysAgo ;;
          */reader) printf '%s' "$body" | grep -q streamId ;;
        esac
        printf '%s' '{"metricHeaders":[{"name":"activeUsers"}],"rowCount":1,"rows":[{"metricValues":[{"value":"42"}]}]}'
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let live = GA4TrafficQuery(reader: executable.path, propertyId: "123", window: .realtime, filterValues: ["456"])
        XCTAssertEqual(try live.load(), 42)
        let historical = directory.appendingPathComponent("historical")
        try FileManager.default.copyItem(at: executable, to: historical)
        let report = GA4TrafficQuery(reader: historical.path, propertyId: "123", window: .sevenDays, filterValues: [])
        XCTAssertEqual(try report.load(), 42)
    }

    func testEmptyReportIsZeroAndIncompleteReportsAreUnavailable() throws {
        let headers = #""metricHeaders":[{"name":"activeUsers"}]"#
        func decode(_ fields: String) throws -> Int {
            try GA4TrafficQuery.decode(Data("{\(headers),\(fields)}".utf8))
        }
        XCTAssertEqual(try decode(#""rowCount":0"#), 0)
        XCTAssertThrowsError(try decode(#""rowCount":1"#))
        XCTAssertThrowsError(try decode(#""rowCount":0,"metadata":{"subjectToThresholding":true}"#))
        XCTAssertThrowsError(try decode(#""rowCount":0,"metadata":{"dataLossFromOtherRow":true}"#))
        XCTAssertThrowsError(try decode(#""rowCount":1,"rows":[{"metricValues":[{"value":"-1"}]}]"#))
        XCTAssertThrowsError(try decode(#""rowCount":0,"dimensionHeaders":[{"name":"date"}]"#))
    }

    func testPortugalIsExcludedForScopedAndPropertyWideReportsInBothWindows() throws {
        for window in GA4TrafficWindow.allCases {
            for values in [[], ["456"]] {
                let report = try request(GA4TrafficQuery(reader: "/reader", propertyId: "123",
                                                       window: window, filterValues: values))
                let expression = try XCTUnwrap(report["dimensionFilter"] as? [String: Any])
                let exclusion: [String: Any]
                if values.isEmpty {
                    exclusion = expression
                    XCTAssertNil(expression["andGroup"])
                } else {
                    let group = try XCTUnwrap(expression["andGroup"] as? [String: Any])
                    let expressions = try XCTUnwrap(group["expressions"] as? [[String: Any]])
                    XCTAssertEqual(expressions.count, 2)
                    exclusion = expressions[1]
                }
                let negated = try XCTUnwrap(exclusion["notExpression"] as? [String: Any])
                let filter = try XCTUnwrap(negated["filter"] as? [String: Any])
                XCTAssertEqual(filter["fieldName"] as? String, "countryId")
                XCTAssertEqual(filter["stringFilter"] as? [String: AnyHashable],
                               ["matchType": "EXACT", "value": "PT", "caseSensitive": false])
            }
        }
    }

    private func request(_ query: GA4TrafficQuery) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: query.request()) as? [String: Any])
    }

    private func filter(_ request: [String: Any]) throws -> [String: Any] {
        let expression = try XCTUnwrap(request["dimensionFilter"] as? [String: Any])
        let group = try XCTUnwrap(expression["andGroup"] as? [String: Any])
        let expressions = try XCTUnwrap(group["expressions"] as? [[String: Any]])
        return try XCTUnwrap(expressions.first?["filter"] as? [String: Any])
    }
}
