import AppKit
import SwiftUI

/// Native pop-up menus preserve attributed category titles, including while
/// highlighted, and retain standard keyboard navigation and checkmarks.
struct LibraryFilterMenu: NSViewRepresentable {
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: 36, height: 28)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.menu = context.coordinator.makeMenu(for: viewState, settings: settings)
        button.setAccessibilityLabel(String(localized: "Filter"))
        button.toolTip = String(localized: "Filter by category and status, and choose the list order")
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var viewState: LibraryViewState?
        private weak var settings: AppSettings?

        func makeMenu(for viewState: LibraryViewState, settings: AppSettings) -> NSMenu {
            self.viewState = viewState
            self.settings = settings
            let menu = NSMenu()
            menu.autoenablesItems = false
            let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                  accessibilityDescription: String(localized: "Filter"))
            menu.addItem(title)

            let categories = NSMenu(title: String(localized: "Category"))
            categories.autoenablesItems = false
            let all = item("All Categories", action: #selector(selectCategory(_:)))
            all.state = viewState.category == nil ? .on : .off
            categories.addItem(all)
            for category in FontCategory.allCases {
                let choice = item(category.specimenTitle, action: #selector(selectCategory(_:)), value: category.rawValue)
                choice.attributedTitle = NSAttributedString(string: category.specimenTitle, attributes: [
                    .font: specimenFont(for: category)
                ])
                choice.state = viewState.category == category ? .on : .off
                categories.addItem(choice)
            }
            addSubmenu(categories, to: menu)
            menu.addItem(.separator())

            let statuses = NSMenu(title: String(localized: "Status"))
            statuses.autoenablesItems = false
            for status in ActivationFilter.allCases {
                let choice = item(status.title, action: #selector(selectStatus(_:)), value: status.rawValue)
                choice.state = viewState.activationFilter == status ? .on : .off
                statuses.addItem(choice)
            }
            addSubmenu(statuses, to: menu)
            menu.addItem(.separator())

            let order = NSMenu(title: String(localized: "Sort By"))
            order.autoenablesItems = false
            for sort in LibrarySortOrder.allCases {
                let choice = item(sort.title, action: #selector(selectOrder(_:)), value: sort.rawValue)
                choice.state = viewState.sortOrder == sort ? .on : .off
                order.addItem(choice)
            }
            order.addItem(.separator())
            let activated = item(String(localized: "Activated First"), action: #selector(toggleActivatedFirst(_:)))
            activated.state = settings.activatedFirst ? .on : .off
            order.addItem(activated)
            let favorites = item(String(localized: "Show favorites first"), action: #selector(toggleFavoritesFirst(_:)))
            favorites.state = settings.favoritesFirst ? .on : .off
            order.addItem(favorites)
            addSubmenu(order, to: menu)
            return menu
        }

        private func item(_ title: String, action: Selector, value: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            return item
        }

        private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
            let parent = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }

        private func specimenFont(for category: FontCategory) -> NSFont {
            let size = NSFont.systemFontSize
            switch category {
            case .sansSerif, .symbols, .unclassified:
                // Symbol-only fonts cannot spell the category's name legibly.
                return .systemFont(ofSize: size)
            case .serif:
                return NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
            case .monospaced:
                return .monospacedSystemFont(ofSize: size, weight: .regular)
            case .display:
                return NSFont(name: "Didot-Bold", size: size + 1) ?? .boldSystemFont(ofSize: size)
            case .script:
                return NSFont(name: "SnellRoundhand", size: size + 3) ?? .systemFont(ofSize: size)
            }
        }

        @objc private func selectCategory(_ sender: NSMenuItem) {
            viewState?.category = (sender.representedObject as? String).flatMap(FontCategory.init(rawValue:))
        }

        @objc private func selectStatus(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let status = ActivationFilter(rawValue: raw) else { return }
            viewState?.activationFilter = status
        }

        @objc private func selectOrder(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let order = LibrarySortOrder(rawValue: raw) else { return }
            viewState?.sortOrder = order
        }

        @objc private func toggleFavoritesFirst(_ sender: NSMenuItem) {
            guard let settings else { return }
            settings.favoritesFirst.toggle()
            sender.state = settings.favoritesFirst ? .on : .off
        }

        @objc private func toggleActivatedFirst(_ sender: NSMenuItem) {
            guard let settings else { return }
            settings.activatedFirst.toggle()
            sender.state = settings.activatedFirst ? .on : .off
        }
    }
}
