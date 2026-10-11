import Foundation
import Observation

/// Changes of one album (簡轉繁) or disc set (CD 編號), as the lists show them.
public struct ChangeGroup: Identifiable, Sendable {
    public let name: String
    public let changes: [Change]
    public var id: String { name }
}

/// Everything the window shows and does, shared by the macOS (SwiftUI) and Windows (WinUI) views. Its state is
/// owned by the UI thread: views call it there, and work done elsewhere comes back through `ui`.
@Observable
public final class AppController: @unchecked Sendable {
    public private(set) var root: URL?
    public private(set) var albums: [Album] = []
    public private(set) var changes: [Change] = []
    public private(set) var splits: [AlbumSplit] = []
    public private(set) var discs: [Change] = []
    public private(set) var scanning = false
    public private(set) var progress = 0
    public var message: String?
    /// Bumped whenever cover files may have changed, so the cover picker reloads what it shows.
    public private(set) var coverRevision = 0 {
        didSet { picker?.reload() }
    }

    // 封面
    public var onlyMissing = true
    public var coverFilter = ""
    public var coverSelection: URL? {
        didSet { if coverSelection != oldValue { picker = coverSelection.map { CoverPickerController(id: $0, app: self) } } }
    }
    /// The cover picker of the selected album.
    public private(set) var picker: CoverPickerController?

    // 簡轉繁
    public var chineseFilter = ""
    public private(set) var selectedChanges = Set<UUID>()

    // CD 編號
    public private(set) var selectedDiscs = Set<UUID>()

    /// Runs a closure on the UI thread.
    @ObservationIgnored public let ui: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init(ui: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.ui = ui
    }

    public func choose(_ url: URL) {
        root = url
        albums = []
        changes = []
        splits = []
        discs = []
        selectedChanges = []
        selectedDiscs = []
        coverSelection = nil
    }

    public func scanCovers() {
        runScan(Library.scanCovers) { albums in
            self.albums = albums
            if !albums.contains(where: { $0.id == self.coverSelection }) { self.coverSelection = nil }
            self.coverRevision += 1
        }
    }
    public func scanChinese() { runScan(Library.scanChinese) { self.changes = $0; self.selectedChanges = [] } }
    public func scanSplits() { runScan(Library.scanSplits) { self.splits = $0 } }
    public func scanDiscs() { runScan(Library.scanDiscs) { self.discs = $0; self.selectedDiscs = [] } }

    public func applyChanges() { apply(changes.filter { selectedChanges.contains($0.id) }, then: scanChinese) }
    public func applyDiscs() { apply(discs.filter { selectedDiscs.contains($0.id) }, then: scanDiscs) }

    /// Applies the ticked changes, reports failures, and rescans so the list matches the files again.
    private func apply(_ selected: [Change], then rescan: @escaping @Sendable () -> Void) {
        guard !selected.isEmpty, !scanning else { return }
        scanning = true
        DispatchQueue.global().async { [ui] in
            let failures = Library.apply(selected)
            ui {
                self.scanning = false
                if !failures.isEmpty { self.message = "\(failures.count) 筆失敗：\n" + failures.joined(separator: "\n") }
                rescan()
            }
        }
    }

    private func runScan<T>(_ scan: @escaping @Sendable (URL, (Int) -> Void) -> T, then apply: @escaping @Sendable (T) -> Void) {
        guard let root, !scanning else { return }
        scanning = true
        progress = 0
        DispatchQueue.global().async { [ui] in
            let result = scan(root) { n in ui { self.progress = max(self.progress, n) } }
            nonisolated(unsafe) let r = result
            ui {
                apply(r)
                self.scanning = false
            }
        }
    }

    /// Runs a cover fix for one album off the UI thread (it writes to the NAS) and marks it covered on success.
    func fixCover(_ id: URL, covered: Bool = true, _ op: @escaping @Sendable () async throws -> Void) {
        guard !scanning else { return }
        scanning = true
        Task.detached { [ui] in
            let failure: String?
            do { try await op(); failure = nil } catch { failure = error.localizedDescription }
            ui {
                if let failure {
                    self.message = failure
                } else if covered, let i = self.albums.firstIndex(where: { $0.id == id }) {
                    self.albums[i].cover = .ok
                }
                self.coverRevision += 1
                self.scanning = false
            }
        }
    }

    // MARK: 封面

    public var shownAlbums: [Album] {
        albums.filter { a in
            (!onlyMissing || a.cover != .ok)
                && (coverFilter.isEmpty || [a.title, a.artist, a.dir.path].contains { $0.localizedCaseInsensitiveContains(coverFilter) })
        }
    }

    // MARK: 簡轉繁

    public var chineseGroups: [ChangeGroup] {
        let shown = chineseFilter.isEmpty ? changes : changes.filter {
            $0.group.localizedCaseInsensitiveContains(chineseFilter) || $0.url.path.localizedCaseInsensitiveContains(chineseFilter)
        }
        return Self.grouped(shown)
    }

    public func isSelected(_ change: Change) -> Bool { selectedChanges.contains(change.id) }

    /// Ticks or unticks changes; ticking a group's box passes all of its changes.
    public func setSelected(_ changes: [Change], _ value: Bool) {
        let ids = changes.map(\.id)
        if value { selectedChanges.formUnion(ids) } else { selectedChanges.subtract(ids) }
    }

    public func allSelected(_ changes: [Change]) -> Bool { changes.allSatisfy { selectedChanges.contains($0.id) } }

    public static func summary(_ changes: [Change]) -> String {
        let folders = changes.filter { $0.kind == .folder }.count
        let files = changes.filter { $0.kind == .file }.count
        let tags = changes.count - folders - files
        return "資料夾 \(folders) · 檔名 \(files) · 標籤 \(tags)"
    }

    // MARK: CD 編號

    public var discGroups: [ChangeGroup] { Self.grouped(discs) }

    public func allDiscsSelected(_ changes: [Change]) -> Bool { changes.allSatisfy { selectedDiscs.contains($0.id) } }

    public func setDiscsSelected(_ changes: [Change], _ value: Bool) {
        let ids = changes.map(\.id)
        if value { selectedDiscs.formUnion(ids) } else { selectedDiscs.subtract(ids) }
    }

    /// Albums (disc sets) with at least one ticked change.
    public var selectedDiscAlbums: Int { Set(discs.filter { selectedDiscs.contains($0.id) }.map(\.group)).count }

    public static func trackCount(_ changes: [Change]) -> Int { Set(changes.map(\.url)).count }

    private static func grouped(_ changes: [Change]) -> [ChangeGroup] {
        Dictionary(grouping: changes, by: \.group).sorted { $0.key < $1.key }.map { ChangeGroup(name: $0.key, changes: $0.value) }
    }
}
