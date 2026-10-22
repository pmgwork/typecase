import AppKit
import SwiftUI

/// A native AppKit pop-up with a consistent, compact width. SwiftUI's menu
/// Picker sizes its button to its current title, leaving short weights much
/// narrower than the font selector even with the same frame on both views.
struct TypographyPopUp: NSViewRepresentable {
    static let styleWidth: CGFloat = 92
    static let height: CGFloat = 30

    struct Option: Equatable {
        let id: String?
        let title: String
    }

    let title: String
    let options: [Option]
    @Binding var selection: String?
    var enabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> PopUpContainer {
        let container = PopUpContainer()
        let button = container.button
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Self.styleWidth, height: Self.height)
    }

    func updateNSView(_ container: PopUpContainer, context: Context) {
        let button = container.button
        let coordinator = context.coordinator
        coordinator.selection = $selection
        if coordinator.options != options {
            button.removeAllItems()
            for option in options { button.addItem(withTitle: option.title) }
            coordinator.options = options
        }
        let selectedIndex = options.firstIndex { $0.id == selection } ?? 0
        if button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }

    /// Keep the button's actual frame inside the fixed-width hosting view.
    /// A bare NSPopUpButton can report a wider intrinsic size based on its
    /// longest menu item and draw outside SwiftUI's frame.
    final class PopUpContainer: NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)

        init() {
            super.init(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.heightAnchor.constraint(equalToConstant: 26),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String?>
        var options: [Option] = []

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        @objc func didChange(_ button: NSPopUpButton) {
            guard options.indices.contains(button.indexOfSelectedItem) else { return }
            selection.wrappedValue = options[button.indexOfSelectedItem].id
        }
    }
}

