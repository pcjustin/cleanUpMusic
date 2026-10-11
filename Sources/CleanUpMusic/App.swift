import AppKit
import CleanUpMusicCore
import SwiftUI

@main
struct CleanUpMusicApp: App {
    @State private var model = AppController { f in DispatchQueue.main.async(execute: f) }

    init() {
        Chinese.dataDir = Bundle.main.url(forResource: "opencc", withExtension: nil) // set by build-dmg.sh
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = Bundle.module.url(forResource: "AppIcon", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("CleanUpMusic") {
            ContentView().environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppController.self) var m

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("選擇音樂資料夾…", action: pick).disabled(m.scanning)
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
                MojibakeView().tabItem { Text("亂碼檔名 (\(m.mojibake.count))") }
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .alert("訊息", isPresented: Binding(get: { m.message != nil }, set: { if !$0 { m.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(m.message ?? "")
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        m.choose(url)
    }
}
