import SwiftUI

struct DiscsView: View {
    @EnvironmentObject var m: Model

    private var groups: [(name: String, changes: [Change])] {
        Dictionary(grouping: m.discs, by: \.group).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("掃描 CD 資料夾") { m.scanDiscs() }.disabled(m.root == nil || m.scanning)
                Text("同一層有 CD1 / Disc 2 / 碟3 之類資料夾時，依資料夾名稱補上 DISCNUMBER、DISCTOTAL，並把 ALBUM 改成「專輯 [Disc n]」").foregroundStyle(.secondary)
                Spacer()
                Button("全選專輯") { setSelected(true) }
                Button("全不選") { setSelected(false) }
                let n = Set(m.discs.filter(\.selected).map(\.group)).count
                Button("套用勾選 (\(n) 張專輯)") { m.applyDiscs() }.disabled(n == 0 || m.scanning)
            }
            List(groups, id: \.name) { g in
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
                        Toggle("", isOn: binding(g.changes)).labelsHidden()
                        Text(g.name).bold()
                        Text("\(Set(g.changes.map(\.url)).count) 首").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private func binding(_ changes: [Change]) -> Binding<Bool> {
        let ids = Set(changes.map(\.id))
        return Binding(
            get: { m.discs.filter { ids.contains($0.id) }.allSatisfy(\.selected) },
            set: { v in for i in m.discs.indices where ids.contains(m.discs[i].id) { m.discs[i].selected = v } })
    }

    private func setSelected(_ value: Bool) {
        for i in m.discs.indices { m.discs[i].selected = value }
    }
}
