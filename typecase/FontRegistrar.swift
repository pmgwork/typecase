import CoreText
import Foundation

nonisolated struct FontRegistrationAction: Sendable {
    let url: URL
    let names: Set<String>
    /// `true` registers the font for the user (activated); `false` keeps it registered
    /// for this process only so previews work while the font stays deactivated.
    let enabled: Bool
    /// When `true`, the Core Text calls are skipped if the font is already registered
    /// in the desired scope. Scans use `false` so a replaced font file is re-registered.
    let skipIfAlreadyScoped: Bool
}

nonisolated struct FontRegistrationOutcome: Sendable {
    let url: URL
    let names: Set<String>
    let enabled: Bool
    let succeeded: Bool
    /// For a deactivated font: the process-scope registration used for previews succeeded.
    let previewRegistered: Bool
    let errorDescription: String?
}

/// Serializes Core Text font registration away from the main actor.
///
/// All registration goes through this actor so a folder scan and a user toggle
/// can never interleave their Core Text calls. The actor skips work when the
/// font is already registered in the desired scope.
actor FontRegistrar {
    func synchronize(_ actions: [FontRegistrationAction]) -> [FontRegistrationOutcome] {
        actions.map(perform)
    }

    private func perform(_ action: FontRegistrationAction) -> FontRegistrationOutcome {
        let desired: CTFontManagerScope = action.enabled ? .user : .process
        if action.skipIfAlreadyScoped, CTFontManagerGetScopeForURL(action.url as CFURL) == desired {
            return FontRegistrationOutcome(
                url: action.url,
                names: action.names,
                enabled: action.enabled,
                succeeded: true,
                previewRegistered: desired == .process,
                errorDescription: nil
            )
        }

        var error: Unmanaged<CFError>?
        if action.enabled {
            CTFontManagerUnregisterFontsForURL(action.url as CFURL, .process, nil)
            if CTFontManagerRegisterFontsForURL(action.url as CFURL, .user, &error) {
                return FontRegistrationOutcome(
                    url: action.url,
                    names: action.names,
                    enabled: true,
                    succeeded: true,
                    previewRegistered: false,
                    errorDescription: nil
                )
            }
            // Restore the preview registration so the deactivated font can still be previewed.
            CTFontManagerRegisterFontsForURL(action.url as CFURL, .process, nil)
            return failure(action, error: error)
        }

        guard CTFontManagerUnregisterFontsForURL(action.url as CFURL, .user, &error) else {
            return failure(action, error: error)
        }
        let previewRegistered = CTFontManagerRegisterFontsForURL(action.url as CFURL, .process, &error)
        return FontRegistrationOutcome(
            url: action.url,
            names: action.names,
            enabled: false,
            succeeded: true,
            previewRegistered: previewRegistered,
            errorDescription: previewRegistered
                ? nil
                : error?.takeRetainedValue().localizedDescription ?? action.url.lastPathComponent
        )
    }

    private func failure(_ action: FontRegistrationAction, error: Unmanaged<CFError>?) -> FontRegistrationOutcome {
        FontRegistrationOutcome(
            url: action.url,
            names: action.names,
            enabled: action.enabled,
            succeeded: false,
            previewRegistered: false,
            errorDescription: error?.takeRetainedValue().localizedDescription ?? action.url.lastPathComponent
        )
    }
}
