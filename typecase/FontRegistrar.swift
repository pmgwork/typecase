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

/// A batch error can name multiple files. Unattributed errors fail the whole
/// batch conservatively rather than reporting an unknown result as success.
nonisolated struct FontRegistrationFailure: Sendable {
    let urls: Set<URL>
    let message: String
}

nonisolated struct FontRegistrationBackend: Sendable {
    var scope: @Sendable (URL) -> CTFontManagerScope
    var update: @Sendable ([URL], Bool) async -> [FontRegistrationFailure]

    static let coreText = Self(
        scope: { CTFontManagerGetScopeForURL($0 as CFURL) },
        update: { urls, enabled in
            await withCheckedContinuation { continuation in
                let result = FontRegistrationBatchResult()
                let handler: (CFArray, Bool) -> Bool = { errors, done in
                    let failures = (errors as? [CFError] ?? []).map { error in
                        let info = CFErrorCopyUserInfo(error) as NSDictionary
                        let urls = info[kCTFontManagerErrorFontURLsKey] as? [URL] ?? []
                        return FontRegistrationFailure(
                            urls: Set(urls.map(\.standardizedFileURL)),
                            message: CFErrorCopyDescription(error) as String
                        )
                    }
                    if let final = result.append(failures, done: done) {
                        continuation.resume(returning: final)
                    }
                    return true
                }
                if enabled {
                    CTFontManagerRegisterFontURLs(urls as CFArray, .user, true, handler)
                } else {
                    CTFontManagerUnregisterFontURLs(urls as CFArray, .user, handler)
                }
            }
        }
    )
}

/// Core Text may report errors over several callbacks, possibly on another
/// queue. Resume only at completion, retaining errors from earlier callbacks.
nonisolated private final class FontRegistrationBatchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [FontRegistrationFailure] = []
    private var completed = false

    func append(_ errors: [FontRegistrationFailure], done: Bool) -> [FontRegistrationFailure]? {
        lock.withLock {
            guard !completed else { return nil }
            failures.append(contentsOf: errors)
            guard done else { return nil }
            completed = true
            return failures
        }
    }
}

/// Registration is serialized by the catalog's work queue. Core Text receives
/// a batch instead of paying registration/notification costs for every file.
actor FontRegistrar {
    private let backend: FontRegistrationBackend

    init(backend: FontRegistrationBackend = .coreText) {
        self.backend = backend
    }

    func synchronize(_ actions: [FontRegistrationAction]) async -> [FontRegistrationOutcome] {
        guard !actions.isEmpty else { return [] }
        var results: [Int: FontRegistrationOutcome] = [:]
        var unregister: [Int] = []
        var register: [Int] = []
        for (index, action) in actions.enumerated() {
            let userRegistered = backend.scope(action.url) == .user
            if action.enabled {
                if userRegistered && action.skipIfAlreadyScoped {
                    results[index] = outcome(action, failures: [])
                } else {
                    if userRegistered { unregister.append(index) }
                    register.append(index)
                }
            } else if userRegistered {
                unregister.append(index)
            } else {
                results[index] = outcome(action, failures: [])
            }
        }
        if !unregister.isEmpty {
            let failures = await backend.update(unregister.map { actions[$0].url }, false)
            for index in unregister {
                let result = outcome(actions[index], failures: failures)
                // Failed refresh unregistration must not be reported as a
                // successful registration of the replacement file.
                if !actions[index].enabled || !result.succeeded { results[index] = result }
            }
        }
        register.removeAll { results[$0] != nil }
        if !register.isEmpty {
            let failures = await backend.update(register.map { actions[$0].url }, true)
            for index in register { results[index] = outcome(actions[index], failures: failures) }
        }
        return actions.indices.compactMap { results[$0] }
    }

    private func outcome(_ action: FontRegistrationAction, failures: [FontRegistrationFailure]) -> FontRegistrationOutcome {
        let messages = failures.filter {
            $0.urls.isEmpty || $0.urls.contains(action.url.standardizedFileURL)
        }.map(\.message)
        return FontRegistrationOutcome(
            url: action.url, names: action.names,
            succeeded: messages.isEmpty,
            errorDescription: messages.isEmpty ? nil : messages.joined(separator: "\n")
        )
    }
}
