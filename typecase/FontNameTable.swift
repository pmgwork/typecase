import Foundation

/// Reads Japanese family names directly from a font file's `name` table.
///
/// Core Text localizes family names using the user's global language order, so an English-first
/// language list always yields English names. Reading the table lets TypeCase show the Japanese
/// name for Japanese fonts regardless of the system language.
enum FontNameTable {
    struct FamilyNames {
        var family: String?
        var typographicFamily: String?
        var japaneseFamily: String?
        var japaneseTypographicFamily: String?
    }

    /// Maps lowercased English family names to Japanese family names for every font in the file.
    static func japaneseFamilies(inFontAt url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 12 else {
            return [:]
        }

        var mapping: [String: String] = [:]
        for base in subfontOffsets(in: data) {
            guard let names = readNames(in: data, at: base) else { continue }
            let japanese = names.japaneseTypographicFamily ?? names.japaneseFamily
            if let family = names.family, let japanese {
                mapping[family.lowercased()] = japanese
            }
            if let typographic = names.typographicFamily, let japanese {
                mapping[typographic.lowercased()] = japanese
            }
        }
        return mapping
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

    private static func readNames(in data: Data, at base: Int) -> FamilyNames? {
        guard base >= 0, base + 12 <= data.count else { return nil }
        let tableCount = Int(readUInt16(data, base + 4))
        guard base + 12 + tableCount * 16 <= data.count else { return nil }

        for table in 0..<tableCount {
            let record = base + 12 + table * 16
            guard readUInt32(data, record) == 0x6e61_6d65 else { continue } // 'name'
            let offset = Int(readUInt32(data, record + 8))
            let length = Int(readUInt32(data, record + 12))
            guard offset > 0, length > 6, offset + length <= data.count else { return nil }
            return parseNameTable(in: data, at: offset)
        }
        return nil
    }

    private static func parseNameTable(in data: Data, at tableOffset: Int) -> FamilyNames {
        var names = FamilyNames()
        let count = Int(readUInt16(data, tableOffset + 2))
        let stringOffset = tableOffset + Int(readUInt16(data, tableOffset + 4))

        for record in 0..<count {
            let entry = tableOffset + 6 + record * 12
            guard entry + 12 <= data.count else { break }
            let platform = readUInt16(data, entry)
            let language = readUInt16(data, entry + 4)
            let nameID = readUInt16(data, entry + 6)
            let length = Int(readUInt16(data, entry + 8))
            let offset = stringOffset + Int(readUInt16(data, entry + 10))

            guard platform == 3, nameID == 1 || nameID == 16, length > 0 else { continue }
            guard let value = decodeUTF16(data, offset: offset, length: length) else { continue }

            switch (language, nameID) {
            case (0x0409, 1): if names.family == nil { names.family = value }
            case (0x0409, 16): if names.typographicFamily == nil { names.typographicFamily = value }
            case (0x0411, 1): if names.japaneseFamily == nil { names.japaneseFamily = value }
            case (0x0411, 16): if names.japaneseTypographicFamily == nil { names.japaneseTypographicFamily = value }
            default: break
            }
        }
        return names
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
