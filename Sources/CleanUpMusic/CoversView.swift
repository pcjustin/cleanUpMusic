import AppKit
import SwiftUI

struct CoversView: View {
    @EnvironmentObject var m: Model
    @State private var selection: URL?
    @State private var onlyMissing = true
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("掃描封面") { m.scanCovers() }.disabled(m.root == nil || m.scanning)
                Toggle("只顯示缺封面", isOn: $onlyMissing)
                TextField("篩選專輯", text: $filter).frame(maxWidth: 240)
            }.padding([.top, .horizontal])
            covers
        }
    }

    private var shown: [Album] {
        m.albums.filter { a in
            (!onlyMissing || a.cover != .ok)
                && (filter.isEmpty || [a.title, a.artist, a.dir.path].contains { $0.localizedCaseInsensitiveContains(filter) })
        }
    }

    private var covers: some View {
        HSplitView {
            List(shown, selection: $selection) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).bold()
                    Text(a.artist)
                    if a.cover == .ok { Text("已有封面").foregroundStyle(.green) }
                    if case .unreadable(let imgs) = a.cover {
                        Text("有 \(imgs.count) 張圖但 MinimServer 讀不到").foregroundStyle(.orange)
                    }
                    Text(a.dir.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)

            Group {
                if let album = m.albums.first(where: { $0.id == selection }) {
                    CoverPicker(album: album).id(album.id)
                } else {
                    Text("從左邊選一張專輯")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CoverPicker: View {
    let album: Album
    @EnvironmentObject var m: Model
    @State private var query = ""
    @State private var results: [CoverCandidate] = []
    @State private var searching = false
    @State private var urlText = ""
    @State private var parentImages: [URL] = []
    @State private var current: [(name: String, image: NSImage)] = []
    @AppStorage("coverToFile") private var toFile = true
    @AppStorage("coverToEmbed") private var toEmbed = false

    var body: some View {
        VStack(alignment: .leading) {
            if !current.isEmpty {
                VStack(alignment: .leading) {
                    Text("目前封面").bold()
                    HStack(alignment: .top) {
                        ForEach(current, id: \.name) { c in
                            VStack {
                                Image(nsImage: c.image).resizable().scaledToFit().frame(width: 170, height: 170)
                                Text(c.name).font(.caption)
                                Text("\(Int(c.image.size.width))×\(Int(c.image.size.height))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                }
            }
            if case .unreadable(let imgs) = album.cover {
                imageRow("資料夾裡現有的圖（檔名 MinimServer 讀不到）", imgs, button: "設為封面") { try Library.promote($0) }
            }
            if !parentImages.isEmpty {
                imageRow("上一層資料夾的圖", parentImages, button: "複製為封面") {
                    try Library.saveCover(Data(contentsOf: $0), for: album, file: toFile, embed: toEmbed)
                }
            }
            HStack {
                Toggle("存成 cover 檔", isOn: $toFile)
                Toggle("嵌入 metadata", isOn: $toEmbed)
            }
            HStack {
                TextField("搜尋", text: $query).onSubmit(search)
                Button("搜尋", action: search)
            }
            ScrollView {
                if searching { ProgressView() }
                if !searching && results.isEmpty { Text("沒有結果，可改搜尋字串，或手動設定封面") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
                    ForEach(results) { c in
                        Button { save(from: c.full) } label: {
                            VStack {
                                AsyncImage(url: c.thumb) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(width: 170, height: 170)
                                Text(c.title).lineLimit(2).font(.caption)
                                Text(c.source).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("貼上圖片網址", text: $urlText)
                Button("使用網址") { if let u = URL(string: urlText) { save(from: u) } }
                Button("選擇檔案…", action: pickFile)
                Text("或把圖片拖進來").foregroundStyle(.secondary)
            }
        }
        .padding()
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            save(from: u)
            return true
        }
        .task(id: album.cover) {
            let a = album
            current = await Task.detached {
                var out: [(name: String, image: NSImage)] = []
                let files = (try? FileManager.default.contentsOfDirectory(at: a.dir, includingPropertiesForKeys: nil)) ?? []
                for u in files.filter(Library.isMinimCover).sorted(by: { $0.path < $1.path }) {
                    if let i = NSImage(contentsOf: u) { out.append((u.lastPathComponent, i)) }
                }
                if let d = Tags.embeddedArt(a.tracks[0]), let i = NSImage(data: d) { out.append(("內嵌", i)) }
                return out
            }.value
        }
        .task {
            query = "\(album.title) \(album.artist)"
            search()
            let parent = album.dir.deletingLastPathComponent()
            parentImages = await Task.detached {
                ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .filter { Library.imageExts.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path < $1.path }
            }.value
        }
    }

    private func imageRow(_ title: String, _ images: [URL], button: String, action: @escaping (URL) throws -> Void) -> some View {
        VStack(alignment: .leading) {
            Text(title).bold()
            ScrollView(.horizontal) {
                HStack(alignment: .top) {
                    ForEach(images, id: \.self) { img in
                        VStack {
                            LocalImage(url: img).frame(width: 170, height: 170)
                            Text(img.lastPathComponent).font(.caption).lineLimit(1)
                            Button(button) { m.fixCover(album) { try action(img) } }
                        }
                        .frame(width: 180)
                    }
                }
            }
            Divider()
        }
    }

    private func search() {
        searching = true
        Task {
            results = await CoverSearch.search(query)
            searching = false
        }
    }

    private func save(from url: URL) {
        m.fixCover(album) {
            let data = url.isFileURL ? try Data(contentsOf: url) : try await URLSession.shared.data(from: url).0
            try Library.saveCover(data, for: album, file: toFile, embed: toEmbed)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        if panel.runModal() == .OK, let u = panel.url { save(from: u) }
    }
}

struct LocalImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var size = ""

    var body: some View {
        VStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            Text(size).font(.caption2).foregroundStyle(.secondary)
        }
        .task {
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            image = loaded
            if let rep = loaded?.representations.first { size = "\(rep.pixelsWide)×\(rep.pixelsHigh)" }
        }
    }
}
