import SwiftUI

/// One saved mixed pair as a list row, built like a font row: the indicator
/// column, the pair's name, how many fonts it uses, where they come from, and
/// the specimen drawn with those fonts.
struct MixedPairRow: View, Equatable {
    let pair: FontPair
    /// The resolved family names of the two required fonts, or their stored
    /// PostScript names when a font is no longer in the library.
    let japaneseName: String
    let latinName: String
    /// The faces the pair sets, resolved against the library.
    let faces: [MixedScript: FontFace]
    let variations: [FontFace.ID: [UInt32: Double]]
    /// The short source labels of the pair's fonts, without repeats.
    let sourceLabel: String
    let previewText: String
    let previewSize: Double
    let previewTextColor: Color?
    let isSelected: Bool
    /// The selection veil shared with the regular font rows.
    let selectionTint: Color?
    /// Whether every referenced font still resolves.
    let isResolvable: Bool

    static func == (lhs: MixedPairRow, rhs: MixedPairRow) -> Bool {
        lhs.pair == rhs.pair
            && lhs.japaneseName == rhs.japaneseName
            && lhs.latinName == rhs.latinName
            && lhs.faces == rhs.faces
            && lhs.variations == rhs.variations
            && lhs.sourceLabel == rhs.sourceLabel
            && lhs.previewText == rhs.previewText
            && lhs.previewSize == rhs.previewSize
            && lhs.previewTextColor == rhs.previewTextColor
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionTint == rhs.selectionTint
            && lhs.isResolvable == rhs.isResolvable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // The pair has no activation state; the mark keeps its name
                // aligned with the font rows.
                Image(systemName: "rectangle.on.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(pair.references.count) fonts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !sourceLabel.isEmpty {
                    Text(sourceLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !isResolvable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("One of the fonts is no longer in the library")
                }
            }
            // Single-line like the font rows, so row heights stay constant.
            MixedFontPreview(
                text: previewText,
                size: previewSize,
                lines: 1,
                fonts: fonts,
                textColor: previewTextColor
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected, let selectionTint {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectionTint.opacity(0.22))
            }
        }
        // The system's accent selection is suppressed while the row draws its
        // own veil, otherwise the blue fights the custom canvas color.
        .background(TableRowEmphasisConfigurator(
            isEmphasized: selectionTint == nil,
            hidesSelectionHighlight: selectionTint != nil
        ))
        .contentShape(.rect)
        .help(name)
    }

    /// A pair is named by its two required fonts.
    private var name: String {
        FontPair.defaultName(japanese: japaneseName, latin: latinName)
    }

    private var fonts: [MixedScript: PreviewFaceSpec] {
        pair.references.reduce(into: [:]) { result, entry in
            result[entry.script] = PreviewFaceSpec(
                postScriptName: entry.reference.postScriptName,
                fileURL: faces[entry.script]?.fileURL,
                variations: variations[entry.reference.postScriptName]
            )
        }
    }
}
