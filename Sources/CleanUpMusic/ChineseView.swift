import SwiftUI

struct ChineseView: View {
    @EnvironmentObject var m: Model
    @State private var filter = ""

    private var groups: [(name: String, changes: [Change])] {
        let shown = filter.isEmpty ? m.changes : m.changes.filter {
            $0.group.localizedCaseInsensitiveContains(filter) || $0.url.path.localizedCaseInsensitiveContains(filter)
        }
        return Dictionary(grouping: shown, by: \.group).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        let groups = groups
        let picked = Set(m.changes.filter(\.selected).map(\.id))
        VStack(alignment: .leading) {
            HStack {
                Button("掃描簡體字") { m.scanChinese() }.disabled(m.root == nil || m.scanning)
                TextField("篩選（專輯或路徑）", text: $filter).frame(maxWidth: 320)
                Button("全選") { setSelected(groups.flatMap(\.changes), true) }
                Button("全不選") { setSelected(groups.flatMap(\.changes), false) }
                Text("\(groups.count) 張專輯").foregroundStyle(.secondary)
                Spacer()
                let n = m.changes.filter(\.selected).count
                Button("套用勾選 (\(n))") { m.applyChanges() }.disabled(n == 0 || m.scanning)
            }
            List(groups, id: \.name) { g in
                DisclosureGroup {
                    ForEach(g.changes) { c in
                        HStack {
                            Toggle("", isOn: m.isSelected(c.id)).labelsHidden()
                            Text(c.kind.label).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                            Text(c.old).frame(maxWidth: .infinity, alignment: .leading)
                            Text("→")
                            Text(c.new).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help(c.url.path)
                    }
                } label: {
                    HStack {
                        Toggle("", isOn: groupBinding(g.changes, picked)).labelsHidden()
                        Text(g.name).bold()
                        Text(summary(g.changes)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private func summary(_ changes: [Change]) -> String {
        let folders = changes.filter { $0.kind == .folder }.count
        let files = changes.filter { $0.kind == .file }.count
        let tags = changes.count - folders - files
        return "資料夾 \(folders) · 檔名 \(files) · 標籤 \(tags)"
    }

    private func groupBinding(_ changes: [Change], _ picked: Set<UUID>) -> Binding<Bool> {
        Binding(
            get: { changes.allSatisfy { picked.contains($0.id) } },
            set: { setSelected(changes, $0) })
    }

    private func setSelected(_ changes: [Change], _ value: Bool) {
        let ids = Set(changes.map(\.id))
        for i in m.changes.indices where ids.contains(m.changes[i].id) { m.changes[i].selected = value }
    }
}
