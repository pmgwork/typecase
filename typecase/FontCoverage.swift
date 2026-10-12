import CoreFoundation
import CoreText
import Foundation

/// One family's preview face, as needed for a character-coverage check.
nonisolated struct CoverageFaceQuery: Sendable, Hashable {
    let familyID: FontFamily.ID
    let postScriptName: String
    let fileURL: URL?
}

/// Decides which characters a font can display, away from the main actor.
///
/// Coverage comes from each face's character set and is cached until the font
/// file changes. Only a family's preview face is queried, matching the face the
/// list shows while it is collapsed.
actor FontCoverage {
    private struct FaceKey: Hashable {
        let postScriptName: String
        let fileURL: URL?
    }

    private var characterSets: [FaceKey: CFCharacterSet] = [:]
    private var unavailableFaces: Set<FaceKey> = []
    private var descriptorsByURL: [URL: [String: CTFontDescriptor]] = [:]
    private var unreadableURLs: Set<URL> = []

    /// The families whose preview face can display every scalar.
    func matchingFamilies(
        _ families: [CoverageFaceQuery],
        scalars: [Unicode.Scalar]
    ) -> Set<FontFamily.ID> {
        // An empty request places no constraint on the list.
        guard !scalars.isEmpty else { return Set(families.map(\.familyID)) }

        var matches: Set<FontFamily.ID> = []
        for family in families {
            if Task.isCancelled { break }
            let key = FaceKey(
                postScriptName: family.postScriptName,
                fileURL: family.fileURL?.standardizedFileURL
            )
            guard let characterSet = characterSet(for: key) else { continue }
            if scalars.allSatisfy({ CFCharacterSetIsLongCharacterMember(characterSet, $0.value) }) {
                matches.insert(family.familyID)
            }
        }
        return matches
    }

    /// The distinct characters of `text` the face cannot display, ordered by
    /// first appearance.
    func missingCharacters(postScriptName: String, fileURL: URL?, text: String) -> [String] {
        let scalars = CoverageText.requiredScalars(in: text)
        guard !scalars.isEmpty else { return [] }
        let key = FaceKey(postScriptName: postScriptName, fileURL: fileURL?.standardizedFileURL)
        guard let characterSet = characterSet(for: key) else { return [] }

        var missing: [String] = []
        var seen: Set<UInt32> = []
        for scalar in scalars where !CFCharacterSetIsLongCharacterMember(characterSet, scalar.value) {
            if seen.insert(scalar.value).inserted {
                missing.append(String(scalar))
            }
        }
        return missing
    }

    /// Every code point the face maps to a glyph, in ascending order. Only the
    /// planes the character set reports members in are scanned, so a CJK font
    /// costs two planes rather than the whole code space.
    func coveredCodePoints(postScriptName: String, fileURL: URL?) -> [UInt32] {
        let key = FaceKey(postScriptName: postScriptName, fileURL: fileURL?.standardizedFileURL)
        guard let characterSet = characterSet(for: key) else { return [] }

        var codePoints: [UInt32] = []
        for plane in 0...16 where CFCharacterSetHasMemberInPlane(characterSet, CFIndex(plane)) {
            if Task.isCancelled { return [] }
            let base = UInt32(plane) << 16
            for offset in UInt32(0)..<0x10000
            where CFCharacterSetIsLongCharacterMember(characterSet, base | offset) {
                codePoints.append(base | offset)
            }
        }
        return codePoints
    }

    /// Drops cached results for font files that were replaced or removed.
    func invalidate(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let normalized = Set(urls.map(\.standardizedFileURL))
        characterSets = characterSets.filter { key, _ in
            key.fileURL.map { !normalized.contains($0) } ?? true
        }
        unavailableFaces = unavailableFaces.filter { key in
            key.fileURL.map { !normalized.contains($0) } ?? true
        }
        for url in normalized {
            descriptorsByURL.removeValue(forKey: url)
            unreadableURLs.remove(url)
        }
    }

    // MARK: - Resolution

    private func characterSet(for key: FaceKey) -> CFCharacterSet? {
        if let cached = characterSets[key] { return cached }
        guard !unavailableFaces.contains(key) else { return nil }
        guard let font = resolveFont(for: key) else {
            unavailableFaces.insert(key)
            return nil
        }
        let characterSet = CTFontCopyCharacterSet(font)
        characterSets[key] = characterSet
        return characterSet
    }

    private func resolveFont(for key: FaceKey) -> CTFont? {
        // A registered font wins. Comparing PostScript names separates a real
        // match from the system fallback that Core Text substitutes for names
        // which are not currently available.
        let registered = CTFontCreateWithName(key.postScriptName as CFString, 12, nil)
        if (CTFontCopyPostScriptName(registered) as String) == key.postScriptName {
            return registered
        }
        guard let url = key.fileURL,
              let descriptor = descriptors(for: url)[key.postScriptName] else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    }

    private func descriptors(for url: URL) -> [String: CTFontDescriptor] {
        if let cached = descriptorsByURL[url] { return cached }
        guard !unreadableURLs.contains(url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            unreadableURLs.insert(url)
            return [:]
        }

        var byName: [String: CTFontDescriptor] = [:]
        byName.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                byName[name] = descriptor
            }
        }
        descriptorsByURL[url] = byName
        return byName
    }
}

/// The characters of a preview string a font must contain to display it.
nonisolated enum CoverageText {
    static func requiredScalars(in text: String) -> [Unicode.Scalar] {
        var seen: Set<UInt32> = []
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            // Control and format characters (newlines, variation selectors,
            // joiners) have no glyph of their own, so they never constrain
            // coverage.
            guard category != .control, category != .format else { continue }
            if seen.insert(scalar.value).inserted {
                scalars.append(scalar)
            }
        }
        return scalars
    }
}
