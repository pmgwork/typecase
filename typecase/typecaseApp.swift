//
//  typecaseApp.swift
//  typecase
//
//  Created by Yuto Chiba on 2026/09/15.
//

import SwiftUI

@main
struct typecaseApp: App {
    @StateObject private var catalog = FontCatalog()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(settings)
                .task { catalog.start() }
        }
        // A background launch starts without a window. The Dock icon still
        // reopens the library. The behavior is read when the app launches.
        .defaultLaunchBehavior(settings.startHidden ? .suppressed : .presented)
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Font Folder…") {
                    NotificationCenter.default.post(name: .addFontFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Font Library") {
                    catalog.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

extension Notification.Name {
    static let addFontFolder = Notification.Name("addFontFolder")
}
