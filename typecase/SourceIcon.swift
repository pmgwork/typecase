import SwiftUI

/// The icon of a sidebar destination: an SF Symbol, a custom symbol from the
/// asset catalog, or a bundled mark image that keeps its own colors. Service
/// navigation uses neutral SF Symbols.
nonisolated enum SourceIcon: Hashable, Sendable {
    case symbol(String)
    case customSymbol(String)
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
        case .customSymbol(let name):
            Image(name)
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

/// Shared symbol metrics for navigation destinations and folder status controls.
struct SidebarIcon: View {
    let icon: SourceIcon

    var body: some View {
        SourceIconView(icon: icon)
            .font(.system(size: 16, weight: .regular))
            .imageScale(.medium)
            .frame(width: 20, height: 20)
    }
}
