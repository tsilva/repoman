import Foundation
import zlib

/// Reads selected regular metadata members in memory; never extracts or executes archive contents.
enum NPMBundleArchive {
    static let maximumCompressedBytes = 16 * 1_024 * 1_024
    static let maximumExpandedBytes = 64 * 1_024 * 1_024
    static func manifests(_ compressed: Data, paths: Set<String>, expandedLimit: Int = maximumExpandedBytes) throws -> [String: Data] {
        guard !compressed.isEmpty, compressed.count <= maximumCompressedBytes,
              expandedLimit > 0, expandedLimit <= maximumExpandedBytes, !paths.isEmpty, paths.count <= 256,
              paths.allSatisfy({ DependencyLockInventory.safePath($0) && $0.hasPrefix("package/") && $0.hasSuffix("/package.json") }) else { throw failure() }
        let bytes = try expand(compressed, limit: expandedLimit)
        guard bytes.count >= 1_024, bytes.count % 512 == 0 else { throw failure() }
        var offset = 0, count = 0, names = Set<String>(), found: [String: Data] = [:]
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) {
                guard offset + 1_024 <= bytes.count, bytes[offset...].allSatisfy({ $0 == 0 }), Set(found.keys) == paths else { throw failure() }
                return found
            }
            count += 1
            guard count <= 10_000, let checksum = octal(header[148..<156]),
                  header.enumerated().reduce(0, { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }) == checksum,
                  let size = octal(header[124..<136]), size <= expandedLimit,
                  let name = field(header[0..<100]), let prefix = field(header[345..<500]) else { throw failure() }
            let magic = Array(header[257..<263])
            guard magic == Array("ustar\0".utf8) || magic == Array("ustar ".utf8) || magic.allSatisfy({ $0 == 0 }) && prefix.isEmpty else { throw failure() }
            let rawPath = (prefix.isEmpty ? "" : prefix + "/") + name
            let directory = header[156] == 53
            let path = directory && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard DependencyLockInventory.safePath(path), names.insert(path).inserted,
                  header[156] == 0 || header[156] == 48 || directory,
                  !directory || size == 0 else { throw failure() }
            let start = offset + 512, padded = ((size + 511) / 512) * 512
            guard padded <= bytes.count - start else { throw failure() }
            if paths.contains(path) {
                guard !directory, size <= 65_536 else { throw failure() }
                found[path] = Data(bytes[start..<start + size])
            }
            offset = start + padded
        }
        throw failure()
    }
    private static func field(_ bytes: ArraySlice<UInt8>) -> String? {
        let head = bytes.prefix(while: { $0 != 0 })
        guard bytes.dropFirst(head.count).allSatisfy({ $0 == 0 }), let text = String(bytes: head, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    private static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard !value.isEmpty, value.allSatisfy({ ("0"..."7").contains(String($0)) }) else { return nil }
        return Int(value, radix: 8)
    }
    private static func expand(_ data: Data, limit: Int) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw failure() }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: limit + 1)
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        // inflate validates gzip framing and CRC. Reject trailing/concatenated streams and bombs.
        guard status == Z_STREAM_END, stream.avail_in == 0, stream.total_out <= limit else { throw failure() }
        output.removeSubrange(Int(stream.total_out)..<output.count)
        return output
    }
    private static func failure() -> InspectionError { .blocked("Bundled package archive is unsupported, ambiguous, corrupt or exceeds inspection limits.") }
}
