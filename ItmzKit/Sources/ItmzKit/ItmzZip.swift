import Foundation
import Compression

/// Errors raised while reading or writing the ZIP container of an .itmz file.
enum ItmzZipError: LocalizedError, Equatable {
    case notAZipArchive
    case unsupportedZip64
    case unsupportedCompression(method: UInt16, entry: String)
    case corruptEntry(String)

    var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "The file is not a ZIP archive."
        case .unsupportedZip64:
            return "ZIP64 archives are not supported."
        case let .unsupportedCompression(method, entry):
            return "Entry \"\(entry)\" uses unsupported compression method \(method)."
        case let .corruptEntry(entry):
            return "Entry \"\(entry)\" is damaged."
        }
    }
}

/// One file inside a ZIP archive. Order of entries is preserved on read and write.
struct ItmzZipEntry: Equatable {
    var name: String
    var data: Data
}

/// Minimal ZIP reader/writer: "stored" and "deflate" entries, no ZIP64, no encryption.
/// That is everything iThoughts produces. Uses Apple's Compression framework
/// (COMPRESSION_ZLIB is raw DEFLATE, RFC 1951), so it works inside the App Sandbox
/// without launching external tools.
enum ItmzZip {
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let utf8NameFlag: UInt16 = 0x0800

    // MARK: Reading

    static func read(_ archive: Data) throws -> [ItmzZipEntry] {
        let bytes = [UInt8](archive)
        guard let eocd = findEndOfCentralDirectory(bytes) else {
            throw ItmzZipError.notAZipArchive
        }

        let entryCount = try Int(u16(bytes, eocd + 10))
        let centralOffsetRaw = try u32(bytes, eocd + 16)
        if entryCount == 0xFFFF || centralOffsetRaw == 0xFFFF_FFFF {
            throw ItmzZipError.unsupportedZip64
        }

        var entries: [ItmzZipEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = Int(centralOffsetRaw)

        for _ in 0..<entryCount {
            guard try u32(bytes, cursor) == centralHeaderSignature else {
                throw ItmzZipError.notAZipArchive
            }
            let flags = try u16(bytes, cursor + 8)
            let method = try u16(bytes, cursor + 10)
            let expectedCRC = try u32(bytes, cursor + 16)
            let compressedSize = try u32(bytes, cursor + 20)
            let uncompressedSize = try u32(bytes, cursor + 24)
            let nameLength = try Int(u16(bytes, cursor + 28))
            let extraLength = try Int(u16(bytes, cursor + 30))
            let commentLength = try Int(u16(bytes, cursor + 32))
            let localOffset = try u32(bytes, cursor + 42)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ItmzZipError.unsupportedZip64
            }

            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else {
                throw ItmzZipError.notAZipArchive
            }
            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
            let name = decodeName(nameBytes, isUTF8: flags & utf8NameFlag != 0)
            cursor = nameStart + nameLength + extraLength + commentLength

            if name.hasSuffix("/") {
                continue // directory entry
            }

            // Sizes come from the central directory: local headers may defer them to a data descriptor.
            let local = Int(localOffset)
            guard try u32(bytes, local) == localHeaderSignature else {
                throw ItmzZipError.corruptEntry(name)
            }
            let localNameLength = try Int(u16(bytes, local + 26))
            let localExtraLength = try Int(u16(bytes, local + 28))
            let dataStart = local + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + Int(compressedSize)
            guard dataStart <= dataEnd, dataEnd <= bytes.count else {
                throw ItmzZipError.corruptEntry(name)
            }
            let raw = Array(bytes[dataStart..<dataEnd])

            let content: [UInt8]
            switch method {
            case 0:
                content = raw
            case 8:
                content = try inflate(raw, expectedSize: Int(uncompressedSize), entry: name)
            default:
                throw ItmzZipError.unsupportedCompression(method: method, entry: name)
            }

            guard content.count == Int(uncompressedSize), ItmzCRC32.checksum(content) == expectedCRC else {
                throw ItmzZipError.corruptEntry(name)
            }
            entries.append(ItmzZipEntry(name: name, data: Data(content)))
        }

        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else {
            return nil
        }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var position = bytes.count - 22
        while position >= lowest {
            if bytes[position] == 0x50, bytes[position + 1] == 0x4B,
               bytes[position + 2] == 0x05, bytes[position + 3] == 0x06 {
                return position
            }
            position -= 1
        }
        return nil
    }

    private static func decodeName(_ bytes: [UInt8], isUTF8: Bool) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) {
            return utf8
        }
        // Legacy archives use CP437; Latin-1 is close enough for file names we only carry through.
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func inflate(_ input: [UInt8], expectedSize: Int, entry: String) throws -> [UInt8] {
        if expectedSize == 0 {
            return []
        }
        guard !input.isEmpty else {
            throw ItmzZipError.corruptEntry(entry)
        }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                compression_decode_buffer(
                    destination.baseAddress!, destination.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ItmzZipError.corruptEntry(entry)
        }
        return output
    }

    // MARK: Writing

    /// Writes entries in the given order. Data that does not shrink is stored uncompressed.
    static func write(_ entries: [ItmzZipEntry], date: Date = Date()) throws -> Data {
        let (dosTime, dosDate) = dosTimestamp(date)
        var output: [UInt8] = []
        var central: [UInt8] = []

        for entry in entries {
            let content = [UInt8](entry.data)
            let nameBytes = Array(entry.name.utf8)
            guard content.count < 0xFFFF_FFFF, nameBytes.count <= 0xFFFF, output.count < 0xFFFF_FFFF else {
                throw ItmzZipError.unsupportedZip64
            }

            let crc = ItmzCRC32.checksum(content)
            var method: UInt16 = 0
            var payload = content
            if let compressed = deflate(content), compressed.count < content.count {
                method = 8
                payload = compressed
            }
            let localOffset = UInt32(output.count)

            put32(localHeaderSignature, into: &output)
            put16(20, into: &output)                 // version needed
            put16(utf8NameFlag, into: &output)       // flags: UTF-8 names
            put16(method, into: &output)
            put16(dosTime, into: &output)
            put16(dosDate, into: &output)
            put32(crc, into: &output)
            put32(UInt32(payload.count), into: &output)
            put32(UInt32(content.count), into: &output)
            put16(UInt16(nameBytes.count), into: &output)
            put16(0, into: &output)                  // extra length
            output.append(contentsOf: nameBytes)
            output.append(contentsOf: payload)

            put32(centralHeaderSignature, into: &central)
            put16(0x0314, into: &central)            // made by: Unix, spec 2.0
            put16(20, into: &central)
            put16(utf8NameFlag, into: &central)
            put16(method, into: &central)
            put16(dosTime, into: &central)
            put16(dosDate, into: &central)
            put32(crc, into: &central)
            put32(UInt32(payload.count), into: &central)
            put32(UInt32(content.count), into: &central)
            put16(UInt16(nameBytes.count), into: &central)
            put16(0, into: &central)                 // extra length
            put16(0, into: &central)                 // comment length
            put16(0, into: &central)                 // disk number
            put16(0, into: &central)                 // internal attributes
            put32(0o100644 << 16, into: &central)    // external attributes: regular file rw-r--r--
            put32(localOffset, into: &central)
            central.append(contentsOf: nameBytes)
        }

        guard entries.count < 0xFFFF, output.count < 0xFFFF_FFFF else {
            throw ItmzZipError.unsupportedZip64
        }
        let centralOffset = UInt32(output.count)
        output.append(contentsOf: central)
        put32(endOfCentralDirectorySignature, into: &output)
        put16(0, into: &output)
        put16(0, into: &output)
        put16(UInt16(entries.count), into: &output)
        put16(UInt16(entries.count), into: &output)
        put32(UInt32(central.count), into: &output)
        put32(centralOffset, into: &output)
        put16(0, into: &output)
        return Data(output)
    }

    private static func deflate(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else {
            return nil
        }
        let capacity = input.count + input.count / 10 + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                compression_encode_buffer(
                    destination.baseAddress!, destination.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            return nil
        }
        return Array(output[0..<written])
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let day = (year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }

    // MARK: Little-endian helpers

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ItmzZipError.notAZipArchive
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ItmzZipError.notAZipArchive
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func put16(_ value: UInt16, into array: inout [UInt8]) {
        array.append(UInt8(value & 0xFF))
        array.append(UInt8(value >> 8))
    }

    private static func put32(_ value: UInt32, into array: inout [UInt8]) {
        array.append(UInt8(value & 0xFF))
        array.append(UInt8((value >> 8) & 0xFF))
        array.append(UInt8((value >> 16) & 0xFF))
        array.append(UInt8(value >> 24))
    }
}

/// CRC-32 (IEEE 802.3), as required by the ZIP format.
enum ItmzCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        checksum([UInt8](data))
    }
}
