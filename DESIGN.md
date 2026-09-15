# TypeCase Design

## Direction

TypeCase uses a quiet, native macOS library interface inspired by the information density and workflow of RightFont. The font previews are the primary visual content; controls remain neutral and compact.

## Color and surfaces

- Native semantic macOS colors provide automatic light and dark appearances.
- The system accent color is the only saturated color and communicates enabled or selected states.
- Adobe Fonts and Morisawa Fonts use neutral source labels and SF Symbols rather than brand colors.
- Dividers and native list selection provide 1 px boundaries without shadows.
- The inspector uses `controlBackgroundColor` as the only secondary surface.

## Typography

- Interface labels use the macOS system font.
- Font content is rendered with each font's PostScript name through SwiftUI `Font.custom`.
- Primary page headings use 20–24 pt; UI labels use 11–14 pt; preview text is user-adjustable from 18–72 pt.

## Layout

- `NavigationSplitView` with sidebar navigation and font previews, plus a trailing `.inspector` panel for details.
- Toggling the inspector collapses the panel so the font list expands to the full window width.
- Sidebar width: 190–260 pt.
- Main library width: 480 pt minimum.
- Inspector width: 280–400 pt.
- Repeated font rows use vertical spacing rather than cards or shadows.
- Source, language, and classification use `LabeledContent` in the inspector.

## Components and motion

- Standard macOS controls only: `List`, `Picker`, `Slider`, `TextField`, `Toggle`, `LabeledContent`, `.searchable`, `.inspector`, sheets, and SF Symbols.
- No custom badges, floating overlays, or hand-drawn borders; the font source appears as a short secondary label (`Morisawa`, `Adobe`, `Local`) and is omitted for OS fonts.
- Each row starts with an activation indicator: a radio button for fonts TypeCase can activate (`circle.inset.filled` enabled, `circle` disabled, `circle.lefthalf.filled` partial) and `lock.fill` for fonts managed by macOS, Adobe, or Morisawa.
- Filters and folder actions live in toolbar menus; the preview bar keeps only a flexible text field, slider, and size label.
- The sidebar contains navigation rows only, so no bordered buttons appear inside it; folders are added from the toolbar “+” menu or File menu.
- Font previews in lists are single-line with tail truncation so row heights stay constant; the inspector and comparison allow two lines.
- Library edits update only the affected family so the list does not rebuild or re-animate during state changes.
- State changes use native macOS motion and accessibility behavior; no decorative animation is added.
