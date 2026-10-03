import AppKit
import SwiftUI

struct SplitsView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("掃描分裂專輯") { m.scanSplits() }.disabled(m.root == nil || m.scanning)
                Text("同資料夾但 ALBUM 標籤不同；「幾乎相同」代表只差大小寫、空白、標點或簡繁").foregroundStyle(.secondary)
            }
            List(m.splits) { s in
                DisclosureGroup {
                    ForEach(s.variants, id: \.album) { v in
                        VStack(alignment: .leading) {
                            Text(v.album.isEmpty ? "（無 ALBUM）" : "「\(v.album)」").bold() + Text("  \(v.tracks.count) 首").foregroundStyle(.secondary)
                            Text(v.tracks.map(\.lastPathComponent).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                } label: {
                    HStack {
                        Text(s.dir.lastPathComponent).bold()
                        if s.similar { Text("幾乎相同").foregroundStyle(.orange) }
                        Text("\(s.variants.count) 種 ALBUM").foregroundStyle(.secondary)
                        Spacer()
                        Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([s.dir]) }
                    }
                }
                .help(s.dir.path)
            }
        }
        .padding()
    }
}
