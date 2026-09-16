import CoreServices
import Foundation

/// Watches added folders with FSEvents and reports debounced changes on the main queue.
///
/// Events are coalesced so a burst of file system activity (copying a folder of
/// fonts) results in a single rescan. All stream bookkeeping happens on a private
/// serial queue; `onChanges` is only read and written on the main queue.
///
/// `@unchecked Sendable`: mutable state is confined to `queue` and `onChanges`
/// is only touched on the main queue.
nonisolated final class FolderMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedRoots: [URL] = []
    private var pendingNotification: DispatchWorkItem?
    private let queue = DispatchQueue(label: "pmgwork.typecase.folder-monitor", qos: .utility)

    /// Called on the main queue after file system changes settle down.
    var onChanges: (() -> Void)?

    func update(roots: [URL]) {
        let normalized = roots.map(\.standardizedFileURL)
        queue.async { [weak self] in
            guard let self, normalized != self.watchedRoots else { return }
            self.watchedRoots = normalized
            self.restartStream()
        }
    }

    fileprivate func eventReceived() {
        guard pendingNotification == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNotification = nil
            DispatchQueue.main.async {
                self.onChanges?()
            }
        }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restartStream() {
        stopStream()
        guard !watchedRoots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        let paths = watchedRoots.map(\.path) as CFArray
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderMonitorCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            return
        }
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        self.stream = nil
    }
}

private nonisolated func folderMonitorCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
    monitor.eventReceived()
}
