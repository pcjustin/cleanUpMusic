import CleanUpMusicCore
import SwiftUI

struct ChineseView: View {
    @Environment(AppController.self) var m

    var body: some View {
        @Bindable var m = m
        let groups = m.chineseGroups
        VStack(alignment: .leading) {
            HStack {
                Button("掃描簡體字") { m.scanChinese() }.disabled(m.root == nil || m.scanning)
                TextField("篩選（專輯或路徑）", text: $m.chineseFilter).frame(maxWidth: 320)
                Button("全選") { m.setSelected(groups.flatMap(\.changes), true) }
                Button("全不選") { m.setSelected(groups.flatMap(\.changes), false) }
                Text("\(groups.count) 張專輯").foregroundStyle(.secondary)
                Spacer()
                let n = m.selectedChanges.count
                Button("套用勾選 (\(n))") { m.applyChanges() }.disabled(n == 0 || m.scanning)
            }
            List(groups) { g in
                DisclosureGroup {
                    ForEach(g.changes) { c in
                        HStack {
                            Toggle("", isOn: Binding(get: { m.isSelected(c) }, set: { m.setSelected([c], $0) })).labelsHidden()
                            Text(c.kind.label).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                            Text(c.old).frame(maxWidth: .infinity, alignment: .leading)
                            Text("→")
                            Text(c.new).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help(c.url.path)
                    }
                } label: {
                    HStack {
                        Toggle("", isOn: Binding(get: { m.allSelected(g.changes) }, set: { m.setSelected(g.changes, $0) })).labelsHidden()
                        Text(g.name).bold()
                        Text(AppController.summary(g.changes)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
