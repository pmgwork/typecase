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
- The initial library scan runs off the main thread; while it is loading, the font list area shows a standard `ProgressView` row instead of the empty state.
- No custom badges or hand-drawn borders in list rows; the font source appears as a short secondary label (`Morisawa`, `Adobe`, `Local`) and is omitted for OS fonts.
- Each row starts with an activation indicator: a radio button for fonts TypeCase can activate (`circle.inset.filled` enabled, `circle` disabled, `circle.lefthalf.filled` partial) and `lock.fill` for fonts managed by macOS, Adobe, or Morisawa. Both indicators use the same size and column width so font names align, and expanded style rows repeat the indicator at the leading edge.
- Activation is changed from the list row only; the inspector shows the management hint for sources TypeCase cannot change, not a toggle.
- Filters and folder actions live in toolbar menus; the preview size sits in the toolbar as a compact “A”/slider/“A” pill in its own toolbar item with the system glass effect, separate from the button groups.
- The toolbar search field uses the native `NSSearchField` at a fixed 220 pt width instead of expanding into all available toolbar space.
- A floating preview-text editor is always visible below the font list: a Liquid Glass panel over a bottom gradient that fades list content beneath it, containing a text field, quick preset chips, and a “+” chip that keeps the current text as a user preset.
- The preview text always filters the library: while it is not empty, the list keeps only fonts whose preview style can display every character of it. Coverage checks run off the main thread and are cached per font file.
- The inspector lists the preview-text characters the selected font cannot display; list rows stay unmarked.
- `Settings` (⌘,) has General, Sidebar, and Preview tabs with app-wide preferences shared by every window. General covers starting at login, launching in the background, and favorites-first sorting. The last section and selected font are always restored. Sidebar contains an aligned checkbox-and-icon list of All Fonts, Favorites, System Fonts, Local Library, Adobe Fonts, Morisawa Fonts, and Tags. Hiding a destination moves the selection to the first item that is still visible.
- The login item mirrors the system state through `SMAppService`; when macOS asks the user to approve it, the row shows a hint and a shortcut to Login Items instead of a stale toggle. A background launch opens no window, and the Dock icon reopens the library.
- The Preview settings choose the app-wide preview size and the Japanese and Latin sample texts used while the preview field is empty.
- The System Fonts group collapses from a leading disclosure control aligned with folder disclosure arrows; the expanded state is remembered across launches.
- The sidebar contains navigation rows only; the Folders section header has a trailing borderless `folder.badge.plus` button, and the same action remains available from the File menu.
- All sidebar navigation labels use the same system font size, including indented System Fonts scopes and nested folders.
- A sidebar font count appears only on the currently selected destination.
- The selected sidebar row uses a neutral gray highlight rather than an accent-color fill.
- Font previews in lists are single-line with tail truncation so row heights stay constant; the inspector and comparison allow two lines.
- Expanded style rows list each face light-to-heavy by font weight, with the style name as the tiebreaker so styles order the same for installed and folder fonts.
- Disabled local fonts are previewed directly from their font-file descriptors without registering or activating them.
- Library edits update only the affected family so the list does not rebuild or re-animate during state changes.
- State changes use native macOS motion and accessibility behavior; no decorative animation is added.
