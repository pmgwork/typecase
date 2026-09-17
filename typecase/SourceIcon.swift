import SwiftUI

/// The icon of a sidebar destination: an SF Symbol, or a bundled mark image
/// that keeps its own colors. The font services ship their colored brand
/// marks; everything else uses SF Symbols.
nonisolated enum SourceIcon: Hashable, Sendable {
    case symbol(String)
    case asset(String)
}

/// Draws a `SourceIcon`: symbols take the current foreground style, assets
/// keep their own colors.
struct SourceIconView: View {
    let icon: SourceIcon
    var assetSize: CGFloat = 18

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
        case .asset(let name):
            Image(name)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: assetSize, height: assetSize)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: assetSize * 2 / 9,
                        style: .continuous
                    )
                )
        }
    }
}
