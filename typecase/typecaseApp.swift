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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
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
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Font Library") {
                    catalog.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let addFontFolder = Notification.Name("addFontFolder")
}
