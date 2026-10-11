import CleanUpMusicCore
import SwiftUI

struct DiscsView: View {
    @Environment(AppController.self) var m

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("掃描 CD 資料夾") { m.scanDiscs() }.disabled(m.root == nil || m.scanning)
                Text("同一層有 CD1 / Disc 2 / 碟3 之類資料夾時，依資料夾名稱補上 DISCNUMBER、DISCTOTAL，並把 ALBUM 改成「專輯 [Disc n]」").foregroundStyle(.secondary)
                Spacer()
                Button("全選專輯") { m.setDiscsSelected(m.discs, true) }
                Button("全不選") { m.setDiscsSelected(m.discs, false) }
                let n = m.selectedDiscAlbums
                Button("套用勾選 (\(n) 張專輯)") { m.applyDiscs() }.disabled(n == 0 || m.scanning)
            }
            List(m.discGroups) { g in
                DisclosureGroup {
                    ForEach(g.changes) { c in
                        HStack {
                            Text(c.kind.label).frame(width: 100, alignment: .leading).foregroundStyle(.secondary)
                            Text(c.url.deletingLastPathComponent().lastPathComponent + "/" + c.url.lastPathComponent).frame(maxWidth: .infinity, alignment: .leading)
                            Text(c.old.isEmpty ? "（無）" : c.old)
                            Text("→")
                            Text(c.new)
                        }
                        .help(c.url.path)
                    }
                } label: {
                    HStack {
                        Toggle("", isOn: Binding(get: { m.allDiscsSelected(g.changes) }, set: { m.setDiscsSelected(g.changes, $0) })).labelsHidden()
                        Text(g.name).bold()
                        Text("\(AppController.trackCount(g.changes)) 首").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
