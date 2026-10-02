import Foundation

enum CoverState: Equatable {
    case ok, missing
    case unreadable([URL])
}

struct Album: Identifiable {
    let dir: URL
    var id: URL { dir }
    let tracks: [URL]
    let cover: CoverState
    let title: String
    let artist: String
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
    static let tagKeys = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST"]
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

    /// Albums MinimServer would show without artwork. Renames `cover.jpeg` / `folder.jpeg` on the way.
    static func scanCovers(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Album] {
        var albums: [Album] = []
        for (i, d) in audioDirs(root).dirs.enumerated() {
            progress(i)
            let images = d.files.filter { imageExts.contains($0.pathExtension.lowercased()) }.map(fixJpeg)
            let cover = coverState(images: images, firstTrack: d.tracks[0])
            guard cover != .ok else { continue }
            let tags = Tags.read(d.tracks[0])
            albums.append(Album(
                dir: d.dir, tracks: d.tracks, cover: cover,
                title: tags["ALBUM"]?.first ?? d.dir.lastPathComponent,
                artist: (tags["ALBUMARTIST"] ?? tags["ARTIST"])?.first ?? ""))
        }
        return albums
    }

    static func scanChinese(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
        let (dirs, rootDepth) = audioDirs(root)
        let relative = { (u: URL) in u.pathComponents.dropFirst(rootDepth).joined(separator: "/") }
        var changes: [Change] = [], folderChanges: [Change] = []
        var seenFolders = Set<String>()
        var dirGroup: [String: String] = [:]
        for (i, d) in dirs.enumerated() {
            progress(i)
            let tags = d.tracks.map(Tags.read)
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

    static func saveCover(_ data: Data, in dir: URL) throws {
        let target = dir.appendingPathComponent("cover." + imageExt(data))
        try data.write(to: target, options: .atomic)
        log("cover", "", target.path)
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
