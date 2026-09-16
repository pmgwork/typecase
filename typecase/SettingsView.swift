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

                Toggle("Start in the background", isOn: $settings.startHidden)
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
                    systemImage: LibrarySection.all.systemImage,
                    isOn: $settings.showAllSection
                )
                SidebarItemToggle(
                    title: LibrarySection.favorites.title,
                    systemImage: LibrarySection.favorites.systemImage,
                    isOn: $settings.showFavoritesSection
                )
                SidebarItemToggle(
                    title: LibrarySection.system.title,
                    systemImage: LibrarySection.system.systemImage,
                    isOn: $settings.showSystemSection
                )
                SidebarItemToggle(
                    title: LibrarySection.local.title,
                    systemImage: LibrarySection.local.systemImage,
                    isOn: $settings.showLocalSection
                )
                SidebarItemToggle(
                    title: LibrarySection.adobe.title,
                    systemImage: LibrarySection.adobe.systemImage,
                    isOn: $settings.showAdobeSection
                )
                SidebarItemToggle(
                    title: LibrarySection.morisawa.title,
                    systemImage: LibrarySection.morisawa.systemImage,
                    isOn: $settings.showMorisawaSection
                )
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
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
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
                TextField("Japanese", text: $settings.japaneseSampleText, prompt: Text(AppSettings.japaneseSampleDefault))
                TextField("Latin", text: $settings.latinSampleText, prompt: Text(AppSettings.latinSampleDefault))
                Button("Restore Defaults") { settings.resetSampleText() }
            } header: {
                Text("Sample Text")
            } footer: {
                Text("Used in previews while the preview text field is empty.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
}
