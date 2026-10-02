import AppKit
import SwiftUI

@main
struct CleanUpMusicApp: App {
    @StateObject private var model = Model()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
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
    @Published var scanning = false
    @Published var progress = 0
    @Published var message: String?

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        albums = []
        changes = []
    }

    func scanCovers() { runScan(Library.scanCovers) { self.albums = $0 } }
    func scanChinese() { runScan(Library.scanChinese) { self.changes = $0 } }

    private func runScan<T>(_ scan: @escaping (URL, (Int) -> Void) -> T, then apply: @escaping (T) -> Void) {
        guard let root, !scanning else { return }
        scanning = true
        progress = 0
        Task.detached {
            let result = scan(root) { n in Task { @MainActor in self.progress = n } }
            await MainActor.run {
                apply(result)
                self.scanning = false
            }
        }
    }

    /// Runs a cover fix for one album and drops it from the list on success.
    func fixCover(_ album: Album, _ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                albums.removeAll { $0.id == album.id }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func isSelected(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.changes.first { $0.id == id }?.selected ?? false },
            set: { v in if let i = self.changes.firstIndex(where: { $0.id == id }) { self.changes[i].selected = v } })
    }

    func applyChanges() {
        let selected = changes.filter(\.selected)
        guard !selected.isEmpty else { return }
        scanning = true
        Task.detached {
            let failures = Library.apply(selected)
            await MainActor.run {
                self.scanning = false
                if !failures.isEmpty { self.message = "\(failures.count) 筆失敗：\n" + failures.joined(separator: "\n") }
                self.scanChinese()
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("選擇音樂資料夾…") { m.pick() }
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
