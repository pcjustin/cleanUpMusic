import AppKit
import CleanUpMusicCore
import SwiftUI

struct CoversView: View {
    @Environment(AppController.self) var m

    var body: some View {
        @Bindable var m = m
        VStack(alignment: .leading) {
            HStack {
                Button("掃描封面") { m.scanCovers() }.disabled(m.root == nil || m.scanning)
                Toggle("只顯示缺封面", isOn: $m.onlyMissing)
                TextField("篩選專輯", text: $m.coverFilter).frame(maxWidth: 240)
            }.padding([.top, .horizontal])
            covers
        }
    }

    private var covers: some View {
        @Bindable var m = m
        return HSplitView {
            List(m.shownAlbums, selection: $m.coverSelection) { a in
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
                if let picker = m.picker {
                    CoverPicker(p: picker).id(picker.id)
                } else {
                    Text("從左邊選一張專輯")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CoverPicker: View {
    @Bindable var p: CoverPickerController
    @Environment(AppController.self) var m
    @State private var urlText = ""

    var body: some View {
        let album = p.album
        VStack(alignment: .leading) {
            if !p.current.isEmpty {
                VStack(alignment: .leading) {
                    Text("目前封面").bold()
                    HStack(alignment: .top) {
                        ForEach(p.current, id: \.name) { c in
                            if let image = NSImage(data: c.data) {
                                VStack {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 170, height: 170)
                                    Text(c.name).font(.caption)
                                    Text("\(Int(image.size.width))×\(Int(image.size.height))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
            if album.split { Text("此資料夾含多個專輯（單曲），只能嵌入 metadata").foregroundStyle(.secondary) }
            if album.split, !p.folderCovers.isEmpty {
                HStack {
                    Text("資料夾裡的 \(p.folderCovers.map(\.lastPathComponent).joined(separator: "、")) 會顯示在這裡所有的單曲上")
                        .foregroundStyle(.orange)
                    Button("刪除") { p.deleteFolderCovers() }
                }
            }
            if !p.unreadable.isEmpty {
                imageRow("資料夾裡現有的圖（檔名 MinimServer 讀不到）", p.unreadable, button: "設為封面", action: p.promote)
            }
            if !p.parentImages.isEmpty {
                imageRow("上一層資料夾的圖", p.parentImages, button: "複製為封面", action: p.copyParent)
            }
            HStack {
                Toggle("存成 cover 檔", isOn: $p.toFile).disabled(album.split)
                Toggle("嵌入 metadata", isOn: $p.toEmbed)
            }
            HStack {
                TextField("搜尋", text: $p.query).onSubmit(p.search)
                Button("搜尋", action: p.search)
            }
            ScrollView {
                if p.searching { ProgressView() }
                if !p.searching && p.results.isEmpty { Text("沒有結果，可改搜尋字串，或手動設定封面") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
                    ForEach(p.results) { c in
                        Button { p.save(from: c.full) } label: {
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
                Button("使用網址") { p.save(fromText: urlText) }
                Button("選擇檔案…", action: pickFile)
                Text("或把圖片拖進來").foregroundStyle(.secondary)
            }
        }
        .padding()
        .disabled(m.scanning)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            p.save(from: u)
            return true
        }
    }

    private func imageRow(_ title: String, _ images: [URL], button: String, action: @escaping (URL) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text(title).bold()
            ScrollView(.horizontal) {
                HStack(alignment: .top) {
                    ForEach(images, id: \.self) { img in
                        VStack {
                            LocalImage(url: img).frame(width: 170, height: 170)
                            Text(img.lastPathComponent).font(.caption).lineLimit(1)
                            Button(button) { action(img) }
                        }
                        .frame(width: 180)
                    }
                }
            }
            Divider()
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        if panel.runModal() == .OK, let u = panel.url { p.save(from: u) }
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
