import Foundation

/// Reads family names and descriptive metadata directly from a font file's
/// `name`, `maxp`, and `OS/2` tables.
///
/// Core Text localizes family names using the user's global language order, so an English-first
/// language list always yields English names. Reading the table lets TypeCase show the Japanese
/// name for Japanese fonts regardless of the system language.
nonisolated enum FontNameTable {
    /// Descriptive information read from a face's font file.
    struct Metadata: Sendable {
        var version: String?
        var copyright: String?
        var designer: String?
        var manufacturer: String?
        var license: String?
        var trademark: String?
        var glyphCount: Int?
        var embedding: EmbeddingPermission?

        /// The version without the "Version " prefix name tables usually carry.
        var versionNumber: String? {
            guard let version else { return nil }
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("version") else {
                return trimmed.isEmpty ? nil : trimmed
            }
            let number = trimmed.dropFirst("version".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :："))
            return number.isEmpty ? nil : number
        }
    }

    /// The embedding permission a face's `OS/2` `fsType` grants.
    enum EmbeddingPermission: Sendable {
        case installable
        case restricted
        case previewAndPrint
        case editable

        var title: String {
            switch self {
            case .installable: "Installable"
            case .restricted: "Restricted"
            case .previewAndPrint: "Preview & Print"
            case .editable: "Editable"
            }
        }
    }

    struct FamilyNames {
        var family: String?
        var typographicFamily: String?
        var japaneseFamily: String?
        var japaneseTypographicFamily: String?
    }

    /// Maps lowercased English family names to Japanese family names for every font in the file.
    static func japaneseFamilies(inFontAt url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }

        var mapping: [String: String] = [:]
        for base in subfontOffsets(in: data) {
            let names = familyNames(in: data, atSubfont: base)
            let japanese = names.japaneseTypographicFamily ?? names.japaneseFamily
            guard let japanese else { continue }
            if let family = names.family { mapping[family.lowercased()] = japanese }
            if let typographic = names.typographicFamily { mapping[typographic.lowercased()] = japanese }
        }
        return mapping
    }

    /// Reads a face's descriptive metadata. `postScriptName` selects the face
    /// inside a collection; the first face is used when it is nil or absent.
    static func metadata(forPostScriptName postScriptName: String?, inFontAt url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        var first: Metadata?
        for base in subfontOffsets(in: data) {
            guard let tables = tableDirectory(in: data, at: base) else { continue }
            var metadata = Metadata()
            if let name = tables[Tag.name] {
                let records = nameRecords(in: data, at: name.offset, length: name.length)
                metadata.version = preferredValue(in: records, id: 5)
                metadata.copyright = preferredValue(in: records, id: 0)
                metadata.designer = preferredValue(in: records, id: 9)
                metadata.manufacturer = preferredValue(in: records, id: 8)
                metadata.license = preferredValue(in: records, id: 13)
                metadata.trademark = preferredValue(in: records, id: 7)
                if let postScriptName,
                   let record = preferredValue(in: records, id: 6),
                   record.caseInsensitiveCompare(postScriptName) == .orderedSame {
                    metadata.glyphCount = glyphCount(in: data, tables: tables)
                    metadata.embedding = embeddingPermission(in: data, tables: tables)
                    return metadata
                }
            }
            if first == nil {
                metadata.glyphCount = glyphCount(in: data, tables: tables)
                metadata.embedding = embeddingPermission(in: data, tables: tables)
                first = metadata
            }
        }
        return first
    }

    // MARK: - Tables

    private enum Tag {
        static let name: UInt32 = 0x6e61_6d65 // 'name'
        static let maxp: UInt32 = 0x6d61_7870 // 'maxp'
        static let os2: UInt32 = 0x4f53_2f32 // 'OS/2'
    }

    private static func subfontOffsets(in data: Data) -> [Int] {
        if readUInt32(data, 0) == 0x7474_6366 { // 'ttcf'
            let count = Int(readUInt32(data, 8))
            guard count > 0, count <= 4096, data.count >= 12 + count * 4 else { return [] }
            return (0..<count).compactMap { index in
                let offset = Int(readUInt32(data, 12 + index * 4))
                return offset > 0 && offset < data.count ? offset : nil
            }
        }
        return [0]
    }

    /// The offset and length of every table in a subfont's table directory.
    private static func tableDirectory(in data: Data, at base: Int) -> [UInt32: (offset: Int, length: Int)]? {
        guard base >= 0, base + 12 <= data.count else { return nil }
        let tableCount = Int(readUInt16(data, base + 4))
        guard tableCount > 0, base + 12 + tableCount * 16 <= data.count else { return nil }

        var tables: [UInt32: (offset: Int, length: Int)] = [:]
        for table in 0..<tableCount {
            let record = base + 12 + table * 16
            let offset = Int(readUInt32(data, record + 8))
            let length = Int(readUInt32(data, record + 12))
            guard offset > 0, length > 0, offset + length <= data.count else { continue }
            tables[readUInt32(data, record)] = (offset, length)
        }
        return tables
    }

    private static func familyNames(in data: Data, atSubfont base: Int) -> FamilyNames {
        familyNames(in: nameRecords(in: data, atSubfont: base))
    }

    private static func nameRecords(in data: Data, atSubfont base: Int) -> [UInt16: [UInt16: String]] {
        guard let tables = tableDirectory(in: data, at: base), let name = tables[Tag.name] else { return [:] }
        return nameRecords(in: data, at: name.offset, length: name.length)
    }

    /// Windows- and Macintosh-platform name strings by name ID and language ID.
    private static func nameRecords(in data: Data, at tableOffset: Int, length: Int) -> [UInt16: [UInt16: String]] {
        guard tableOffset + 6 <= data.count, length > 6 else { return [:] }
        let count = Int(readUInt16(data, tableOffset + 2))
        let stringOffset = tableOffset + Int(readUInt16(data, tableOffset + 4))

        var records: [UInt16: [UInt16: String]] = [:]
        for record in 0..<count {
            let entry = tableOffset + 6 + record * 12
            guard entry + 12 <= data.count, entry + 12 <= tableOffset + length else { break }
            let platform = readUInt16(data, entry)
            let encoding = readUInt16(data, entry + 2)
            let language = readUInt16(data, entry + 4)
            let nameID = readUInt16(data, entry + 6)
            let stringLength = Int(readUInt16(data, entry + 8))
            let offset = stringOffset + Int(readUInt16(data, entry + 10))
            guard stringLength > 0 else { continue }

            // Windows records hold UTF-16; the Roman records of legacy Mac fonts
            // are MacRoman and count as English. Other encodings are skipped.
            let value: String?
            let storedLanguage: UInt16
            if platform == 3 {
                value = decodeUTF16(data, offset: offset, length: stringLength)
                storedLanguage = language
            } else if platform == 1, encoding == 0, language == 0 {
                value = decodeMacRoman(data, offset: offset, length: stringLength)
                storedLanguage = 0x0409
            } else {
                continue
            }
            guard let value, !value.isEmpty else { continue }
            records[nameID, default: [:]][storedLanguage] = value
        }
        return records
    }

    private static func familyNames(in records: [UInt16: [UInt16: String]]) -> FamilyNames {
        FamilyNames(
            family: records[1]?[0x0409],
            typographicFamily: records[16]?[0x0409],
            japaneseFamily: records[1]?[0x0411],
            japaneseTypographicFamily: records[16]?[0x0411]
        )
    }

    /// The English record for a name ID, falling back to the lowest language ID.
    private static func preferredValue(in records: [UInt16: [UInt16: String]], id: UInt16) -> String? {
        guard let values = records[id] else { return nil }
        if let english = values[0x0409] { return english }
        return values.min { $0.key < $1.key }?.value
    }

    private static func glyphCount(in data: Data, tables: [UInt32: (offset: Int, length: Int)]) -> Int? {
        guard let maxp = tables[Tag.maxp], maxp.length >= 6, maxp.offset + 6 <= data.count else { return nil }
        let count = Int(readUInt16(data, maxp.offset + 4))
        return count > 0 ? count : nil
    }

    private static func embeddingPermission(
        in data: Data,
        tables: [UInt32: (offset: Int, length: Int)]
    ) -> EmbeddingPermission? {
        guard let os2 = tables[Tag.os2], os2.length >= 10, os2.offset + 10 <= data.count else { return nil }
        let fsType = readUInt16(data, os2.offset + 8)
        if fsType & 0x0002 != 0 { return .restricted }
        if fsType & 0x0004 != 0 { return .previewAndPrint }
        if fsType & 0x0008 != 0 { return .editable }
        return .installable
    }

    private static func decodeUTF16(_ data: Data, offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(length / 2)
        var index = offset
        while index + 1 < offset + length {
            units.append(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func decodeMacRoman(_ data: Data, offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
        return String(data: data[offset..<offset + length], encoding: .macOSRoman)
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
