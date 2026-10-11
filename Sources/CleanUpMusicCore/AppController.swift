import Foundation
import Observation

/// Changes of one album (簡轉繁), disc set (CD 編號) or folder (亂碼檔名), as the lists show them.
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
    public private(set) var mojibake: [Change] = []
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

    // 亂碼檔名
    public private(set) var selectedMojibake = Set<UUID>()

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
        mojibake = []
        selectedChanges = []
        selectedDiscs = []
        selectedMojibake = []
        coverSelection = nil
    }

    // Each scan ends with a message saying what it found, so a quick scan that finds nothing still visibly finishes;
    // `report` leads it with what an apply did before the rescan.

    public func scanCovers(report: String? = nil) {
        runScan(Library.scanCovers, report: report) { albums in
            self.albums = albums
            if !albums.contains(where: { $0.id == self.coverSelection }) { self.coverSelection = nil }
            self.coverRevision += 1
            let missing = albums.filter { $0.cover == .missing }.count
            let unreadable = albums.filter { if case .unreadable = $0.cover { true } else { false } }.count
            return "\(albums.count) 張專輯，缺封面 \(missing) 張，有圖但 MinimServer 讀不到 \(unreadable) 張。"
        }
    }

    public func scanChinese(report: String? = nil) {
        runScan(Library.scanChinese, report: report) { changes in
            self.changes = changes
            self.selectedChanges = []
            return changes.isEmpty ? "沒有找到簡體字。" : "\(Set(changes.map(\.group)).count) 張專輯共 \(changes.count) 項可轉成繁體。"
        }
    }

    public func scanSplits(report: String? = nil) {
        runScan(Library.scanSplits, report: report) { splits in
            self.splits = splits
            return splits.isEmpty ? "沒有資料夾的 ALBUM 標籤不一致。" : "\(splits.count) 個資料夾裡有不同的 ALBUM 標籤。"
        }
    }

    public func scanDiscs(report: String? = nil) {
        runScan(Library.scanDiscs, report: report) { discs in
            self.discs = discs
            self.selectedDiscs = []
            return discs.isEmpty ? "沒有需要補 CD 編號的專輯。" : "\(Set(discs.map(\.group)).count) 張專輯共 \(discs.count) 項標籤可補上。"
        }
    }

    public func scanMojibake(report: String? = nil) {
        runScan(Library.scanMojibake, report: report) { changes in
            self.mojibake = changes
            self.selectedMojibake = []
            return changes.isEmpty ? "沒有找到亂碼的檔名或資料夾名稱。" : "找到 \(changes.count) 個亂碼的檔名或資料夾名稱。"
        }
    }

    public func applyChanges() { apply(changes.filter { selectedChanges.contains($0.id) }) { self.scanChinese(report: $0) } }
    public func applyDiscs() { apply(discs.filter { selectedDiscs.contains($0.id) }) { self.scanDiscs(report: $0) } }
    public func applyMojibake() { apply(mojibake.filter { selectedMojibake.contains($0.id) }) { self.scanMojibake(report: $0) } }

    /// Applies the ticked changes, then rescans so the list matches the files again, reporting both.
    private func apply(_ selected: [Change], then rescan: @escaping @Sendable (String) -> Void) {
        guard !selected.isEmpty, !scanning else { return }
        scanning = true
        DispatchQueue.global().async { [ui] in
            let failures = Library.apply(selected)
            ui {
                self.scanning = false
                var report = "已套用勾選的 \(selected.count) 項變更。"
                if !failures.isEmpty { report += "其中 \(failures.count) 筆失敗：\n" + failures.joined(separator: "\n") }
                rescan(report + "\n\n重新掃描")
            }
        }
    }

    private func runScan<T>(_ scan: @escaping @Sendable (URL, (Int) -> Void) -> T, report: String?,
                            then apply: @escaping @Sendable (T) -> String) {
        guard let root, !scanning else { return }
        scanning = true
        progress = 0
        DispatchQueue.global().async { [ui] in
            let result = scan(root) { n in ui { self.progress = max(self.progress, n) } }
            nonisolated(unsafe) let r = result
            ui {
                let found = apply(r)
                self.scanning = false
                self.message = (report ?? "掃描") + "完成：" + found
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

    // MARK: 亂碼檔名

    public var mojibakeGroups: [ChangeGroup] { Self.grouped(mojibake) }

    public func allMojibakeSelected(_ changes: [Change]) -> Bool { changes.allSatisfy { selectedMojibake.contains($0.id) } }

    public func setMojibakeSelected(_ changes: [Change], _ value: Bool) {
        let ids = changes.map(\.id)
        if value { selectedMojibake.formUnion(ids) } else { selectedMojibake.subtract(ids) }
    }

    private static func grouped(_ changes: [Change]) -> [ChangeGroup] {
        Dictionary(grouping: changes, by: \.group).sorted { $0.key < $1.key }.map { ChangeGroup(name: $0.key, changes: $0.value) }
    }
}
