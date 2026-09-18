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
    @StateObject private var playground = PlaygroundStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(settings)
                .environmentObject(playground)
                .task { catalog.start() }
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Font Folder…") {
                    NotificationCenter.default.post(name: .addFontFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                OpenPlaygroundCommand()
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Font Library") {
                    catalog.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("PlayGround", id: PlaygroundWindow.id) {
            PlaygroundView()
                .environmentObject(catalog)
                .environmentObject(settings)
                .environmentObject(playground)
        }
        .defaultSize(width: 1040, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

/// Opens the PlayGround window from the File menu. The library's toolbar adds
/// the selected fonts as well.
private struct OpenPlaygroundCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open PlayGround") {
            openWindow(id: PlaygroundWindow.id)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    static let addFontFolder = Notification.Name("addFontFolder")
}
