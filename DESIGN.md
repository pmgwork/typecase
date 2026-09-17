# TypeCase Design

## Direction

TypeCase uses a quiet, native macOS library interface inspired by the information density and workflow of RightFont. The font previews are the primary visual content; controls remain neutral and compact.

## Color and surfaces

- Native semantic macOS colors provide automatic light and dark appearances.
- System green communicates font activation in list rows; the system accent color is reserved for selection.
- Adobe Fonts, Morisawa Fonts, and Fontworks LETS use neutral source labels; each service's own mark is bundled as a square asset, kept as it appears in the service's own icon (background included), and clipped to the same proportional continuous corner radius. Provider marks render at 18 pt in navigation rows and 48 pt in an empty state, so they match the surrounding SF Symbol scale in each context. The rest of the sidebar keeps SF Symbols and the neutral tint.
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
- Source, language, classification, version, glyph count, embedding permission, and designer use `LabeledContent` in the inspector; the copyright and license notices follow as secondary text.

## Components and motion

- Standard macOS controls only: `List`, `Picker`, `Slider`, `TextField`, `NSSearchField`, `Toggle`, `LabeledContent`, `.inspector`, sheets, and SF Symbols.
- The initial library scan runs off the main thread; while it is loading, the font list area shows a standard `ProgressView` row instead of the empty state.
- No custom badges or hand-drawn borders in list rows; the font source appears as a short secondary label (`Morisawa`, `Adobe`, `LETS`, `Local`) and is omitted for OS fonts.
- Each row starts with an activation indicator: a radio button for fonts TypeCase can activate (`circle.fill` enabled, `circle` disabled, `circle.lefthalf.filled` partial) and `lock.fill` for fonts managed by macOS or a font service. Active indicators and the lock use system green; a disabled style keeps a secondary-gray outline. Both indicators use the same size and column width so font names align, and expanded style rows repeat the indicator as a per-style activation button. Styles that share one font file toggle together, because Core Text registers font files as a unit.
- Activation is changed from the list row only; the inspector shows the management hint for sources TypeCase cannot change, not a toggle. Activating or deactivating — from a radio button, a style row, or the context menu — registers with the window's undo manager, so ⌘Z restores the previous activation state and Redo re-applies it.
- Right-clicking a font row offers Activate, Deactivate, Show in Finder, Copy Path, and a Copy Name submenu (family name, English name, PostScript names, and a CSS `font-family` declaration). Every item stays visible and disables itself when it does not apply, so the menu keeps the same shape for every font: activation is disabled for sources TypeCase cannot change, and the file actions are disabled when the family has no file on disk. Show in Finder reveals every file of the family, Copy Path puts the paths on the pasteboard one per line, and when the clicked row is part of a multi-selection, Activate and Deactivate apply to every selected family and show the count in their titles.
- Filters and folder actions live in toolbar menus; the preview size sits in the toolbar as a compact “A”/slider/“A” pill in its own toolbar item with the system glass effect, separate from the filter menu and the inspector button.
- The toolbar toggles the inspector with a single ⓘ button (`info.circle`); side-by-side comparison opens from the inspector when a multi-selection is active.
- The Filter menu also chooses the list order: Name, Manufacturer, Recently Added, or Activated First. Favorites-first stays an app-wide preference layered on top. Recently Added uses the font file's creation date, so installed fonts with no folder stamp sort last.
- The specimen colors sit in the toolbar as a Liquid Glass capsule around a split swatch. Each half independently opens a custom SwiftUI popover: background on the left, text on the right. The same picker is used in Settings: a hue ring with a handle, a rounded-square saturation/brightness field sized to sit clear of the ring, and a per-color system reset; there are no RGB or HEX fields. The ring and disc support dragging (the control is chosen where the drag starts), keyboard adjustment, and accessibility controls; the brightness slider was replaced by the disc. Native popover surfaces and typography keep it consistent with macOS. System, Light, and Dark presets are available in the toolbar context menu. The chosen background paints the whole font list area, so specimens sit directly on it and the preview-text editor fades into the same color; while it is set, a selected row draws its own veil in the specimen text color and the system accent highlight is suppressed, so the selection belongs to the chosen palette. The inspector, sidebar, toolbar, and comparison sheet keep the system surfaces, and the inspector and comparison sheet show the color pair as a block behind their specimen. Without a chosen color the list keeps the system window color and the specimens follow the system appearance.
- The window keeps its title for the Window menu and Mission Control, but the toolbar does not draw it: the app name is already in the menu bar, so no title is repeated above the font list.
- The search field is a compact native `NSSearchField`; the Filter menu, the ⓘ inspector toggle, and the search field share the toolbar's trailing section, and the leading side keeps the viewing controls (preview size and specimen colors).
- A floating preview-text editor is always visible below the font list: a Liquid Glass panel over a bottom gradient that fades list content beneath it, containing a text field, quick preset chips, and a “+” chip that keeps the current text as a user preset.
- The preview text always filters the library: while it is not empty, the list keeps only fonts whose preview style can display every character of it. Coverage checks run off the main thread and are cached per font file.
- The inspector lists the preview-text characters the selected font cannot display; list rows stay unmarked.
- The inspector adds a Variable Axes section for variable fonts: sliders set the preview instance of the family's preview style, the values apply to every preview of that face, and Reset returns to the style's own coordinates.
- The inspector reads the selected face's version, glyph count, embedding permission, designer, copyright, and license from the font file's `name`, `maxp`, and `OS/2` tables on a background task; fields the file does not carry are omitted.
- `Settings` (⌘,) has General, Sidebar, and Preview tabs with app-wide preferences shared by every window. General covers starting at login and favorites-first sorting. The last section and selected font are always restored. Sidebar contains an aligned checkbox-and-icon list of All Fonts, Favorites, System Fonts, Local Library, the font services, and Tags. Hiding a destination moves the selection to the first item that is still visible.
- Font services are defined in one provider table (`FontProviderRegistry`): title, short label, icon (an SF Symbol or a bundled service mark), management hint, empty-state message, and detection rules. Sidebar rows, Settings checkboxes, filtering, counts, and empty states all derive from it, and a family's service wins over Local and System when its faces come from several sources. Detection combines path fragments, manufacturer names, and the font file names recorded in a service's own manifests; LETS installs fonts into `~/Library/Fonts`, so its `LETS.font.plist` and `LETS-device.target.plist` files identify them instead of the path.
- The login item mirrors the system state through `SMAppService`; when macOS asks the user to approve it, the row shows a hint and a shortcut to Login Items instead of a stale toggle.
- The Preview settings choose the app-wide preview size, background and text colors, and the Japanese and Latin sample texts used while the preview field is empty. The color pickers and System/Light/Dark presets share persisted state with the toolbar controls, so changes in either location update all windows.
- The System Fonts group collapses from a leading disclosure control aligned with folder disclosure arrows; the expanded state is remembered across launches.
- The sidebar contains navigation rows only; the Folders section header has a trailing borderless `folder.badge.plus` button, and the same action remains available from the File menu.
- The font services (Adobe Fonts, Morisawa Fonts, Fontworks LETS) sit under a `Providers` section header, matching the Folders and Tags headers; the header disappears when every service is hidden in Settings.
- All sidebar navigation labels use the same system font size, including indented System Fonts scopes and nested folders.
- A sidebar font count appears only on the currently selected destination.
- Selection uses AppKit's native drawing: the sidebar requests non-emphasized gray and the font list requests emphasized accent blue. Selection shape, spacing, keyboard behavior, and multiple selection remain system-provided.
- Font previews in lists are single-line with tail truncation so row heights stay constant; the inspector and comparison allow two lines.
- Expanded style rows list each face light-to-heavy by font weight, with the style name as the tiebreaker so styles order the same for installed and folder fonts. Only one family is expanded at a time, and selecting another font collapses the expanded styles.
- Disabled local fonts are previewed directly from their font-file descriptors without registering or activating them.
- Library edits update only the affected family so the list does not rebuild or re-animate during state changes.
- State changes use native macOS motion and accessibility behavior; no decorative animation is added.
