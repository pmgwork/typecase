import AppKit
import SwiftUI

/// A pop-up for long lists such as every font family: the button opens a
/// menu-like list right below it, with a search field pinned at the top and
/// about ten rows that scroll. The arrow keys move through the matches and
/// Return chooses. SwiftUI has no such control, so the list lives in a
/// borderless child panel styled like a menu.
struct SearchablePopUp: View {
    static let visibleRows = 10
    /// Row height and corner radius follow the system menus.
    static let rowHeight: CGFloat = 24
    static let cornerRadius: CGFloat = 14
    static let minimumListWidth: CGFloat = 220

    let title: String
    let searchPrompt: String
    let options: [TypographyPopUp.Option]
    @Binding var selection: String?
    var enabled = true

    @State private var list = SearchableListController()

    private var selectedTitle: String {
        options.first { $0.id == selection }?.title ?? options.first?.title ?? ""
    }

    var body: some View {
        SearchablePopUpButton(title: title, selectedTitle: selectedTitle, enabled: enabled, controller: list) {
            list.toggle(options: options, selection: $selection, searchPrompt: searchPrompt)
        }
    }
}

/// The native pop-up button, so the control matches the other pop-ups; a
/// click opens the searchable list instead of the button's menu.
private struct SearchablePopUpButton: NSViewRepresentable {
    let title: String
    let selectedTitle: String
    let enabled: Bool
    let controller: SearchableListController
    let press: () -> Void

    func makeNSView(context: Context) -> TypographyPopUp.PopUpContainer {
        let container = TypographyPopUp.PopUpContainer(button: ListPopUpButton(frame: .zero, pullsDown: false))
        container.button.cell?.lineBreakMode = .byTruncatingTail
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TypographyPopUp.PopUpContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? TypographyPopUp.styleWidth, height: TypographyPopUp.height)
    }

    func updateNSView(_ container: TypographyPopUp.PopUpContainer, context: Context) {
        let button = container.button
        (button as? ListPopUpButton)?.onPress = press
        if button.titleOfSelectedItem != selectedTitle {
            button.removeAllItems()
            button.addItem(withTitle: selectedTitle)
        }
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        controller.anchor = button
    }

    static func dismantleNSView(_ container: TypographyPopUp.PopUpContainer, coordinator: ()) {
        // The window may close with the list still open.
        (container.window?.childWindows ?? [])
            .compactMap { $0 as? SearchableListPanel }
            .forEach { $0.close() }
    }
}

/// A pop-up button that hands its click to the searchable list.
private final class ListPopUpButton: NSPopUpButton {
    var onPress: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func performClick(_ sender: Any?) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Opens and closes the list panel for one pop-up button.
@MainActor
private final class SearchableListController {
    weak var anchor: NSView?
    private var panel: SearchableListPanel?
    /// Clicking the button while the list is open first closes the list (the
    /// panel loses key); the button's own action must then not reopen it.
    private var closedAt: Date = .distantPast

    func toggle(options: [TypographyPopUp.Option], selection: Binding<String?>, searchPrompt: String) {
        if panel != nil {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            open(options: options, selection: selection, searchPrompt: searchPrompt)
        }
    }

    private func open(options: [TypographyPopUp.Option], selection: Binding<String?>, searchPrompt: String) {
        guard let anchor, let parent = anchor.window else { return }
        let buttonFrame = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = max(buttonFrame.width, SearchablePopUp.minimumListWidth)

        let list = SearchablePopUpList(
            options: options,
            selection: selection.wrappedValue,
            searchPrompt: searchPrompt,
            width: width,
            choose: { [weak self] id in
                selection.wrappedValue = id
                self?.close()
            },
            cancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: list)
        let size = hosting.fittingSize

        // The same Liquid Glass material and corner radius as a system menu.
        let background = NSGlassEffectView()
        background.cornerRadius = SearchablePopUp.cornerRadius
        background.contentView = hosting

        // Below the button, aligned to its leading edge; above it when the
        // screen has no room below.
        let gap: CGFloat = 4
        var origin = NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - gap - size.height)
        if let screen = parent.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = buttonFrame.maxY + gap }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }

        let panel = SearchableListPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = background
        panel.onDismiss = { [weak self] in self?.close() }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        // The shadow is computed from the drawn glass; taken before the
        // first draw, it outlines the whole rectangular panel instead.
        panel.display()
        panel.invalidateShadow()
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        closedAt = Date()
        panel.onDismiss = nil
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }
}

/// A borderless panel that takes key focus for its search field and closes
/// when it loses focus or the user presses Escape, as a menu does.
private final class SearchableListPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

private struct SearchablePopUpList: View {
    let options: [TypographyPopUp.Option]
    let selection: String?
    let searchPrompt: String
    let width: CGFloat
    let choose: (String?) -> Void
    let cancel: () -> Void

    @State private var query = ""
    /// The row the arrow keys point at, as an index into the matches.
    @State private var highlighted: Int?
    @FocusState private var searchFocused: Bool

    private var matches: [TypographyPopUp.Option] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    /// Fixed so the panel keeps its size while the matches narrow.
    private var listHeight: CGFloat {
        CGFloat(min(options.count, SearchablePopUp.visibleRows)) * SearchablePopUp.rowHeight + 10
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                    move(by: 1, in: matches)
                    return .handled
                }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                    move(by: -1, in: matches)
                    return .handled
                }
                .onSubmit {
                    if let highlighted, matches.indices.contains(highlighted) {
                        choose(matches[highlighted].id)
                    }
                }
                .onExitCommand(perform: cancel)

            Divider()
                .padding(.horizontal, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.offset) { index, option in
                            row(option, isHighlighted: index == highlighted)
                                .id(index)
                                .onHover { if $0 { highlighted = index } }
                                .onTapGesture { choose(option.id) }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .overlay {
                    if matches.isEmpty {
                        Text(String(localized: "No matches"))
                            .foregroundStyle(.secondary)
                    }
                }
                .task {
                    // Open on the current choice, as a native pop-up does.
                    // The scroll waits until the panel is on screen; before
                    // that the scroll view has no size to center within.
                    let index = matches.firstIndex { $0.id == selection }
                    highlighted = index
                    guard let index else { return }
                    try? await Task.sleep(for: .milliseconds(30))
                    proxy.scrollTo(index, anchor: .center)
                }
                .onChange(of: query) {
                    highlighted = self.matches.isEmpty ? nil : 0
                    proxy.scrollTo(0, anchor: .top)
                }
                .onChange(of: highlighted) { _, index in
                    if let index { proxy.scrollTo(index) }
                }
            }
            .frame(height: listHeight)
        }
        .frame(width: width)
        .defaultFocus($searchFocused, true)
    }

    /// A menu item: checkmark column, title, and the accent highlight.
    private func row(_ option: TypographyPopUp.Option, isHighlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12)
                .opacity(option.id == selection ? 1 : 0)
            Text(option.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: SearchablePopUp.rowHeight)
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .padding(.horizontal, 5)
        .contentShape(.rect)
    }

    private func move(by step: Int, in matches: [TypographyPopUp.Option]) {
        guard !matches.isEmpty else { return }
        let current = highlighted ?? (step > 0 ? -1 : matches.count)
        highlighted = min(max(current + step, 0), matches.count - 1)
    }
}
