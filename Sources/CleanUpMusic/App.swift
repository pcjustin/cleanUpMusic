import AppKit
import SwiftUI

@main
struct CleanUpMusicApp: App {
    @StateObject private var model = Model()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = Bundle.module.url(forResource: "AppIcon", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("CleanUpMusic") {
            ContentView().environmentObject(model)
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var root: URL?
    @Published var albums: [Album] = []
    @Published var changes: [Change] = []
    @Published var splits: [AlbumSplit] = []
    @Published var discs: [Change] = []
    @Published var scanning = false
    @Published var progress = 0
    @Published var message: String?
    /// Bumped whenever cover files may have changed, so the cover picker reloads what it shows.
    @Published private(set) var coverRevision = 0

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        albums = []
        changes = []
        splits = []
        discs = []
    }

    func scanCovers() { runScan(Library.scanCovers) { self.albums = $0; self.coverRevision += 1 } }
    func scanChinese() { runScan(Library.scanChinese) { self.changes = $0 } }
    func scanSplits() { runScan(Library.scanSplits) { self.splits = $0 } }
    func scanDiscs() { runScan(Library.scanDiscs) { self.discs = $0 } }

    func applyChanges() { apply(changes, then: scanChinese) }
    func applyDiscs() { apply(discs, then: scanDiscs) }

    /// Applies the ticked changes, reports failures, and rescans so the list matches the files again.
    private func apply(_ list: [Change], then rescan: @escaping () -> Void) {
        let selected = list.filter(\.selected)
        guard !selected.isEmpty, !scanning else { return }
        scanning = true
        Task.detached {
            let failures = Library.apply(selected)
            await MainActor.run {
                self.scanning = false
                if !failures.isEmpty { self.message = "\(failures.count) 筆失敗：\n" + failures.joined(separator: "\n") }
                rescan()
            }
        }
    }

    private func runScan<T>(_ scan: @escaping (URL, (Int) -> Void) -> T, then apply: @escaping (T) -> Void) {
        guard let root, !scanning else { return }
        scanning = true
        progress = 0
        Task.detached {
            let result = scan(root) { n in Task { @MainActor in self.progress = max(self.progress, n) } }
            await MainActor.run {
                apply(result)
                self.scanning = false
            }
        }
    }

    /// Runs a cover fix for one album off the main thread (it writes to the NAS) and marks it covered on success.
    func fixCover(_ album: Album, covered: Bool = true, _ op: @escaping @Sendable () async throws -> Void) {
        guard !scanning else { return }
        scanning = true
        Task {
            do {
                try await Task.detached(operation: op).value
                if covered, let i = albums.firstIndex(where: { $0.id == album.id }) { albums[i].cover = .ok }
            } catch {
                message = error.localizedDescription
            }
            coverRevision += 1
            scanning = false
        }
    }

    func isSelected(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.changes.first { $0.id == id }?.selected ?? false },
            set: { v in if let i = self.changes.firstIndex(where: { $0.id == id }) { self.changes[i].selected = v } })
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("選擇音樂資料夾…") { m.pick() }.disabled(m.scanning)
                Text(m.root?.path ?? "未選擇").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if m.scanning {
                    ProgressView().controlSize(.small)
                    Text("處理中… \(m.progress)")
                }
            }
            .padding()
            TabView {
                CoversView().tabItem { Text("封面 (\(m.albums.count))") }
                ChineseView().tabItem { Text("簡轉繁 (\(m.changes.count))") }
                SplitsView().tabItem { Text("專輯分裂 (\(m.splits.count))") }
                DiscsView().tabItem { Text("CD 編號 (\(m.discs.count))") }
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .alert("訊息", isPresented: Binding(get: { m.message != nil }, set: { if !$0 { m.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(m.message ?? "")
        }
    }
}
