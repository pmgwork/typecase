import AppKit
import CoreText
import SwiftUI

/// Caches whether a PostScript name resolves to an installed font.
///
/// `NSFont(name:size:)` performs a Core Text lookup on every call, and previews
/// query it whenever a row is evaluated. Registration changes invalidate the cache.
@MainActor
final class FontResolver {
    static let shared = FontResolver()

    private var availability: [String: Bool] = [:]
    private var descriptorsByURL: [URL: [String: CTFontDescriptor]] = [:]
    private var unreadableURLs: Set<URL> = []

    func isAvailable(_ postScriptName: String) -> Bool {
        if let cached = availability[postScriptName] { return cached }
        let available = NSFont(name: postScriptName, size: 12) != nil
        availability[postScriptName] = available
        return available
    }

    /// Whether a face can actually be drawn: installed in the process, or
    /// readable from its font file.
    func isResolvable(postScriptName: String, fileURL: URL?) -> Bool {
        if isAvailable(postScriptName) { return true }
        guard let fileURL else { return false }
        return descriptor(postScriptName: postScriptName, fileURL: fileURL) != nil
    }

    /// Resolves installed fonts by PostScript name and disabled local fonts
    /// directly from their files. Creating a CTFont from a file descriptor does
    /// not register or activate that font for the process. When `variations` is
    /// set, the font is built as a variable instance with those axis values.
    func previewFont(
        postScriptName: String?,
        fileURL: URL?,
        size: CGFloat,
        variations: [UInt32: Double]? = nil
    ) -> Font {
        guard let postScriptName else { return .system(size: size) }
        if let variations, !variations.isEmpty,
           let base = baseDescriptor(postScriptName: postScriptName, fileURL: fileURL, size: size) {
            let attributes = [kCTFontVariationAttribute: variationDictionary(variations)] as CFDictionary
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes)
            return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        }
        if isAvailable(postScriptName) {
            return .custom(postScriptName, size: size)
        }
        guard let fileURL,
              let descriptor = descriptor(postScriptName: postScriptName, fileURL: fileURL) else {
            return .system(size: size)
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return Font(font)
    }

    /// The same resolution as `previewFont`, as an `NSFont` for AppKit text
    /// views. Falls back to the system font while the face cannot be drawn.
    func nsFont(
        postScriptName: String?,
        fileURL: URL?,
        size: CGFloat,
        variations: [UInt32: Double]? = nil
    ) -> NSFont {
        guard let postScriptName else { return NSFont.systemFont(ofSize: size) }
        if let variations, !variations.isEmpty,
           let base = baseDescriptor(postScriptName: postScriptName, fileURL: fileURL, size: size) {
            let attributes = [kCTFontVariationAttribute: variationDictionary(variations)] as CFDictionary
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        if let installed = NSFont(name: postScriptName, size: size) {
            return installed
        }
        guard let fileURL,
              let descriptor = descriptor(postScriptName: postScriptName, fileURL: fileURL) else {
            return NSFont.systemFont(ofSize: size)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// Inspector lookups can read a large font file. Resolve it away from the
    /// main actor so changing selection never blocks the list's click handling.
    nonisolated static func backgroundVariableInfo(
        postScriptName: String, fileURL: URL?, size: CGFloat
    ) -> VariableFontInfo? {
        let registered = CTFontCreateWithName(postScriptName as CFString, size, nil)
        if (CTFontCopyPostScriptName(registered) as String) == postScriptName {
            return variationInfo(for: registered)
        }
        guard let fileURL,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first(where: {
                  (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == postScriptName
              }) else { return nil }
        return variationInfo(for: CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    nonisolated private static func variationInfo(for font: CTFont) -> VariableFontInfo? {
        guard let rawAxes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else { return nil }
        let axes = rawAxes.compactMap { axis -> VariableFontAxis? in
            guard let tag = (axis[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value,
                  let name = axis[kCTFontVariationAxisNameKey] as? String else { return nil }
            let minimum = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue ?? 0
            guard maximum > minimum else { return nil }
            let defaultValue = (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? minimum
            return VariableFontAxis(
                tag: tag,
                name: name,
                minimum: minimum,
                maximum: maximum,
                defaultValue: defaultValue
            )
        }
        guard !axes.isEmpty else { return nil }
        let current = (CTFontCopyVariation(font) as? [NSNumber: NSNumber]) ?? [:]
        return VariableFontInfo(
            axes: axes,
            currentValues: Dictionary(uniqueKeysWithValues: current.map { ($0.key.uint32Value, $0.value.doubleValue) })
        )
    }

    // MARK: - Resolution

    /// The descriptor of the requested instance before any axis overrides.
    private func baseDescriptor(postScriptName: String, fileURL: URL?, size: CGFloat) -> CTFontDescriptor? {
        if isAvailable(postScriptName) {
            return CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, size)
        }
        guard let fileURL else { return nil }
        return descriptor(postScriptName: postScriptName, fileURL: fileURL)
    }

    private func variationDictionary(_ variations: [UInt32: Double]) -> CFDictionary {
        var values: [NSNumber: NSNumber] = [:]
        values.reserveCapacity(variations.count)
        for (tag, value) in variations {
            values[NSNumber(value: tag)] = NSNumber(value: value)
        }
        return values as CFDictionary
    }

    private func descriptor(postScriptName: String, fileURL: URL) -> CTFontDescriptor? {
        let url = fileURL.standardizedFileURL
        if let cached = descriptorsByURL[url] {
            return cached[postScriptName]
        }
        guard !unreadableURLs.contains(url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            unreadableURLs.insert(url)
            return nil
        }

        var byName: [String: CTFontDescriptor] = [:]
        byName.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                byName[name] = descriptor
            }
        }
        descriptorsByURL[url] = byName
        return byName[postScriptName]
    }

    func invalidate() {
        availability.removeAll(keepingCapacity: true)
        descriptorsByURL.removeAll(keepingCapacity: true)
        unreadableURLs.removeAll(keepingCapacity: true)
    }

    func invalidate(names: Set<String>, urls: Set<URL>) {
        for name in names { availability.removeValue(forKey: name) }
        for url in urls {
            let normalized = url.standardizedFileURL
            descriptorsByURL.removeValue(forKey: normalized)
            unreadableURLs.remove(normalized)
        }
    }
}
