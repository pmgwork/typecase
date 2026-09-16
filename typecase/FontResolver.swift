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

    /// Resolves installed fonts by PostScript name and disabled local fonts
    /// directly from their files. Creating a CTFont from a file descriptor does
    /// not register or activate that font for the process.
    func previewFont(postScriptName: String?, fileURL: URL?, size: CGFloat) -> Font {
        guard let postScriptName else { return .system(size: size) }
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
}
