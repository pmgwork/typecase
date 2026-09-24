import AppKit
import SwiftUI

/// An editable specimen sized to its text rather than to a fixed text-field
/// height. Like MixedTextEditor, the caret and marked text live in an NSTextView
/// with no field border or focus ring on the canvas.
struct PlaygroundTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let postScriptName: String?
    let fileURL: URL?
    let variations: [UInt32: Double]?
    let size: CGFloat
    let lineHeight: Double
    let tracking: Double
    let alignment: PlaygroundAlignment
    let textColor: Color
    let onBeginEditing: () -> Void

    var body: some View {
        PlaygroundTextView(
            text: $text,
            placeholder: placeholder,
            postScriptName: postScriptName,
            fileURL: fileURL,
            variations: variations,
            size: size,
            lineHeight: lineHeight,
            tracking: tracking,
            alignment: alignment,
            textColor: textColor,
            onBeginEditing: onBeginEditing
        )
        // A background does not contribute its own font leading to the row's
        // measured height; it just paints the sample under the empty editor.
        .background(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .font(FontResolver.shared.previewFont(
                        postScriptName: postScriptName,
                        fileURL: fileURL,
                        size: size,
                        variations: variations
                    ))
                    .lineSpacing(size * CGFloat(max(lineHeight - 1, 0)))
                    .tracking(tracking)
                    .multilineTextAlignment(alignment.textAlignment)
                    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                    .foregroundStyle(textColor.opacity(0.45))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
    }
}

private struct PlaygroundTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let postScriptName: String?
    let fileURL: URL?
    let variations: [UInt32: Double]?
    let size: CGFloat
    let lineHeight: Double
    let tracking: Double
    let alignment: PlaygroundAlignment
    let textColor: Color
    let onBeginEditing: () -> Void

    struct Appearance: Equatable {
        let postScriptName: String?
        let fileURL: URL?
        let variations: [UInt32: Double]?
        let size: CGFloat
        let lineHeight: Double
        let tracking: Double
        let alignment: PlaygroundAlignment
        let textColor: Color
    }

    private var appearance: Appearance {
        Appearance(
            postScriptName: postScriptName, fileURL: fileURL, variations: variations,
            size: size, lineHeight: lineHeight, tracking: tracking,
            alignment: alignment, textColor: textColor
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TextContainerView {
        let container = TextContainerView()
        let view = container.textView
        view.drawsBackground = false
        view.focusRingType = .none
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.applyAppearance(to: view, appearance: appearance)
        return container
    }

    func updateNSView(_ container: TextContainerView, context: Context) {
        let view = container.textView
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.string != text {
            let selected = view.selectedRange()
            coordinator.isApplying = true
            view.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            view.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
            coordinator.isApplying = false
            coordinator.lastAppearance = nil
        }
        if coordinator.lastAppearance != appearance {
            coordinator.applyAppearance(to: view, appearance: appearance)
        }
        container.invalidateIntrinsicContentSize()
    }

    /// An NSTextView has no useful fixed intrinsic height for wrapping text.
    /// Measure TextKit's actual wrapped layout. A font's built-in leading is
    /// needed between lines, but reserving it after the last line creates a
    /// large empty strip under single-line specimens with tall font metrics.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextContainerView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let font = resolvedFont
        let sample = text.isEmpty ? (placeholder.isEmpty ? " " : placeholder) : text
        let storage = NSTextStorage(string: sample, attributes: attributes(font: font))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let usedHeight = layout.usedRect(for: container).height
        let lastLineHeight = max(font.ascender - font.descender, 0)
        return CGSize(width: width, height: ceil(max(usedHeight - max(font.leading, 0), lastLineHeight)) + 2)
    }

    private var resolvedFont: NSFont {
        FontResolver.shared.nsFont(
            postScriptName: postScriptName, fileURL: fileURL,
            size: size, variations: variations
        )
    }

    private func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.lineSpacing = size * CGFloat(max(lineHeight - 1, 0))
        return [
            .font: font,
            .foregroundColor: NSColor(textColor),
            .kern: tracking,
            .paragraphStyle: paragraph,
        ]
    }

    /// Constrain the actual text view to SwiftUI's measured row width. Without
    /// this container AppKit can draw a long line beyond its proposed frame.
    final class TextContainerView: NSView {
        let textView = NSTextView()

        init() {
            super.init(frame: .zero)
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaygroundTextView
        var isApplying = false
        var lastAppearance: Appearance?

        init(parent: PlaygroundTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onBeginEditing()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? NSTextView,
                  NSApp.keyWindow?.firstResponder === view else { return }
            parent.onBeginEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                if parent.text != view.string { parent.text = view.string }
            }
        }

        func applyAppearance(to view: NSTextView, appearance: Appearance) {
            let font = parent.resolvedFont
            let attributes = parent.attributes(font: font)
            isApplying = true
            view.font = font
            view.textColor = NSColor(appearance.textColor)
            view.typingAttributes = attributes
            if !view.hasMarkedText(), let storage = view.textStorage, storage.length > 0 {
                storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
            lastAppearance = appearance
            isApplying = false
        }
    }
}
