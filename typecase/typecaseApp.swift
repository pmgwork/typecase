//
//  typecaseApp.swift
//  typecase
//
//  Created by Yuto Chiba on 2026/09/15.
//

import AppKit
import SwiftUI

@main
struct typecaseApp: App {
    @StateObject private var updater = AppUpdater()
    @StateObject private var catalog = FontCatalog()
    @StateObject private var settings = AppSettings()
    @StateObject private var mixedPairDraft = MixedPairDraft()

    init() {
        // The library is not a tabbed document window; without this, macOS
        // adds Show Tab Bar and Show All Tabs to the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // One library window: a second one adds nothing a font manager needs.
        Window("TypeCase", id: LibraryWindows.id) {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(settings)
                .environmentObject(mixedPairDraft)
                .task { catalog.start() }
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Check for Updates…")) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                AddFontFolderCommand(catalog: catalog, settings: settings)
            }
            CommandGroup(after: .sidebar) {
                Button(String(localized: "Refresh Font Library")) {
                    catalog.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window(String(localized: "New Mixed Pair"), id: MixedPairWindow.id) {
            MixedPairEditorView(catalog: catalog)
                .environmentObject(settings)
                .environmentObject(mixedPairDraft)
        }
        .defaultSize(width: 980, height: 600)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        WindowGroup(String(localized: "Glyphs"), id: GlyphWindow.id, for: FontFamily.ID.self) { $familyID in
            GlyphBrowserWindow(catalog: catalog, familyID: familyID)
        }
        .defaultSize(width: 1040, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(catalog)
        }
    }
}

/// Adds a font folder from the File menu. An open library window shows the
/// folder; with none open, a new library window opens on it.
private struct AddFontFolderCommand: View {
    let catalog: FontCatalog
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Add Font Folder…")) {
            if LibraryWindows.frontmost != nil {
                NotificationCenter.default.post(name: .addFontFolder, object: nil)
            } else {
                catalog.addFolder { url in
                    // A new window restores the remembered destination.
                    settings.remember(location: .folder(url))
                    openWindow(id: LibraryWindows.id)
                }
            }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    static let addFontFolder = Notification.Name("addFontFolder")
}
