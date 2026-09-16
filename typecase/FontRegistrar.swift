import CoreText
import Foundation

nonisolated struct FontRegistrationAction: Sendable {
    let url: URL
    let names: Set<String>
    /// `true` activates the font for the user; `false` removes that registration.
    /// Deactivated fonts stay unregistered: previews read the font file directly,
    /// so no process-scope registration is needed.
    let enabled: Bool
    /// When `true`, the Core Text call is skipped if the font is already in the
    /// desired state. Scans use `false` so a replaced font file is re-registered.
    let skipIfAlreadyScoped: Bool
}

nonisolated struct FontRegistrationOutcome: Sendable {
    let url: URL
    let names: Set<String>
    let succeeded: Bool
    let errorDescription: String?
}

/// Serializes Core Text font registration away from the main actor.
///
/// All registration goes through this actor so a folder scan and a user toggle
/// can never interleave their Core Text calls. Only user-scope activation is
/// registered; deactivated fonts are previewed from their file descriptors by
/// `FontResolver`.
actor FontRegistrar {
    func synchronize(_ actions: [FontRegistrationAction]) -> [FontRegistrationOutcome] {
        actions.map(perform)
    }

    private func perform(_ action: FontRegistrationAction) -> FontRegistrationOutcome {
        let url = action.url as CFURL
        let currentScope = CTFontManagerGetScopeForURL(url)

        if action.enabled {
            if currentScope == .user {
                if action.skipIfAlreadyScoped { return success(action) }
                // Re-register so Core Text picks up a replaced font file.
                CTFontManagerUnregisterFontsForURL(url, .user, nil)
            }
            var error: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url, .user, &error) else {
                return failure(action, error: error)
            }
            return success(action)
        }

        // Deactivation only has to remove the user registration. A font that is
        // not user-registered is already in the desired state.
        guard currentScope == .user else { return success(action) }
        var error: Unmanaged<CFError>?
        guard CTFontManagerUnregisterFontsForURL(url, .user, &error) else {
            return failure(action, error: error)
        }
        return success(action)
    }

    private func success(_ action: FontRegistrationAction) -> FontRegistrationOutcome {
        FontRegistrationOutcome(url: action.url, names: action.names, succeeded: true, errorDescription: nil)
    }

    private func failure(_ action: FontRegistrationAction, error: Unmanaged<CFError>?) -> FontRegistrationOutcome {
        FontRegistrationOutcome(
            url: action.url,
            names: action.names,
            succeeded: false,
            errorDescription: error?.takeRetainedValue().localizedDescription ?? action.url.lastPathComponent
        )
    }
}
