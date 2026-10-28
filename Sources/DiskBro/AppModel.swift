import SwiftUI
import AppKit

enum AppSection: String, CaseIterable, Identifiable {
    case overview, explore, cleanup, largeFiles, duplicates, history, hidden
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .explore: "Explore"
        case .cleanup: "Cleanup"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .history: "History"
        case .hidden: "Hidden Space"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .explore: "chart.pie"
        case .cleanup: "sparkles"
        case .largeFiles: "doc.badge.ellipsis"
        case .duplicates: "square.on.square"
        case .history: "chart.xyaxis.line"
        case .hidden: "eye.slash"
        }
    }
}

enum ScanState: Equatable {
    case idle, scanning, done
}

struct TrashItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    var node: FileNode?
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let title: String
    var items: [TrashItem]
    var isEmptyTrash = false
}

struct CommandRequest: Identifiable {
    let id = UUID()
    let title: String
    let explanation: String
    let estimatedSize: Int64?
    /// Each element is (executable, args). Run sequentially.
    let invocations: [(String, [String])]
    var admin = false
    var commandLines: [String] { invocations.map { Shell.quoted([$0.0] + $0.1) } }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol = "checkmark.circle.fill"
    var isError = false
}

@MainActor @Observable
final class AppModel {
    var section: AppSection = .overview
    var volume = VolumeStats.current()
    var container: APFSContainer?
    var snapshots: [LocalSnapshot] = []
    var hasFullDiskAccess = Permissions.hasFullDiskAccess()

    var scanState: ScanState = .idle
    var progress = ScanProgress()
    var root: FileNode?
    /// Bumped whenever the tree mutates so views depending on it refresh.
    var treeVersion = 0
    var lastScan: Date?
    var scanDuration: TimeInterval = 0
    var deniedPaths: [String] = []
    var deniedCount = 0
    var breakdown: [StorageCategory: Int64] = [:]

    var recommendations: [Recommendation] = []
    var recommendationsLoading = false
    /// Recommendation id → selected entry ids.
    var selections: [String: Set<String>] = [:]

    var exploreFocus: FileNode?

    var trashRequest: TrashRequest?
    var commandRequest: CommandRequest?
    var toast: Toast?

    let history = HistoryStore()
    var historyVersion = 0

    var duplicateGroups: [DuplicateGroup]?
    var duplicateProgress: DuplicateProgress?
    var duplicateKeep: [String: FileNode] = [:]
    private var duplicateFinder: DuplicateFinder?

    private var scanner: DiskScanner?
    private var timer: Timer?

    var home: String { NSHomeDirectory() }

    init() {
        history.sample(volume)
        Task { await refreshSystemInfo() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVolume() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.hasFullDiskAccess = Permissions.hasFullDiskAccess()
                self?.refreshVolume()
            }
        }
    }

    // MARK: - Derived

    var trashNode: FileNode? { root?.node(atPath: home + "/.Trash") }
    var trashSize: Int64? { trashNode?.size }

    var safeReclaimable: Int64 {
        recommendations.filter { $0.safety == .safe && $0.isActionable }.reduce(0) { $0 + selectedSize(of: $1) }
    }
    var reviewReclaimable: Int64 {
        recommendations.filter { $0.safety != .safe && $0.isActionable }.reduce(0) { $0 + $1.totalSize }
    }

    var unaccounted: Int64 {
        guard let root else { return 0 }
        let used = container.map { c in (c.volume(role: "System")?.used ?? 0) + (c.volume(role: "Data")?.used ?? 0) } ?? volume.used
        return max(0, used - root.size)
    }

    func selectedEntries(of rec: Recommendation) -> [CleanupEntry] {
        let sel = selections[rec.id] ?? []
        return rec.entries.filter { sel.contains($0.id) }
    }

    func selectedSize(of rec: Recommendation) -> Int64 {
        if rec.entries.isEmpty { return rec.totalSize }
        return selectedEntries(of: rec).reduce(0) { $0 + $1.size }
    }

    // MARK: - System info

    func refreshVolume() {
        let v = VolumeStats.current()
        if v != volume { volume = v }
        history.sample(v)
        historyVersion += 1
    }

    func refreshSystemInfo() async {
        refreshVolume()
        container = await APFSContainer.load()
        snapshots = await LocalSnapshot.list()
    }

    // MARK: - Scanning

    /// On launch: restore the cached tree and catch up through the FSEvents journal; full scan only if needed.
    func launch() async {
        guard root == nil, scanState == .idle else { return }
        let home = self.home
        guard let (tree, meta) = await Task.detached(priority: .userInitiated, operation: { TreeCache.load(rootPath: "/") }).value,
              Date.now.timeIntervalSince(meta.scanDate) < 30 * 86_400 else {
            startScan()
            return
        }
        root = tree
        exploreFocus = tree.node(atPath: home) ?? tree
        deniedPaths = meta.deniedPaths
        deniedCount = meta.deniedCount
        lastScan = meta.scanDate
        scanDuration = meta.scanDuration
        appliedEventId = meta.eventId
        scanState = .done
        liveState = .catchingUp
        treeVersion += 1
        breakdown = await Task.detached { CategoryBreakdown.compute(root: tree) }.value
        startTracking(since: meta.eventId)
    }

    func startScan() {
        guard scanState != .scanning else { return }
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        stopTracking()
        let scanner = DiskScanner(rootPath: "/")
        self.scanner = scanner
        let previousState = scanState
        scanState = .scanning
        progress = ScanProgress()
        let started = Date.now
        // Changes made while the scan runs are replayed afterwards from this point in the journal.
        let startEventId = ChangeTracker.currentEventId

        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.scanner else { return }
                self.progress = s.progress
            }
        }

        Task {
            let tree = await Task.detached(priority: .userInitiated) { await scanner.scan() }.value
            self.timer?.invalidate()
            self.scanner = nil
            if scanner.wasCancelled {
                self.scanState = self.root == nil ? .idle : previousState
                if self.root != nil { self.startTracking(since: self.appliedEventId) }
                return
            }
            let duration = Date.now.timeIntervalSince(started)
            let meta = TreeCache.Meta(eventId: startEventId, scanDate: .now, scanDuration: duration,
                                      deniedCount: scanner.deniedCount, deniedPaths: scanner.deniedPaths)
            let (breakdown, folders) = await Task.detached {
                TreeCache.save(root: tree, meta: meta)
                return (CategoryBreakdown.compute(root: tree), HistoryStore.folderMap(root: tree))
            }.value
            self.progress = scanner.progress
            self.root = tree
            self.exploreFocus = tree.node(atPath: self.home) ?? tree
            self.breakdown = breakdown
            self.deniedPaths = scanner.deniedPaths
            self.deniedCount = scanner.deniedCount
            self.lastScan = .now
            self.scanDuration = duration
            self.appliedEventId = startEventId
            self.scanState = .done
            self.treeVersion += 1
            self.duplicateGroups = nil
            self.liveState = .catchingUp
            self.startTracking(since: startEventId)
            await self.refreshSystemInfo()
            self.history.recordScan(self.volume, scanned: tree.size, folders: folders)
            self.historyVersion += 1
            await self.rebuildRecommendations()
        }
    }

    func cancelScan() {
        scanner?.cancel()
    }

    // MARK: - Live updates

    enum LiveState { case off, catchingUp, live }
    var liveState: LiveState = .off
    var lastLiveUpdate: Date?
    private var tracker: ChangeTracker?
    private var appliedEventId: UInt64 = 0
    private var pendingChanges: [String: Bool] = [:]   // path → recursive
    private var pendingEventId: UInt64 = 0
    private var pendingHistoryDone = false
    private var applying = false
    private var lastRecsBuild = Date.distantPast
    private var derivedRefreshScheduled = false

    private func startTracking(since eventId: UInt64) {
        let tracker = ChangeTracker { [weak self] batch in
            Task { @MainActor in self?.receive(batch) }
        }
        self.tracker = tracker
        tracker.start(since: eventId)
    }

    private func stopTracking() {
        tracker?.stop()
        tracker = nil
        liveState = .off
        pendingChanges.removeAll()
    }

    private func receive(_ batch: ChangeTracker.Batch) {
        guard tracker != nil, scanState == .done else { return }
        if batch.needsFullScan {
            stopTracking()
            startScan()
            return
        }
        for c in batch.changes { pendingChanges[c.path] = (pendingChanges[c.path] ?? false) || c.recursive }
        pendingEventId = max(pendingEventId, batch.lastEventId)
        if batch.historyDone { pendingHistoryDone = true }
        if !applying { Task { await applyPendingChanges() } }
    }

    /// Re-reads only the directories FSEvents reported and splices the results into the tree.
    private func applyPendingChanges() async {
        guard let root, !applying else { return }
        applying = true
        defer { applying = false }

        while !pendingChanges.isEmpty || pendingHistoryDone {
            let changes = pendingChanges
            let eventId = pendingEventId
            let historyDone = pendingHistoryDone
            pendingChanges.removeAll()
            pendingHistoryDone = false

            let probe = DiskScanner(rootPath: root.name)
            // Collapse: drop anything inside a directory that's being re-read recursively.
            let recursiveRoots = changes.filter(\.value).map(\.key)
            var targets: [(node: FileNode, path: String, known: Set<String>, recursive: Bool)] = []
            var seen = Set<ObjectIdentifier>()
            for (path, recursive) in changes.sorted(by: { $0.key < $1.key }) {
                if probe.isOutsideScan(path) { continue }
                if recursiveRoots.contains(where: { $0 != path && path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { continue }
                // Changed folder might be new; refresh its nearest known ancestor instead.
                var node = root
                var nodePath = root.name
                var exact = true
                for comp in path.split(separator: "/") {
                    guard let next = node.child(named: String(comp)), next.isDirectory else { exact = false; break }
                    node = next
                    nodePath = nodePath == "/" ? "/" + comp : nodePath + "/" + comp
                }
                if node.isPackage && !exact { /* changes inside a bundle: refresh the bundle itself */ }
                guard seen.insert(node.id).inserted else { continue }
                let known = Set(node.children.filter(\.isDirectory).map(\.name))
                targets.append((node, nodePath, known, recursive && exact))
            }

            let requests = targets.map { ($0.path, $0.node.name, $0.known, $0.recursive) }
            let results = await Task.detached(priority: .utility) {
                requests.map { probe.refreshDirectory(path: $0.0, name: $0.1, knownSubdirs: $0.2, recursive: $0.3) }
            }.value

            let focusPath = exploreFocus?.path
            for (target, fresh) in zip(targets, results) {
                splice(fresh, into: target.node, root: root)
            }
            if let focusPath, let f = exploreFocus, !(f === root || f.isDescendant(of: root)) {
                exploreFocus = root.node(atPath: focusPath) ?? root.node(atPath: home) ?? root
            }

            appliedEventId = max(appliedEventId, eventId)
            if !targets.isEmpty {
                bumpTreeVersionThrottled()
                lastLiveUpdate = .now
            }
            if historyDone && liveState == .catchingUp {
                liveState = .live
                lastLiveUpdate = .now
                scheduleDerivedRefresh(full: true)
                // Record the caught-up state so History can compare against it.
                let folders = HistoryStore.folderMap(root: root)
                if let last = history.scans.last, Date.now.timeIntervalSince(last.date) > 3600 {
                    history.recordScan(volume, scanned: root.size, folders: folders)
                    historyVersion += 1
                }
            } else if !targets.isEmpty {
                scheduleDerivedRefresh(full: false)
            }
        }
    }

    private func splice(_ fresh: FileNode, into node: FileNode, root: FileNode) {
        guard node === root || node.isDescendant(of: root) else { return }
        let oldSize = node.size, oldCount = node.fileCount
        var oldDirs: [String: FileNode] = [:]
        for c in node.children where c.isDirectory { oldDirs[c.name] = c }
        var children: [FileNode] = []
        children.reserveCapacity(fresh.children.count)
        for c in fresh.children {
            if c.flags.contains(.placeholder), let old = oldDirs.removeValue(forKey: c.name) {
                children.append(old)
            } else {
                c.flags.remove(.placeholder)
                c.parent = node
                children.append(c)
            }
        }
        let kept = Set(children.map(\.id))
        for c in node.children where !kept.contains(c.id) { c.parent = nil }
        node.children = children
        if fresh.isDenied { node.flags.insert(.denied) } else { node.flags.remove(.denied) }
        DiskScanner.finalize(node)
        let dSize = node.size - oldSize, dCount = node.fileCount - oldCount
        guard dSize != 0 || dCount != 0 else { return }
        var p = node.parent
        while let n = p {
            n.size += dSize
            n.fileCount += dCount
            n.children.sort { $0.size > $1.size }
            p = n.parent
        }
    }

    private var treeBumpScheduled = false

    /// Background churn (caches, logs) changes the tree constantly; redraw views at most every 3 s for it.
    private func bumpTreeVersionThrottled() {
        guard !treeBumpScheduled else { return }
        treeBumpScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            treeBumpScheduled = false
            treeVersion += 1
        }
    }

    /// Breakdown and recommendations are relatively expensive; refresh them at most every 30 s while live.
    private func scheduleDerivedRefresh(full: Bool) {
        guard !derivedRefreshScheduled else { return }
        derivedRefreshScheduled = true
        let delay = full ? 0 : max(0, 30 - Date.now.timeIntervalSince(lastRecsBuild))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            derivedRefreshScheduled = false
            guard let root else { return }
            breakdown = await Task.detached { CategoryBreakdown.compute(root: root) }.value
            refreshVolume()
            await rebuildRecommendations(includeSlow: full || Date.now.timeIntervalSince(lastSlowRecs) > 600)
        }
    }

    /// Persists the live tree (called on quit) so the next launch replays only newer changes.
    func saveCache() {
        guard let root, scanState == .done, appliedEventId > 0 else { return }
        TreeCache.save(root: root, meta: TreeCache.Meta(eventId: appliedEventId, scanDate: lastScan ?? .now,
                                                         scanDuration: scanDuration, deniedCount: deniedCount,
                                                         deniedPaths: deniedPaths))
    }

    private var lastSlowRecs = Date.distantPast

    /// `includeSlow` reruns external tools (brew, simctl); otherwise their previous results are reused.
    func rebuildRecommendations(includeSlow: Bool = true) async {
        guard let root else { return }
        recommendationsLoading = true
        lastRecsBuild = .now
        if includeSlow { lastSlowRecs = .now }
        let engine = RecommendationEngine(root: root, includeSlow: includeSlow)
        var recs = await Task.detached(priority: .utility) { await engine.build() }.value
        if !includeSlow {
            let fresh = Set(recs.map(\.id))
            recs += recommendations.filter { RecommendationEngine.slowIds.contains($0.id) && !fresh.contains($0.id) }
        }
        var newSelections: [String: Set<String>] = [:]
        for r in recs {
            if let existing = selections[r.id] {
                newSelections[r.id] = existing.intersection(r.entries.map(\.id))
            } else {
                newSelections[r.id] = Set(r.entries.filter(\.preselected).map(\.id))
            }
        }
        selections = newSelections
        recommendations = recs.sorted { ($0.group.rawValue, $0.safety, -$0.totalSize) < ($1.group.rawValue, $1.safety, -$1.totalSize) }
        recommendationsLoading = false
    }

    // MARK: - Actions

    func requestTrash(_ nodes: [FileNode], title: String? = nil) {
        let items = nodes.filter(\.isRealItem).map { TrashItem(url: $0.url, name: $0.displayName, size: $0.size, node: $0) }
        guard !items.isEmpty else { return }
        trashRequest = TrashRequest(title: title ?? (items.count == 1 ? "Move “\(items[0].name)” to Trash?" : "Move \(items.count) items to Trash?"), items: items)
    }

    func perform(_ rec: Recommendation) {
        let selected = selectedEntries(of: rec)
        switch rec.action {
        case .trash:
            let items = selected.map { TrashItem(url: $0.url, name: $0.name, size: $0.size, node: $0.node) }
            guard !items.isEmpty else { return }
            trashRequest = TrashRequest(title: rec.title, items: items)
        case .emptyTrash:
            requestEmptyTrash()
        case let .command(exe, args, perEntry, admin):
            let invocations: [(String, [String])] = perEntry
                ? selected.compactMap { e in e.commandArgument.map { (exe, args + [$0]) } }
                : [(exe, args)]
            guard !invocations.isEmpty else { return }
            commandRequest = CommandRequest(title: rec.title, explanation: rec.summary,
                                            estimatedSize: rec.entries.isEmpty ? rec.totalSize : selected.reduce(0) { $0 + $1.size },
                                            invocations: invocations, admin: admin)
        case let .guidance(_, url):
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    func requestEmptyTrash() {
        let size = trashSize ?? 0
        trashRequest = TrashRequest(title: "Empty the Trash?",
                                    items: [TrashItem(url: URL(fileURLWithPath: home + "/.Trash"), name: "Everything in the Trash", size: size)],
                                    isEmptyTrash: true)
    }

    /// Moves items to the Trash, then updates the tree in place so the UI reflects it immediately.
    func executeTrash(_ request: TrashRequest, emptyAfterwards: Bool) async -> (moved: Int, failed: [String]) {
        if request.isEmptyTrash {
            let ok = await emptyTrash()
            return ok ? (1, []) : (0, ["The Trash couldn't be emptied. Try emptying it from the Dock."])
        }
        var moved = 0
        var failed: [String] = []
        var freedNodes: [FileNode] = []
        for item in request.items {
            do {
                let result = try await NSWorkspace.shared.recycle([item.url])
                moved += 1
                if let node = item.node ?? root?.node(atPath: item.url.path) {
                    node.detach()
                    if let trash = trashNode, let newURL = result[item.url] {
                        node.name = newURL.lastPathComponent
                        node.attach(to: trash)
                    }
                    freedNodes.append(node)
                }
            } catch {
                failed.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if emptyAfterwards && moved > 0 { _ = await emptyTrash() }
        await afterMutation()
        let total = request.items.filter { item in !failed.contains { $0.hasPrefix(item.name + ":") } }.reduce(0) { $0 + $1.size }
        showToast(emptyAfterwards ? "Freed \(Fmt.bytes(total))" : "Moved \(Fmt.bytes(total)) to the Trash. Empty it to free the space.")
        return (moved, failed)
    }

    @discardableResult
    func emptyTrash() async -> Bool {
        let trashURL = URL(fileURLWithPath: home + "/.Trash")
        var ok = false
        if let items = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            ok = await Task.detached {
                var allOK = true
                for i in items { do { try FileManager.default.removeItem(at: i) } catch { allOK = false } }
                return allOK
            }.value
        }
        if !ok {
            let r = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
            ok = r.status == 0
        }
        if let trash = trashNode {
            let before = trash.size
            for c in trash.children { c.detach() }
            if ok { showToast("Emptied the Trash, freed \(Fmt.bytes(before))") }
        } else if ok {
            showToast("Emptied the Trash")
        }
        await afterMutation()
        return ok
    }

    func runCommand(_ request: CommandRequest) async -> ShellResult {
        var combined = ShellResult(status: 0, stdout: "", stderr: "")
        let before = VolumeStats.current().available
        for (exe, args) in request.invocations {
            let r = request.admin ? await Shell.runAsAdmin(Shell.quoted([exe] + args)) : await Shell.run(exe, args)
            combined.stdout += r.stdout
            combined.stderr += r.stderr
            if r.status != 0 { combined.status = r.status }
        }
        let freed = VolumeStats.current().available - before
        await afterMutation()
        if combined.status == 0 {
            showToast(freed > 10_000_000 ? "Done. Freed \(Fmt.bytes(freed))" : "Done")
            // Command-based cleanups change things the tree can't track precisely; a rescan keeps numbers honest.
        } else {
            showToast("The command reported an error", symbol: "exclamationmark.triangle.fill", isError: true)
        }
        return combined
    }

    func deleteSnapshots() async {
        let r = await Shell.runAsAdmin("/usr/bin/tmutil deletelocalsnapshots /")
        snapshots = await LocalSnapshot.list()
        refreshVolume()
        if r.status == 0 { showToast("Deleted local snapshots") }
        else { showToast("Couldn't delete snapshots", symbol: "exclamationmark.triangle.fill", isError: true) }
    }

    private func afterMutation() async {
        treeVersion += 1
        if let root {
            breakdown = await Task.detached { CategoryBreakdown.compute(root: root) }.value
            if let f = exploreFocus, f !== root, f.parent == nil { exploreFocus = root.node(atPath: home) ?? root }
        }
        refreshVolume()
        await rebuildRecommendations()
    }

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill", isError: Bool = false) {
        let t = Toast(message: message, symbol: symbol, isError: isError)
        withAnimation(.spring(duration: 0.35)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(4.5))
            if toast == t { withAnimation(.easeOut) { toast = nil } }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Copied path", symbol: "doc.on.clipboard")
    }

    func explore(_ node: FileNode) {
        exploreFocus = node.isDirectory ? node : node.parent
        section = .explore
    }

    // MARK: - Duplicates

    func findDuplicates(minSize: Int64) {
        guard let root else { return }
        let finder = DuplicateFinder()
        duplicateFinder = finder
        duplicateProgress = DuplicateProgress()
        duplicateGroups = nil
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in if let f = self?.duplicateFinder { self?.duplicateProgress = f.progress } }
        }
        Task {
            let groups = await Task.detached(priority: .userInitiated) { await finder.find(root: root, minSize: minSize) }.value
            t.invalidate()
            duplicateKeep = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.files[0]) })
            duplicateGroups = groups
            duplicateProgress = nil
            duplicateFinder = nil
        }
    }

    func cancelDuplicates() {
        duplicateFinder?.cancel()
    }

    func pruneDuplicateGroups() {
        guard var groups = duplicateGroups else { return }
        let trash = trashNode
        for i in groups.indices {
            groups[i].files.removeAll { f in f.parent == nil || (trash.map { f.isDescendant(of: $0) } ?? false) }
        }
        duplicateGroups = groups.filter { $0.files.count > 1 }
    }
}
