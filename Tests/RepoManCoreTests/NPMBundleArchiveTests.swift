import Foundation
import XCTest
import zlib
@testable import RepoManCore

final class NPMBundleArchiveTests: XCTestCase {
    private let path = "package/node_modules/child/package.json"
    private let manifest = Data(#"{"name":"child","version":"1.0.0","scripts":{"install":"must never execute"}}"#.utf8)
    func testReadsOnlySelectedRegularMetadataWithoutExtractionOrExecution() throws {
        let input = try NPMBundleFixture.archive([NPMBundleFixture.member("package/package.json", data: Data(#"{"name":"parent"}"#.utf8)), NPMBundleFixture.member(path, data: manifest), NPMBundleFixture.member("package/unused.js", data: Data("throw new Error('must not run')".utf8))])
        let result = try NPMBundleArchive.manifests(input, paths: [path])
        XCTAssertEqual(result, [path: manifest])
    }
    func testTraversalAbsoluteBackslashAndDuplicatePathsAreRejected() throws {
        for name in ["../private", "/private", "package/../private", "package/dir\\private"] {
            XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member(name, data: Data()), NPMBundleFixture.member(path, data: manifest)]), paths: [path]), name)
        }
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member(path, data: manifest), NPMBundleFixture.member(path, data: manifest)]), paths: [path]))
    }
    func testLinksExtendedHeadersAndSpecialMembersRemainUnsupported() throws {
        for type: UInt8 in [49, 50, 51, 52, 54, 76, 75, 103, 120] {
            XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member(path, data: manifest, type: type)]), paths: [path]))
        }
    }
    func testMissingOversizedOrDirectoryMetadataCannotBecomeEvidence() throws {
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member("package/other.json", data: manifest)]), paths: [path]))
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member(path, data: Data(repeating: 65, count: 65_537))]), paths: [path]))
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([NPMBundleFixture.member(path + "/", data: Data(), type: 53)]), paths: [path]))
    }
    func testBadTarChecksumTruncationAndHiddenTrailingArchiveAreRejected() throws {
        var bad = NPMBundleFixture.member(path, data: manifest); bad[0] = 88
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.archive([bad]), paths: [path]))
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.gzip(NPMBundleFixture.member(path, data: manifest)), paths: [path]))
        let hidden = NPMBundleFixture.member(path, data: manifest) + Data(repeating: 0, count: 1_024) + NPMBundleFixture.member("package/hidden.json", data: manifest)
        XCTAssertThrowsError(try NPMBundleArchive.manifests(NPMBundleFixture.gzip(hidden), paths: [path]))
    }
    func testGzipCRCTruncationConcatenationAndExpansionLimitsAreEnforced() throws {
        let valid = try NPMBundleFixture.archive([NPMBundleFixture.member(path, data: manifest)])
        var corrupt = valid; corrupt[corrupt.count - 8] ^= 1
        for bytes in [corrupt, Data(valid.dropLast()), valid + valid, Data("invalid".utf8)] {
            XCTAssertThrowsError(try NPMBundleArchive.manifests(bytes, paths: [path]))
        }
        XCTAssertThrowsError(try NPMBundleArchive.manifests(valid, paths: [path], expandedLimit: 512))
        XCTAssertThrowsError(try NPMBundleArchive.manifests(valid, paths: [path], expandedLimit: -1))
    }
}

enum NPMBundleFixture {
    static func member(_ path: String, data: Data, type: UInt8 = 48) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func write(_ text: String, _ offset: Int) { for (i, byte) in text.utf8.enumerated() { header[offset + i] = byte } }
        write(path, 0); write(String(format: "%011o", data.count), 124)
        for i in 148..<156 { header[i] = 32 }
        header[156] = type; write("ustar\0", 257)
        write(String(format: "%06o", header.reduce(0, { $0 + Int($1) })) + "\0 ", 148)
        return Data(header) + data + Data(repeating: 0, count: (512 - data.count % 512) % 512)
    }
    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NSError(domain: "gzip-fixture", code: 1) }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: data.count * 2 + 64)
        let status = data.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(source.count)
            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(destination.count)
            return deflate(&stream, Z_FINISH)
        } }
        XCTAssertEqual(status, Z_STREAM_END)
        return Data(output.prefix(Int(stream.total_out)))
    }
    static func archive(_ members: [Data]) throws -> Data { try gzip(members.reduce(Data(), +) + Data(repeating: 0, count: 1_024)) }
}
