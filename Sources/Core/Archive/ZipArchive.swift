import Foundation

/// Minimal ZIP archive reader/writer supporting only the "stored" (no
/// compression) entry format. That's enough for Transcripty's `.tscripty`
/// project archive: the audio payload is already compressed in its source
/// format (or, for WAV, doesn't compress meaningfully) and the JSON manifest
/// is small. Avoids a third-party dependency for a feature with a tightly
/// scoped use case.
///
/// Limitations:
///   * No ZIP64 support — each entry must be < 4 GB and the whole archive
///     must be < 4 GB. Transcripty projects routinely fit well inside this.
///   * No directory entries; flat layout only.
///   * No compression; entries are stored verbatim.
enum ZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: LocalizedError {
        case entryTooLarge(name: String, bytes: Int)
        case archiveTooLarge(bytes: Int)
        case invalidArchive(detail: String)
        case missingEntry(name: String)
        case crcMismatch(name: String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let name, let bytes):
                let mb = bytes / (1024 * 1024)
                return "\"\(name)\" is \(mb) MB, which exceeds the 4 GB ZIP limit."
            case .archiveTooLarge(let bytes):
                let mb = bytes / (1024 * 1024)
                return "Archive size (\(mb) MB) exceeds the 4 GB ZIP limit."
            case .invalidArchive(let detail):
                return "The archive is invalid: \(detail)."
            case .missingEntry(let name):
                return "The archive is missing \"\(name)\"."
            case .crcMismatch(let name):
                return "The archive entry \"\(name)\" failed its checksum."
            }
        }
    }

    // MARK: - Write

    static func write(entries: [Entry], to url: URL) throws {
        var output = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = CRC32.compute(entry.data)
            let size = entry.data.count
            guard size <= Int(UInt32.max) else {
                throw ArchiveError.entryTooLarge(name: entry.name, bytes: size)
            }
            let lfhOffset = output.count
            guard lfhOffset <= Int(UInt32.max) else {
                throw ArchiveError.archiveTooLarge(bytes: lfhOffset)
            }

            // Local File Header (signature 0x04034b50).
            output.appendU32LE(0x04034b50)
            output.appendU16LE(20)                      // version needed to extract (2.0)
            output.appendU16LE(0)                       // general purpose flags
            output.appendU16LE(0)                       // compression: stored
            output.appendU16LE(0)                       // last mod time
            output.appendU16LE(0x21)                    // last mod date — 1980-01-01 stub
            output.appendU32LE(crc)
            output.appendU32LE(UInt32(size))
            output.appendU32LE(UInt32(size))
            output.appendU16LE(UInt16(nameBytes.count))
            output.appendU16LE(0)                       // extra field length
            output.append(nameBytes)
            output.append(entry.data)

            // Central Directory file header (signature 0x02014b50).
            centralDirectory.appendU32LE(0x02014b50)
            centralDirectory.appendU16LE(20)            // version made by
            centralDirectory.appendU16LE(20)            // version needed
            centralDirectory.appendU16LE(0)             // general purpose flags
            centralDirectory.appendU16LE(0)             // compression
            centralDirectory.appendU16LE(0)             // mod time
            centralDirectory.appendU16LE(0x21)          // mod date
            centralDirectory.appendU32LE(crc)
            centralDirectory.appendU32LE(UInt32(size))
            centralDirectory.appendU32LE(UInt32(size))
            centralDirectory.appendU16LE(UInt16(nameBytes.count))
            centralDirectory.appendU16LE(0)             // extra
            centralDirectory.appendU16LE(0)             // comment
            centralDirectory.appendU16LE(0)             // disk number start
            centralDirectory.appendU16LE(0)             // internal attrs
            centralDirectory.appendU32LE(0)             // external attrs
            centralDirectory.appendU32LE(UInt32(lfhOffset))
            centralDirectory.append(nameBytes)
        }

        let cdOffset = output.count
        let cdSize = centralDirectory.count
        guard cdOffset <= Int(UInt32.max), cdSize <= Int(UInt32.max) else {
            throw ArchiveError.archiveTooLarge(bytes: cdOffset + cdSize)
        }
        output.append(centralDirectory)

        // End of Central Directory Record (signature 0x06054b50).
        output.appendU32LE(0x06054b50)
        output.appendU16LE(0)                           // disk number
        output.appendU16LE(0)                           // disk where CD starts
        output.appendU16LE(UInt16(entries.count))
        output.appendU16LE(UInt16(entries.count))
        output.appendU32LE(UInt32(cdSize))
        output.appendU32LE(UInt32(cdOffset))
        output.appendU16LE(0)                           // comment length

        try output.write(to: url, options: .atomic)
    }

    // MARK: - Read

    static func read(from url: URL) throws -> [Entry] {
        let archive = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try parse(archive)
    }

    private static func parse(_ archive: Data) throws -> [Entry] {
        let eocdSig: UInt32 = 0x06054b50
        let cdSig: UInt32 = 0x02014b50
        let lfhSig: UInt32 = 0x04034b50

        // Find EOCD by scanning backward — it's at most 22 + 65535 bytes from
        // the end (22 byte fixed record + up to 64 KB optional comment).
        let minEOCDSize = 22
        guard archive.count >= minEOCDSize else {
            throw ArchiveError.invalidArchive(detail: "file too small to be a ZIP")
        }
        let lookback = min(archive.count, minEOCDSize + 65535)
        let searchStart = archive.count - lookback
        var eocdOffset: Int?
        var i = archive.count - minEOCDSize
        while i >= searchStart {
            if archive.u32LE(at: i) == eocdSig {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocdOffset else {
            throw ArchiveError.invalidArchive(detail: "missing end-of-central-directory record")
        }

        let entryCount = Int(archive.u16LE(at: eocdOffset + 10))
        let cdSize = Int(archive.u32LE(at: eocdOffset + 12))
        let cdStart = Int(archive.u32LE(at: eocdOffset + 16))
        guard cdStart + cdSize <= archive.count else {
            throw ArchiveError.invalidArchive(detail: "central directory out of bounds")
        }

        var entries: [Entry] = []
        var p = cdStart
        for _ in 0..<entryCount {
            guard p + 46 <= archive.count else {
                throw ArchiveError.invalidArchive(detail: "truncated central directory")
            }
            guard archive.u32LE(at: p) == cdSig else {
                throw ArchiveError.invalidArchive(detail: "bad central directory entry")
            }
            let nameLen = Int(archive.u16LE(at: p + 28))
            let extraLen = Int(archive.u16LE(at: p + 30))
            let commentLen = Int(archive.u16LE(at: p + 32))
            let lfhOffset = Int(archive.u32LE(at: p + 42))
            guard p + 46 + nameLen <= archive.count else {
                throw ArchiveError.invalidArchive(detail: "truncated CD entry name")
            }
            let nameData = archive.subData(at: p + 46, count: nameLen)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            // Resolve the entry's data via its Local File Header. Why both?
            // The CD has the authoritative name and offset; the LFH carries
            // the actual data immediately after its own (variable-length)
            // name + extra fields, which can differ from the CD's record.
            guard lfhOffset + 30 <= archive.count,
                  archive.u32LE(at: lfhOffset) == lfhSig else {
                throw ArchiveError.invalidArchive(detail: "bad local file header for \"\(name)\"")
            }
            let lfhCRC = archive.u32LE(at: lfhOffset + 14)
            let lfhSize = Int(archive.u32LE(at: lfhOffset + 22))
            let lfhNameLen = Int(archive.u16LE(at: lfhOffset + 26))
            let lfhExtraLen = Int(archive.u16LE(at: lfhOffset + 28))
            let dataStart = lfhOffset + 30 + lfhNameLen + lfhExtraLen
            guard dataStart + lfhSize <= archive.count else {
                throw ArchiveError.invalidArchive(detail: "truncated entry data for \"\(name)\"")
            }
            let entryData = archive.subData(at: dataStart, count: lfhSize)

            if CRC32.compute(entryData) != lfhCRC {
                throw ArchiveError.crcMismatch(name: name)
            }
            entries.append(Entry(name: name, data: entryData))

            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }
}

// MARK: - Data helpers (private)

private extension Data {
    mutating func appendU16LE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendU32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    func u16LE(at offset: Int) -> UInt16 {
        let lo = UInt16(self[startIndex + offset])
        let hi = UInt16(self[startIndex + offset + 1])
        return lo | (hi << 8)
    }
    func u32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    func subData(at offset: Int, count: Int) -> Data {
        let start = startIndex + offset
        return subdata(in: start..<(start + count))
    }
}

// MARK: - CRC-32

/// IEEE 802.3 CRC-32 — same polynomial used by ZIP. Table-based implementation
/// for a sane throughput on the hundreds-of-MB audio entries archive writes
/// have to checksum.
enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<rawBuf.count {
                crc = table[Int((crc ^ UInt32(bytes[i])) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
