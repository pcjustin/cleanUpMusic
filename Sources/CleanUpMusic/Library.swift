import Foundation

enum CoverState: Equatable {
    case ok, missing
    case unreadable([URL])
}

struct Album: Identifiable {
    let dir: URL
    /// True when the folder holds tracks of several ALBUMs (e.g. singles); folder-level cover files don't apply.
    var split = false
    var id: URL { split ? tracks[0] : dir }
    let tracks: [URL]
    var cover: CoverState
    let title: String
    let artist: String
}

struct AlbumSplit: Identifiable {
    struct Variant {
        let album: String
        let tracks: [URL]
    }
    let dir: URL
    let variants: [Variant]
    /// Values differ only by case, spacing, width or Simplified/Traditional: almost certainly one album.
    let similar: Bool
    var id: URL { dir }
}

enum ChangeKind: Hashable {
    case tag(String), file, folder

    var label: String {
        switch self {
        case .tag(let k): k
        case .file: "檔名"
        case .folder: "資料夾"
        }
    }
}

struct Change: Identifiable {
    let id = UUID()
    let kind: ChangeKind
    let url: URL
    let old: String
    let new: String
    var group = ""
    var selected = false
}

enum Library {
    static let tagKeys = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DISCNUMBER", "DISCTOTAL"]
    static let audioExts: Set = ["flac", "mp3", "m4a", "wav", "aif", "aiff", "ape"]
    static let imageExts: Set = ["jpg", "jpeg", "png", "webp"]
    static let coverNames: Set = ["folder", "cover"]
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CleanUpMusic/changes.log")

    private struct AudioDir {
        let dir: URL
        let tracks: [URL]
        let files: [URL]
    }

    /// Folders that directly contain audio, plus the root depth (symlink-resolved, like the enumerator's paths).
    private static func audioDirs(_ root: URL) -> (dirs: [AudioDir], rootDepth: Int) {
        var byDir: [String: [URL]] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        while let u = e?.nextObject() as? URL {
            if u.lastPathComponent.hasPrefix(".") { continue }
            byDir[u.deletingLastPathComponent().path, default: []].append(u)
        }
        let dirs = byDir.sorted { $0.key < $1.key }.compactMap { path, files -> AudioDir? in
            let tracks = files.filter { audioExts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            return tracks.isEmpty ? nil : AudioDir(dir: URL(fileURLWithPath: path, isDirectory: true), tracks: tracks, files: files)
        }
        let realRoot = realpath(root.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root.path
        return (dirs, URL(fileURLWithPath: realRoot).pathComponents.count)
    }

    /// All albums with their cover state. Renames `cover.jpeg` / `folder.jpeg` on the way.
    static func scanCovers(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Album] {
        var albums: [Album] = []
        for (i, d) in audioDirs(root).dirs.enumerated() {
            progress(i)
            let images = d.files.filter { imageExts.contains($0.pathExtension.lowercased()) }.map(fixJpeg)
            // ponytail: reads every track's tags to detect singles; sample a few tracks if NAS scans get slow.
            let tags = Tags.readAll(d.tracks)
            let byAlbum = Dictionary(grouping: d.tracks.indices) { tags[$0]["ALBUM"]?.first ?? "" }
            let split = byAlbum.count > 1
            for idxs in byAlbum.values.sorted(by: { $0[0] < $1[0] }) {
                let tracks = idxs.map { d.tracks[$0] }
                let t = tags[idxs[0]]
                albums.append(Album(
                    dir: d.dir, split: split, tracks: tracks,
                    cover: coverState(images: images, firstTrack: tracks[0]),
                    title: t["ALBUM"]?.first ?? d.dir.lastPathComponent,
                    artist: (t["ALBUMARTIST"] ?? t["ARTIST"])?.first ?? ""))
            }
        }
        return albums
    }

    /// Folders whose tracks carry different ALBUM tags, which MinimServer shows as separate albums.
    static func scanSplits(_ root: URL, progress: (Int) -> Void = { _ in }) -> [AlbumSplit] {
        var splits: [AlbumSplit] = []
        for (i, d) in audioDirs(root).dirs.enumerated() {
            progress(i)
            let albumOf = Dictionary(uniqueKeysWithValues: zip(d.tracks, Tags.readAll(d.tracks).map { $0["ALBUM"]?.first ?? "" }))
            let byAlbum = Dictionary(grouping: d.tracks) { albumOf[$0]! }
            guard byAlbum.count > 1 else { continue }
            let variants = byAlbum.map { AlbumSplit.Variant(album: $0.key, tracks: $0.value) }
                .sorted { $0.tracks[0].path < $1.tracks[0].path }
            splits.append(AlbumSplit(dir: d.dir, variants: variants, similar: Set(variants.map { albumKey($0.album) }).count == 1))
        }
        return splits.sorted { ($0.similar ? 0 : 1, $0.dir.path) < ($1.similar ? 0 : 1, $1.dir.path) }
    }

    static func albumKey(_ album: String) -> String {
        Chinese.toTraditional(album)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static let discPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z])(?:cd|dis[ck])\\s*0*(\\d+)|碟\\s*0*(\\d+)", options: .caseInsensitive)

    private static let discSuffix = try! NSRegularExpression(
        pattern: "[\\s\\-–_:(\\[（【]*(?:(?<![A-Za-z])(?:cd|dis[ck])\\s*0*\\d+|碟\\s*0*\\d+)[\\s)\\]）】]*$", options: .caseInsensitive)

    /// "Album CD1" / "Album (Disc 2)" → "Album"; nil when there is no trailing disc marker.
    static func stripDisc(_ album: String) -> String? {
        let stripped = discSuffix.stringByReplacingMatches(in: album, range: NSRange(album.startIndex..., in: album), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty || stripped == album ? nil : stripped
    }

    static func discNumber(_ folder: String) -> Int? {
        guard let m = discPattern.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) else { return nil }
        return (1...2).lazy.compactMap { Range(m.range(at: $0), in: folder).flatMap { Int(folder[$0]) } }.first
    }

    /// Proposes DISCNUMBER, DISCTOTAL and ALBUM `X [Disc n]` (MinimServer's disc-heading form) for tracks under
    /// sibling folders named like CD1 / Disc 2 / 碟3 (tracks may sit in a subfolder such as CD1/FLAC).
    /// All discs of a set share the most common ALBUM base, and a lone ALBUMARTIST value fills tracks lacking one.
    /// A lone disc folder is skipped: there is nothing to merge it with.
    static func scanDiscs(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
        let (dirs, rootDepth) = audioDirs(root)
        var sets: [URL: [(tracks: [URL], n: Int)]] = [:]
        for d in dirs {
            var f = d.dir
            while f.pathComponents.count > rootDepth {
                if let n = discNumber(f.lastPathComponent) {
                    sets[f.deletingLastPathComponent(), default: []].append((d.tracks, n))
                    break
                }
                f = f.deletingLastPathComponent()
            }
        }
        var changes: [Change] = []
        var read = 0
        for (parent, items) in sets.sorted(by: { $0.key.path < $1.key.path }) where Set(items.map(\.n)).count > 1 {
            let total = String(Set(items.map(\.n)).count)
            let name = parent.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            let group = name.isEmpty ? parent.lastPathComponent : name
            let flat = items.flatMap { item in item.tracks.map { (url: $0, n: item.n) } }
            let allTags = Tags.readAll(flat.map(\.url))
            let tracks = zip(flat, allTags).map { (url: $0.url, n: $0.n, tags: $1) }
            read += tracks.count
            progress(read)
            let bases = tracks.compactMap { $0.tags["ALBUM"]?.first.map { stripDisc($0) ?? $0 } }
            let base = Dictionary(grouping: bases, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            let artists = Set(tracks.compactMap { $0.tags["ALBUMARTIST"]?.first })
            for (t, n, tags) in tracks {
                let old = tags["DISCNUMBER"]?.first ?? ""
                if Int(old.prefix(while: \.isNumber)) != n {
                    changes.append(Change(kind: .tag("DISCNUMBER"), url: t, old: old, new: String(n), group: group))
                }
                let oldTotal = tags["DISCTOTAL"]?.first ?? ""
                if oldTotal != total {
                    changes.append(Change(kind: .tag("DISCTOTAL"), url: t, old: oldTotal, new: total, group: group))
                }
                if let album = tags["ALBUM"]?.first, let base, case let new = base + " [Disc \(n)]", new != album {
                    changes.append(Change(kind: .tag("ALBUM"), url: t, old: album, new: new, group: group))
                }
                if artists.count == 1, tags["ALBUMARTIST"] == nil {
                    changes.append(Change(kind: .tag("ALBUMARTIST"), url: t, old: "", new: artists.first!, group: group))
                }
            }
        }
        return changes
    }

    static func applyDiscs(_ changes: [Change]) -> [String] {
        var failures: [String] = []
        for (url, items) in Dictionary(grouping: changes, by: \.url) {
            let fields = Dictionary(items.compactMap { c -> (String, [String])? in
                guard case .tag(let key) = c.kind else { return nil }
                return (key, [c.new])
            }, uniquingKeysWith: { $1 })
            do {
                try Tags.write(url, fields)
                for c in items { log("tag \(c.kind.label)", c.old, c.new) }
            } catch {
                failures.append(describe(error))
            }
        }
        return failures
    }

    static func scanChinese(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
        let (dirs, rootDepth) = audioDirs(root)
        let relative = { (u: URL) in u.pathComponents.dropFirst(rootDepth).joined(separator: "/") }
        var changes: [Change] = [], folderChanges: [Change] = []
        var seenFolders = Set<String>()
        var dirGroup: [String: String] = [:]
        for (i, d) in dirs.enumerated() {
            progress(i)
            let tags = Tags.readAll(d.tracks)
            let group = albumGroup(tags[0]) ?? relative(d.dir)
            dirGroup[d.dir.path] = group

            for (t, tag) in zip(d.tracks, tags) {
                for key in tagKeys {
                    guard let values = tag[key] else { continue }
                    let old = values.joined(separator: "; ")
                    if let new = Chinese.convert(old) { changes.append(Change(kind: .tag(key), url: t, old: old, new: new, group: group)) }
                }
                if let new = Chinese.convert(t.deletingPathExtension().lastPathComponent) {
                    changes.append(Change(kind: .file, url: t, old: t.lastPathComponent, new: new + "." + t.pathExtension, group: group))
                }
            }

            var f = d.dir
            while f.pathComponents.count > rootDepth, seenFolders.insert(f.path).inserted {
                if let new = Chinese.convert(f.lastPathComponent) {
                    folderChanges.append(Change(kind: .folder, url: f, old: f.lastPathComponent, new: new))
                }
                f = f.deletingLastPathComponent()
            }
        }
        // ponytail: O(folders × album dirs) prefix scan, fine for a few thousand albums; use a trie if it gets slow.
        for i in folderChanges.indices {
            let p = folderChanges[i].url.path
            let groups = Set(dirGroup.filter { $0.key == p || $0.key.hasPrefix(p + "/") }.values)
            folderChanges[i].group = groups.count == 1 ? groups.first! : "資料夾：" + relative(folderChanges[i].url)
        }
        return changes + folderChanges
    }

    /// Tracks sharing ALBUM + album artist are one album, even across CD1/CD2 folders.
    /// Without an artist, same-named albums can't be told apart, so the caller falls back to the folder.
    static func albumGroup(_ tags: [String: [String]]) -> String? {
        guard let album = tags["ALBUM"]?.first, !album.isEmpty,
              let artist = (tags["ALBUMARTIST"] ?? tags["ARTIST"])?.first, !artist.isEmpty else { return nil }
        return Chinese.toTraditional("\(album) – \(artist)")
    }

    static func coverState(images: [URL], firstTrack: URL) -> CoverState {
        if images.contains(where: isMinimCover) || Tags.hasEmbeddedArt(firstTrack) { return .ok }
        return images.isEmpty ? .missing : .unreadable(images.sorted { $0.path < $1.path })
    }

    static func isMinimCover(_ u: URL) -> Bool {
        coverNames.contains(u.deletingPathExtension().lastPathComponent.lowercased())
            && ["jpg", "png", "webp"].contains(u.pathExtension.lowercased())
    }

    /// MinimServer ignores `.jpeg`, so `cover.jpeg` / `folder.jpeg` become `.jpg`.
    static func fixJpeg(_ u: URL) -> URL {
        let base = u.deletingPathExtension().lastPathComponent
        guard u.pathExtension.lowercased() == "jpeg", coverNames.contains(base.lowercased()) else { return u }
        let target = u.deletingLastPathComponent().appendingPathComponent(base + ".jpg")
        return (try? rename(u, to: target)) ?? u
    }

    /// Renames a non-MinimServer image (e.g. `front.jpg`) to `cover.<ext>`.
    static func promote(_ image: URL) throws {
        let ext = image.pathExtension.lowercased() == "jpeg" ? "jpg" : image.pathExtension.lowercased()
        try rename(image, to: image.deletingLastPathComponent().appendingPathComponent("cover." + ext))
    }

    /// Writes `cover.<ext>` (dropping other `cover.*` variants) and/or embeds the image in every track.
    static func saveCover(_ data: Data, for album: Album, file: Bool, embed: Bool) throws {
        guard (file && !album.split) || embed else { throw CocoaError(.userCancelled) }
        if file && !album.split {
            let fm = FileManager.default
            let ext = imageExt(data)
            for other in ["jpg", "jpeg", "png", "webp"] where other != ext {
                try? fm.removeItem(at: album.dir.appendingPathComponent("cover." + other))
            }
            let target = album.dir.appendingPathComponent("cover." + ext)
            try data.write(to: target, options: .atomic)
            log("cover", "", target.path)
        }
        if embed {
            let mime = "image/" + (imageExt(data) == "jpg" ? "jpeg" : imageExt(data))
            var failed: [String] = []
            for t in album.tracks {
                do {
                    try Tags.embedArt(t, data, mime: mime)
                    log("cover embed", "", t.path)
                } catch {
                    failed.append(t.lastPathComponent)
                }
            }
            if !failed.isEmpty {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(failed.count) 個檔案無法嵌入（其餘已完成）：\n" + failed.joined(separator: "\n")])
            }
        }
    }

    static func imageExt(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.count > 12, data[8..<12].elementsEqual("WEBP".utf8) { return "webp" }
        return "jpg"
    }

    /// Applies tag writes first, then file renames, then folder renames deepest-first,
    /// so every change's URL is still valid when its turn comes. Returns failure messages.
    static func apply(_ changes: [Change]) -> [String] {
        var failures: [String] = []
        let tagFiles = Dictionary(grouping: changes.filter { if case .tag = $0.kind { true } else { false } }, by: \.url)
        for (url, items) in tagFiles {
            let current = Tags.read(url)
            var fields: [String: [String]] = [:]
            for c in items {
                guard case .tag(let key) = c.kind, let values = current[key] else { continue }
                fields[key] = values.map(Chinese.toTraditional)
            }
            do {
                try Tags.write(url, fields)
                for c in items { log("tag \(c.kind.label)", c.old, c.new) }
            } catch {
                failures.append(describe(error))
            }
        }
        let renames = changes.filter { $0.kind == .file }
            + changes.filter { $0.kind == .folder }.sorted { $0.url.pathComponents.count > $1.url.pathComponents.count }
        for c in renames {
            do {
                try rename(c.url, to: c.url.deletingLastPathComponent().appendingPathComponent(c.new))
            } catch {
                failures.append(describe(error))
            }
        }
        return failures
    }

    @discardableResult
    static func rename(_ from: URL, to: URL) throws -> URL {
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path])
        }
        // A file TagLib just rewrote can stay locked on SMB for a few seconds while the NAS re-reads it.
        for attempt in 1... {
            do {
                try FileManager.default.moveItem(at: from, to: to)
                break
            } catch where attempt < 5 {
                Thread.sleep(forTimeInterval: 2)
            }
        }
        log("rename", from.path, to.path)
        return to
    }

    static func describe(_ error: Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return error.localizedDescription + (underlying.map { "（\($0.localizedDescription)）" } ?? "")
    }

    static func log(_ action: String, _ old: String, _ new: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(action)\t\(old)\t\(new)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}
