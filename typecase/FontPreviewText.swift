import AppKit
import SwiftUI

struct FontPreviewText: View {
    let text: String
    let postScriptName: String?
    let size: CGFloat
    var lines = 1
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(previewFont)
            .foregroundStyle(color)
            .lineLimit(lines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(height: size * 1.5 * CGFloat(lines), alignment: .leading)
    }

    private var previewFont: Font {
        guard let postScriptName, NSFont(name: postScriptName, size: size) != nil else {
            return .system(size: size)
        }
        return .custom(postScriptName, size: size)
    }
}
