import CleanUpMusicCore
import SwiftUI

struct MojibakeView: View {
    @Environment(AppController.self) var m

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("掃描亂碼檔名") { m.scanMojibake() }.disabled(m.root == nil || m.scanning)
                Text("檔名或資料夾名稱被用錯的編碼讀成亂碼（如 Shift-JIS、GBK、Big5 被當成西歐或 DOS 編碼）時，改回正確的文字").foregroundStyle(.secondary)
                Spacer()
                Button("全選") { m.setMojibakeSelected(m.mojibake, true) }
                Button("全不選") { m.setMojibakeSelected(m.mojibake, false) }
                let n = m.selectedMojibake.count
                Button("套用勾選 (\(n))") { m.applyMojibake() }.disabled(n == 0 || m.scanning)
            }
            List(m.mojibakeGroups) { g in
                DisclosureGroup {
                    ForEach(g.changes) { c in
                        HStack {
                            Toggle("", isOn: Binding(get: { m.allMojibakeSelected([c]) }, set: { m.setMojibakeSelected([c], $0) })).labelsHidden()
                            Text(c.kind.label).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                            Text(c.note).frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                            Text(c.old).frame(maxWidth: .infinity, alignment: .leading)
                            Text("→")
                            Text(c.new).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help(c.url.path)
                    }
                } label: {
                    HStack {
                        Toggle("", isOn: Binding(get: { m.allMojibakeSelected(g.changes) }, set: { m.setMojibakeSelected(g.changes, $0) })).labelsHidden()
                        Text(g.name).bold()
                        Text("\(g.changes.count) 個").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
