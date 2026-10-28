import Foundation
import CoreServices

/// Streams directory-level changes from the FSEvents journal. Started with a past event id it first
/// replays everything since then (ending with `historyDone`), then keeps delivering live changes.
final class ChangeTracker: @unchecked Sendable {
    struct Change: Sendable {
        let path: String
        /// macOS coalesced or dropped events here; the whole subtree must be re-read.
        let recursive: Bool
    }

    struct Batch: Sendable {
        var changes: [Change] = []
        var lastEventId: UInt64 = 0
        var historyDone = false
        /// The journal can't be trusted (ids wrapped, root must be rescanned): do a full scan.
        var needsFullScan = false
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "DiskBro.ChangeTracker")
    private let handler: @Sendable (Batch) -> Void

    init(handler: @escaping @Sendable (Batch) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    static var currentEventId: UInt64 { FSEventsGetCurrentEventId() }

    func start(since eventId: UInt64) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let tracker = Unmanaged<ChangeTracker>.fromOpaque(info).takeUnretainedValue()
            let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var batch = Batch()
            for i in 0..<min(count, pathList.count) {
                let f = Int(flags[i])
                batch.lastEventId = max(batch.lastEventId, ids[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 { batch.historyDone = true; continue }
                if f & kFSEventStreamEventFlagEventIdsWrapped != 0 { batch.needsFullScan = true; continue }
                var path = pathList[i]
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                let dropped = f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
                if dropped && path == "/" { batch.needsFullScan = true; continue }
                batch.changes.append(Change(path: path, recursive: dropped))
            }
            tracker.handler(batch)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, ["/"] as CFArray, eventId, 1.5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
