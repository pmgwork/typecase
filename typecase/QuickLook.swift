import AppKit
import SwiftUI

/// Quick Look for the font list, as in Finder: Space opens a floating panel
/// with the selected font's specimen page, and Space or Escape closes it. The
/// page follows the list's selection, so the arrow keys move through the fonts
/// while it stays open. The panel never takes the keyboard from the list.
@MainActor
final class QuickLookController {
    static let cornerRadius: CGFloat = 16
    private static let size = NSSize(width: 820, height: 640)

    private var panel: QuickLookPanel?
    /// The panel's frame before it filled the screen.
    private var restoredFrame: NSRect?

    var isVisible: Bool { panel != nil }

    func toggle(catalog: FontCatalog, viewState: LibraryViewState, settings: AppSettings) {
        if isVisible {
            close()
        } else {
            show(catalog: catalog, viewState: viewState, settings: settings)
        }
    }

    func show(catalog: FontCatalog, viewState: LibraryViewState, settings: AppSettings) {
        if let panel {
            panel.orderFront(nil)
            return
        }
        let library = NSApp.keyWindow
        let panel = QuickLookPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A borderless panel draws no frame, so the content clips itself to
        // the rounded shape and the shadow follows it.
        let hosting = NSHostingView(rootView: QuickLookView(catalog: catalog, viewState: viewState, controller: self)
            .environmentObject(settings))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Self.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.minSize = NSSize(width: 420, height: 320)
        if let frame = library?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
        } else {
            panel.center()
        }
        self.panel = panel
        restoredFrame = nil

        // Laid out on screen but transparent, so the zoom has a picture of
        // the page to grow from.
        panel.alphaValue = 0
        panel.orderFront(nil)
        let target = panel.frame
        guard let image = snapshot(of: panel) else {
            panel.alphaValue = 1
            return
        }
        zoom(image, from: Self.scaled(target, by: 0.92), to: target, appearing: true) {
            panel.alphaValue = 1
        }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        let frame = panel.frame
        let image = snapshot(of: panel)
        panel.orderOut(nil)
        if let image {
            zoom(image, from: frame, to: Self.scaled(frame, by: 0.95), appearing: false) {}
        }
    }

    // MARK: - Zoom

    private static func scaled(_ rect: NSRect, by scale: CGFloat) -> NSRect {
        rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
    }

    /// The panel's content as an image, so the zoom can scale it without the
    /// page's text reflowing at every intermediate size.
    private func snapshot(of panel: NSPanel) -> NSImage? {
        guard let view = panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Scales and fades a picture of the panel in a shadowed window of its
    /// own, so the frame, corners, and shadow move together, then hands over
    /// to the real panel.
    private func zoom(_ image: NSImage, from start: NSRect, to end: NSRect, appearing: Bool, completion: @escaping () -> Void) {
        let window = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        window.contentView = imageView
        window.alphaValue = appearing ? 0 : 1
        window.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.2 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = appearing ? 1 : 0
        } completionHandler: {
            completion()
            window.orderOut(nil)
        }
    }

    /// Fills the screen's visible area, or returns to the earlier frame.
    func toggleFillScreen() {
        guard let panel, let screen = panel.screen?.visibleFrame else { return }
        let target: NSRect
        if let restoredFrame {
            target = restoredFrame
            self.restoredFrame = nil
        } else {
            restoredFrame = panel.frame
            target = screen
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().setFrame(target, display: true)
        }
    }

    var fillsScreen: Bool { restoredFrame != nil }
}

/// A floating, borderless panel above the library. It never becomes key, so
/// Space and the arrow keys keep reaching the font list.
private final class QuickLookPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // The controller zooms the panel in and out itself.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
}

/// The panel's content: the first selected font's specimen page, in the
/// list's preview text, variable-axis values, and specimen colors, under a
/// bar laid out like Finder's Quick Look: close and fill-screen buttons on
/// the left, the font's name, and Show in Finder on the right.
private struct QuickLookView: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    let controller: QuickLookController
    @EnvironmentObject private var settings: AppSettings
    @State private var fillsScreen = false

    private var family: FontFamily? {
        viewState.selectedFamilies(catalog: catalog).first
    }

    var body: some View {
        let family = family
        let face = family?.previewFace
        Group {
            if let family, let face {
                ScrollView {
                    SpecimenPage(
                        face: face,
                        text: settings.effectivePreviewText(for: family, entered: viewState.previewText),
                        variations: settings.variationValues(for: face),
                        textColor: textColor
                    )
                    // Clears the bar above.
                    .padding(.top, 44)
                }
            } else {
                ContentUnavailableView(String(localized: "No Font Selected"), systemImage: "textformat")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            bar(family: family, face: face)
        }
    }

    private var textColor: Color {
        settings.previewTextColor ?? Color(nsColor: .labelColor)
    }

    private func bar(family: FontFamily?, face: FontFace?) -> some View {
        HStack(spacing: 10) {
            barButton(String(localized: "Close"), systemImage: "xmark") {
                controller.close()
            }
            barButton(
                fillsScreen ? String(localized: "Restore Size") : String(localized: "Fill Screen"),
                systemImage: fillsScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            ) {
                controller.toggleFillScreen()
                fillsScreen = controller.fillsScreen
            }

            if let family, let face {
                Text(verbatim: "\(family.name) \(face.styleName)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(textColor.opacity(0.6))
                    .lineLimit(1)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 8)

            if let url = face?.fileURL {
                barButton(String(localized: "Show in Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The specimen page: the text set large, then the same text in one line at
/// each size of the waterfall.
private struct SpecimenPage: View {
    static let specimenSize: CGFloat = 72
    static let waterfallSizes: [CGFloat] = [12, 18, 24, 36, 48, 72]

    let face: FontFace
    let text: String
    let variations: [UInt32: Double]?
    let textColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text(text)
                .font(font(size: Self.specimenSize))
                .lineSpacing(Self.specimenSize * 0.15)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(textColor.opacity(0.15))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.waterfallSizes, id: \.self) { size in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(verbatim: "\(Int(size))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(textColor.opacity(0.5))
                            .frame(width: 24, alignment: .trailing)
                        Text(text)
                            .font(font(size: size))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 56)
        .padding(.top, 32)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(size: CGFloat) -> Font {
        FontResolver.shared.previewFont(
            postScriptName: face.postScriptName,
            fileURL: face.fileURL,
            size: size,
            variations: variations
        )
    }
}
