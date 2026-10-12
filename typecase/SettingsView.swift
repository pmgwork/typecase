import AppKit
import SwiftUI

/// The Settings scene (⌘,): app-wide preferences shared by every window.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SidebarSettingsView()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            PreviewSettingsView()
                .tabItem { Label("Preview", systemImage: "textformat") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLogin)

                if loginItem.requiresApproval {
                    HStack(spacing: 8) {
                        Text("Allow TypeCase in Login Items to use this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }

                if let error = loginItem.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            }

            Section("Sorting") {
                Toggle("Show favorites first", isOn: $settings.favoritesFirst)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed the login item in System Settings.
            loginItem.refresh()
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }
}

private struct SidebarSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Show these items in the sidebar:") {
                SidebarItemToggle(
                    title: LibrarySection.all.title,
                    icon: LibrarySection.all.icon,
                    isOn: $settings.showAllSection
                )
                SidebarItemToggle(
                    title: LibrarySection.favorites.title,
                    icon: LibrarySection.favorites.icon,
                    isOn: $settings.showFavoritesSection
                )
                SidebarItemToggle(
                    title: LibrarySection.system.title,
                    icon: LibrarySection.system.icon,
                    isOn: $settings.showSystemSection
                )
                SidebarItemToggle(
                    title: LibrarySection.local.title,
                    icon: LibrarySection.local.icon,
                    isOn: $settings.showLocalSection
                )
                SidebarItemToggle(
                    title: LibrarySection.duplicates.title,
                    icon: LibrarySection.duplicates.icon,
                    isOn: $settings.showDuplicatesSection
                )
                SidebarItemToggle(
                    title: LibrarySection.mixed.title,
                    icon: LibrarySection.mixed.icon,
                    isOn: $settings.showMixedSection
                )
                ForEach(FontProviderRegistry.all) { provider in
                    SidebarItemToggle(
                        title: provider.title,
                        icon: provider.icon,
                        isOn: Binding(
                            get: { settings.isProviderSectionVisible(provider.id) },
                            set: { settings.setProviderSection(provider.id, visible: $0) }
                        )
                    )
                }
                SidebarItemToggle(title: "Tags", systemImage: "tag", isOn: $settings.showTagsSection)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One checkbox in the sidebar visibility list: checkbox, icon, name.
private struct SidebarItemToggle: View {
    let title: String
    let icon: SourceIcon
    @Binding var isOn: Bool

    init(title: String, systemImage: String, isOn: Binding<Bool>) {
        self.init(title: title, icon: .symbol(systemImage), isOn: isOn)
    }

    init(title: String, icon: SourceIcon, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                SourceIconView(icon: icon)
                    .frame(width: 24, alignment: .center)
                Text(title)
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct PreviewSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Size") {
                LabeledContent("Preview size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.previewSize, in: AppSettings.previewSizeRange, step: 1)
                            .frame(width: 200)
                        Text("\(Int(settings.previewSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                LabeledContent("Background") {
                    colorControl($settings.previewBackgroundColor, fallback: Color(nsColor: .windowBackgroundColor), title: "Background Color")
                }
                LabeledContent("Text") {
                    colorControl($settings.previewTextColor, fallback: Color(nsColor: .labelColor), title: "Text Color")
                }
                HStack {
                    Button("System") {
                        settings.setPreviewColors(background: nil, text: nil)
                    }
                    Button("Light") {
                        settings.setPreviewColors(background: .white, text: .black)
                    }
                    Button("Dark") {
                        settings.setPreviewColors(
                            background: Color(red: 0.11, green: 0.11, blue: 0.12),
                            text: .white
                        )
                    }
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("Applies to font specimens. Shared with the toolbar color controls. Choose System to follow the macOS appearance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(FontLanguage.allCases) { language in
                    TextField(
                        language.title,
                        text: sampleTextBinding(language),
                        prompt: Text(language.sampleDefault)
                    )
                }
                Button("Restore Defaults") { settings.resetSampleText() }
            } header: {
                Text("Sample Text")
            } footer: {
                Text("Used in previews while the preview text field is empty; a mixed specimen uses its own Japanese, English, digits, and symbols sample.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sampleTextBinding(_ language: FontLanguage) -> Binding<String> {
        Binding(
            get: { settings.sampleText(for: language) },
            set: { settings.setSampleText($0, for: language) }
        )
    }
}

private func colorControl(_ color: Binding<Color?>, fallback: Color, title: String) -> some View {
    SpecimenColorPicker(color: color, fallback: fallback, title: title) {
        RoundedRectangle(cornerRadius: 5)
            .fill(color.wrappedValue ?? fallback)
            .frame(width: 32, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2)))
            .padding(3)
            .contentShape(.rect)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
}
