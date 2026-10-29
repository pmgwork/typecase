import Foundation
import CoreText

private actor BatchSpy {
    struct Call: Sendable { let urls: [URL]; let enabled: Bool }
    var calls: [Call] = []
    func record(_ urls: [URL], enabled: Bool) { calls.append(Call(urls: urls, enabled: enabled)) }
}

@main
struct FontRegistrarTests {
    static func action(_ index: Int, enabled: Bool = true, refresh: Bool = false) -> FontRegistrationAction {
        FontRegistrationAction(url: URL(fileURLWithPath: "/tmp/typecase-batch-test-\(index).otf"),
                               names: ["test-\(index)"], enabled: enabled, skipIfAlreadyScoped: !refresh)
    }

    static func main() async {
        // A large selection must become one Core Text batch, with stable results
        // and file-specific failures rather than failing unrelated files.
        let actions = (0..<62).map { action($0) }
        let spy = BatchSpy()
        let backend = FontRegistrationBackend(scope: { _ in .none }, update: { urls, enabled in
            await spy.record(urls, enabled: enabled)
            return [FontRegistrationFailure(urls: [actions[12].url], message: "rejected file")]
        })
        let results = await FontRegistrar(backend: backend).synchronize(actions)
        let calls = await spy.calls
        precondition(calls.count == 1 && calls[0].enabled && calls[0].urls.count == 62)
        precondition(results.map(\.url) == actions.map(\.url))
        precondition(results.filter(\.succeeded).count == 61)
        precondition(results[12].errorDescription == "rejected file")

        // Skip unchanged registrations and inactive files; unregister changed
        // active files together before registering their replacements together.
        let spy2 = BatchSpy()
        let backend2 = FontRegistrationBackend(scope: { url in
            url == action(0).url ? .none : .user
        }, update: { urls, enabled in
            await spy2.record(urls, enabled: enabled)
            return []
        })
        let mixed = [action(0, enabled: false), action(1), action(2, refresh: true),
                     action(3, enabled: false), action(4, refresh: true)]
        let refreshed = await FontRegistrar(backend: backend2).synchronize(mixed)
        let refreshCalls = await spy2.calls
        precondition(refreshed.allSatisfy(\.succeeded))
        precondition(refreshCalls.count == 2)
        precondition(!refreshCalls[0].enabled && refreshCalls[0].urls == [mixed[2].url, mixed[3].url, mixed[4].url])
        precondition(refreshCalls[1].enabled && refreshCalls[1].urls == [mixed[2].url, mixed[4].url])

        // An unregistration error must not be concealed by re-registering a
        // replacement. Errors with no attributed URL conservatively fail all.
        let spy3 = BatchSpy()
        let backend3 = FontRegistrationBackend(scope: { _ in .user }, update: { urls, enabled in
            await spy3.record(urls, enabled: enabled)
            return [FontRegistrationFailure(urls: [], message: "batch failed")]
        })
        let failed = await FontRegistrar(backend: backend3).synchronize([action(1, refresh: true), action(2, refresh: true)])
        let failedCalls = await spy3.calls
        precondition(failed.allSatisfy { !$0.succeeded && $0.errorDescription == "batch failed" })
        precondition(failedCalls.count == 1 && !failedCalls[0].enabled)

        // Exercise real Core Text completion/error callbacks only with paths
        // that do not exist. No installed font or user registration is changed.
        let missing = (0..<3).map { i in
            FontRegistrationAction(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing-\(i).otf"),
                                   names: ["missing-\(i)"], enabled: true, skipIfAlreadyScoped: true)
        }
        let rejected = await FontRegistrar().synchronize(missing)
        precondition(rejected.count == 3 && rejected.allSatisfy { !$0.succeeded && $0.errorDescription != nil })
        print("PASS: batch submission, partial failure, skip, refresh ordering, unattributed failure, Core Text error callbacks")
    }
}
