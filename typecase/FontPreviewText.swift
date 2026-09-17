import AppKit
import SwiftUI

struct FontPreviewText: View {
    let text: String
    let postScriptName: String?
    let fileURL: URL?
    let size: CGFloat
    var lines = 1
    /// Variable-font axis values to render this face with.
    var variations: [UInt32: Double]? = nil
    /// The specimen colors chosen from the toolbar. `nil` keeps the system
    /// colors, so selection emphasis and appearance changes stay native.
    var backgroundColor: Color? = nil
    var textColor: Color? = nil

    var body: some View {
        if let backgroundColor {
            specimen
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            specimen
        }
    }

    private var specimen: some View {
        Text(text)
            .font(previewFont)
            .lineLimit(lines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .modifier(SpecimenTextColor(color: textColor))
            .frame(height: size * 1.5 * CGFloat(lines), alignment: .leading)
    }

    private var previewFont: Font {
        FontResolver.shared.previewFont(
            postScriptName: postScriptName,
            fileURL: fileURL,
            size: size,
            variations: variations
        )
    }
}

/// Applies a fixed text color only when one was chosen; without one the text
/// keeps following the system, including the list's selection emphasis.
private struct SpecimenTextColor: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}
