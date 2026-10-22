import Foundation

/// Reads family names and descriptive metadata directly from a font file's
/// `name`, `maxp`, and `OS/2` tables.
///
/// Core Text localizes family names using the user's global language order, so an English-first
/// language list always yields English names. Reading the table lets TypeCase show the Japanese,
/// Chinese, or Korean name for those fonts regardless of the system language.
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
            case .installable: String(localized: "Installable")
            case .restricted: String(localized: "Restricted")
            case .previewAndPrint: String(localized: "Preview & Print")
            case .editable: String(localized: "Editable")
            }
        }
    }

    struct FamilyNames {
        var family: String?
        var typographicFamily: String?
        var localizedFamilies: [FontLanguage: String] = [:]
        var localizedTypographicFamilies: [FontLanguage: String] = [:]
    }

    /// A family's localized names and design languages, as read from one file.
    struct LocalizedFamily: Codable, Sendable {
        var names: [FontLanguage: String] = [:]
        /// The scripts the font is designed for, from the `meta` table's
        /// `dlng` records. Empty when the file carries no `meta` table.
        var designLanguages: Set<FontLanguage> = []
    }

    /// Maps lowercased English family names to the localized family names and
    /// design languages found in the file's `name` and `meta` tables.
    static func localizedFamilies(inFontAt url: URL) -> [String: LocalizedFamily] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }

        var mapping: [String: LocalizedFamily] = [:]
        for base in subfontOffsets(in: data) {
            let names = familyNames(in: data, atSubfont: base)
            // A typographic family name is the more precise one, so it wins
            // when a face carries both name IDs in the same language.
            var localized = names.localizedTypographicFamilies
            localized.merge(names.localizedFamilies) { current, _ in current }
            let designLanguages = designLanguages(in: data, atSubfont: base)
            guard !localized.isEmpty || !designLanguages.isEmpty else { continue }
            for name in [names.family, names.typographicFamily] {
                guard let key = name?.lowercased() else { continue }
                var family = mapping[key] ?? LocalizedFamily()
                family.names.merge(localized) { current, _ in current }
                family.designLanguages.formUnion(designLanguages)
                mapping[key] = family
            }
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
        static let meta: UInt32 = 0x6d65_7461 // 'meta'
        static let dlng: UInt32 = 0x646c_6e67 // 'dlng'
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

    /// The design languages a subfont targets, read from its `meta` table.
    ///
    /// Core Text's language list reports what a font can display, which for CJK
    /// fonts includes scripts the design does not target. The `dlng` records
    /// name the scripts the font was designed for, so a Chinese font that
    /// carries a Japanese alias name is still recognized as Chinese.
    private static func designLanguages(in data: Data, atSubfont base: Int) -> Set<FontLanguage> {
        guard let tables = tableDirectory(in: data, at: base),
              let meta = tables[Tag.meta], meta.length >= 16 else { return [] }
        let count = Int(readUInt32(data, meta.offset + 12))
        guard count > 0, count <= 256 else { return [] }

        var languages: Set<FontLanguage> = []
        for record in 0..<count {
            let entry = meta.offset + 16 + record * 12
            guard entry + 12 <= meta.offset + meta.length else { break }
            guard readUInt32(data, entry) == Tag.dlng else { continue }
            let offset = meta.offset + Int(readUInt32(data, entry + 4))
            let length = Int(readUInt32(data, entry + 8))
            guard offset > 0, length > 0, offset + length <= data.count,
                  let value = String(data: data[offset..<offset + length], encoding: .utf8) else { continue }
            let codes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            languages.formUnion(FontLanguage.detected(in: codes))
        }
        return languages
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
            localizedFamilies: localizedNames(in: records, id: 1),
            localizedTypographicFamilies: localizedNames(in: records, id: 16)
        )
    }

    /// The localized family names for a name ID, keyed by the language their
    /// OpenType language ID names.
    private static func localizedNames(in records: [UInt16: [UInt16: String]], id: UInt16) -> [FontLanguage: String] {
        guard let values = records[id] else { return [:] }
        var names: [FontLanguage: String] = [:]
        // Sorted keys keep the result stable when a language has several
        // regional records, such as zh-CN and zh-SG.
        for openTypeID in values.keys.sorted() {
            guard let value = values[openTypeID],
                  let language = fontLanguage(forOpenTypeLanguageID: openTypeID),
                  names[language] == nil else { continue }
            names[language] = value
        }
        return names
    }

    /// Maps the OpenType language IDs CJK fonts use to the language whose name
    /// they carry. Only the languages TypeCase shows previews for are read.
    private static func fontLanguage(forOpenTypeLanguageID id: UInt16) -> FontLanguage? {
        switch id {
        case 0x0411: return .japanese
        case 0x0804, 0x1004: return .simplifiedChinese
        case 0x0404, 0x0C04, 0x1404: return .traditionalChinese
        case 0x0412: return .korean
        default: return nil
        }
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
