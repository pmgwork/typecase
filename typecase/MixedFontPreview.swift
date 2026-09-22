import AppKit
import SwiftUI

/// Draws text with the faces of a mixed pair: each part of the text — Japanese,
/// Chinese, Korean, English, numbers, and symbols — uses its own face.
///
/// A face that cannot be drawn is skipped, so a pair with a missing font still
/// shows the rest of the specimen.
struct MixedFontPreview: View {
    let text: String
    let size: CGFloat
    /// The maximum number of lines, or nil to wrap the whole text.
    var lines: Int? = nil
    let fonts: [MixedScript: PreviewFaceSpec]
    /// The specimen colors chosen from the toolbar. `nil` keeps the system
    /// colors, so the window and list surfaces stay native.
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
        mixedText
            .multilineTextAlignment(.leading)
            .modifier(SpecimenTextColor(color: textColor))
    }

    @ViewBuilder
    private var mixedText: some View {
        if let lines {
            Text(MixedText.attributed(text, fonts: resolvedFonts))
                .lineLimit(lines)
                .truncationMode(.tail)
                .frame(height: size * 1.5 * CGFloat(lines), alignment: .leading)
        } else {
            Text(MixedText.attributed(text, fonts: resolvedFonts))
        }
    }

    /// The drawable fonts of the mix. A face that cannot be drawn is left out,
    /// and the text falls back to the next face that can draw it.
    private var resolvedFonts: [MixedScript: Font] {
        fonts.compactMapValues { font(for: $0) }
    }

    private func font(for spec: PreviewFaceSpec) -> Font? {
        guard FontResolver.shared.isResolvable(
            postScriptName: spec.postScriptName,
            fileURL: spec.fileURL
        ) else { return nil }
        return FontResolver.shared.previewFont(
            postScriptName: spec.postScriptName,
            fileURL: spec.fileURL,
            size: size,
            variations: spec.variations
        )
    }
}
/// An editable specimen: the text is typed directly into an `NSTextView`
/// whose characters each carry their part's font, so the typed text, the
/// caret, and IME marked text all render in place. Reads and writes plain
/// text; the mixed appearance is reapplied as attributes on every change.
struct MixedTextEditor: View {
    @Binding var text: String
    /// Shown while the text is empty, drawn with the same fonts.
    let placeholder: String
    let size: CGFloat
    let fonts: [MixedScript: PreviewFaceSpec]
    var textColor: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                MixedFontPreview(
                    text: placeholder,
                    size: size,
                    fonts: fonts,
                    textColor: textColor
                )
                .allowsHitTesting(false)
                .opacity(0.45)
            }
            MixedTextViewRepresentable(
                text: $text,
                size: size,
                fonts: fonts,
                textColor: textColor
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The AppKit text view behind `MixedTextEditor`. One `NSTextView` draws and
/// edits the text, so the caret, the selection, and IME composition all behave
/// like a normal field while every character keeps its part's font.
private struct MixedTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let size: CGFloat
    let fonts: [MixedScript: PreviewFaceSpec]
    var textColor: Color? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyMixedAttributes(
            to: textView,
            fonts: fonts,
            size: size,
            textColor: textColor,
            force: true
        )
        context.coordinator.lastKey = Self.configKey(size: size, textColor: textColor, fonts: fonts)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            context.coordinator.isApplying = true
            textView.string = text
            context.coordinator.applyMixedAttributes(
                to: textView,
                fonts: fonts,
                size: size,
                textColor: textColor,
                force: true
            )
            context.coordinator.lastKey = Self.configKey(size: size, textColor: textColor, fonts: fonts)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(
                location: min(selected.location, length),
                length: min(selected.length, max(length - min(selected.location, length), 0))
            ))
            context.coordinator.isApplying = false
        } else {
            let key = Self.configKey(size: size, textColor: textColor, fonts: fonts)
            if key != context.coordinator.lastKey {
                context.coordinator.applyMixedAttributes(
                    to: textView,
                    fonts: fonts,
                    size: size,
                    textColor: textColor,
                    force: true
                )
                context.coordinator.lastKey = key
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Identifies the appearance a config produces, so attribute work only
    /// reruns while the fonts, size, or color changed.
    private static func configKey(size: CGFloat, textColor: Color?, fonts: [MixedScript: PreviewFaceSpec]) -> String {
        var parts = [String(describing: size), String(describing: textColor)]
        for script in MixedScript.allCases {
            if let spec = fonts[script] {
                parts.append("\(script.rawValue)=\(spec.postScriptName)#\(spec.fileURL?.absoluteString ?? "-")")
            }
        }
        return parts.joined(separator: "|")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MixedTextViewRepresentable
        weak var textView: NSTextView?
        var isApplying = false
        var lastKey = ""

        init(parent: MixedTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying,
                  let textView = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                if parent.$text.wrappedValue != textView.string {
                    parent.$text.wrappedValue = textView.string
                }
                isApplying = true
                applyMixedAttributes(
                    to: textView,
                    fonts: parent.fonts,
                    size: parent.size,
                    textColor: parent.textColor,
                    force: false
                )
                lastKey = MixedTextViewRepresentable.configKey(
                    size: parent.size,
                    textColor: parent.textColor,
                    fonts: parent.fonts
                )
                isApplying = false
            }
        }

        /// Styles every character with its part's font. Runs that intersect
        /// the IME marked range keep the input method's own styling, so
        /// composition candidates and the preedit underline stay visible.
        func applyMixedAttributes(
            to textView: NSTextView,
            fonts: [MixedScript: PreviewFaceSpec],
            size: CGFloat,
            textColor: Color?,
            force: Bool
        ) {
            MainActor.assumeIsolated {
                var resolved: [MixedScript: NSFont] = [:]
                for (script, spec) in fonts {
                    resolved[script] = FontResolver.shared.nsFont(
                        postScriptName: spec.postScriptName,
                        fileURL: spec.fileURL,
                        size: size,
                        variations: spec.variations
                    )
                }
                let foreground: NSColor = textColor.map { NSColor($0) } ?? .labelColor
                let defaultFont = resolved[.latin] ?? resolved[.japanese] ?? NSFont.systemFont(ofSize: size)
                textView.font = defaultFont
                textView.typingAttributes = [
                    .font: defaultFont,
                    .foregroundColor: foreground,
                ]
                guard let storage = textView.textStorage, !storage.string.isEmpty else { return }
                let marked = textView.markedRange()
                let string = storage.string
                var runs: [(range: NSRange, script: MixedScript)] = []
                var runScript: MixedScript?
                var runStart = 0
                var runLength = 0
                var location = 0
                for character in string {
                    let script = MixedText.script(of: character)
                    let length = character.utf16.count
                    if script == runScript {
                        runLength += length
                    } else {
                        if let current = runScript {
                            runs.append((NSRange(location: runStart, length: runLength), current))
                        }
                        runScript = script
                        runStart = location
                        runLength = length
                    }
                    location += length
                }
                if let current = runScript {
                    runs.append((NSRange(location: runStart, length: runLength), current))
                }
                storage.beginEditing()
                for run in runs {
                    if marked.location != NSNotFound,
                       NSIntersectionRange(run.range, marked).length > 0 {
                        continue
                    }
                    var font: NSFont?
                    for candidate in MixedText.fallbackScripts(for: run.script) {
                        if let resolvedFont = resolved[candidate] {
                            font = resolvedFont
                            break
                        }
                    }
                    guard let font else { continue }
                    storage.addAttributes(
                        [.font: font, .foregroundColor: foreground],
                        range: run.range
                    )
                }
                storage.endEditing()
                _ = force
            }
        }
    }
}
