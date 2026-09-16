import Combine
import Foundation
import ServiceManagement

/// Mirrors and changes the system login item for this app.
///
/// The state lives in the system, not in `UserDefaults`, so it is read from
/// `SMAppService` whenever the Settings window appears or the app activates.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published var errorMessage: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    /// The user turned the login item off in System Settings; it cannot be
    /// enabled from inside the app until they allow it again.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
