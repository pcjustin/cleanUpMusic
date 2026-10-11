import Foundation
#if os(Windows)
import WinSDK
#endif

public enum CoverState: Equatable, Sendable {
    case ok, missing
    case unreadable([URL])
}

public struct Album: Identifiable, Sendable {
    public let dir: URL
    /// True when the folder holds tracks of several ALBUMs (e.g. singles); a folder-level cover file would show on
    /// all of them, so covers can only be embedded.
    public var split = false
    public var id: URL { split ? tracks[0] : dir }
    public let tracks: [URL]
    public var cover: CoverState
    public let title: String
    public let artist: String
    /// ALBUM without disc markers, or the first track's TITLE when that leaves nothing.
    public var searchName = ""

    public init(dir: URL, split: Bool = false, tracks: [URL], cover: CoverState, title: String, artist: String, searchName: String = "") {
        (self.dir, self.split, self.tracks, self.cover, self.title, self.artist, self.searchName) = (dir, split, tracks, cover, title, artist, searchName)
    }
}

public struct AlbumSplit: Identifiable, Sendable {
    public struct Variant: Sendable {
        public let album: String
        public let tracks: [URL]
    }
    public let dir: URL
    public let variants: [Variant]
    /// Values differ only by case, spacing, width or Simplified/Traditional: almost certainly one album.
    public let similar: Bool
    public var id: URL { dir }
}

public enum ChangeKind: Hashable, Sendable {
    case tag(String), file, folder

    public var label: String {
        switch self {
        case .tag(let k): k
        case .file: "檔名"
        case .folder: "資料夾"
        }
    }
}

public struct Change: Identifiable, Sendable {
    public let id = Foundation.UUID() // WinSDK has a UUID too
    public let kind: ChangeKind
    public let url: URL
    public let old: String
    public let new: String
    /// Values a tag change writes; `new` is their display form.
    public let values: [String]
    public var group = ""
    /// Extra detail for the list, e.g. the code page a garbled name is repaired from.
    public var note = ""
}

public enum Library {
    static let tagKeys = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DISCNUMBER", "DISCTOTAL"]
    static let audioExts: Set = ["flac", "mp3", "m4a", "wav", "aif", "aiff", "ape"]
    public static let imageExts: Set = ["jpg", "jpeg", "png", "webp"]
    static let coverNames: Set = ["folder", "cover"]
    /// Tests point this at a temp file.
    #if os(Windows)
    public static var logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory())
        .appendingPathComponent("CleanUpMusic/changes.log")
    #else
    public static var logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CleanUpMusic/changes.log")
    #endif

    private struct AudioDir {
        let dir: URL
        let tracks: [URL]
        let files: [URL]
    }

    /// Folders that directly contain audio, plus the root depth.
    private static func audioDirs(_ root: URL) -> (dirs: [AudioDir], rootDepth: Int) {
        let (folders, rootDepth) = listTree(root)
        let dirs = folders.compactMap { f in
            let tracks = f.files.filter { audioExts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            return tracks.isEmpty ? nil : AudioDir(dir: f.dir, tracks: tracks, files: f.files)
        }
        return (dirs, rootDepth)
    }

    /// Every folder under the root (the root included) with its files, plus the root depth; paths are
    /// symlink-resolved. Folders are listed 32 at a time, each queued as soon as its parent is listed (a cold NAS
    /// walk takes ~27% less; the NAS answers listings mostly one by one), prefetching the size and modification date
    /// `Tags.readAll` checks against its cache. Serial queues, unlike GCD's shared pool, always get a thread, even
    /// when the caller blocks a Swift task.
    private static func listTree(_ root: URL) -> (folders: [(dir: URL, files: [URL])], rootDepth: Int) {
        #if os(Windows)
        let realRoot = root // resolvingSymlinksInPath turns \\server\share into \server\share
        #else
        let realRoot = URL(fileURLWithPath: realpath(root.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root.path)
        #endif
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let queues = (0..<32).map { _ in DispatchQueue(label: "nas") }
        let turn = Locked(0), found = Locked<[(dir: URL, files: [URL])]>([]), listed = DispatchGroup()
        func list(_ dir: URL) {
            var files: [URL] = []
            for (u, isDirectory) in entries(of: dir, prefetching: keys) {
                if isDirectory {
                    queues[turn { $0 += 1; return $0 % 32 }].async(group: listed) { list(u) }
                } else {
                    files.append(u)
                }
            }
            found { $0.append((URL(fileURLWithPath: dir.path, isDirectory: true), files)) }
        }
        queues[0].async(group: listed) { list(realRoot) }
        listed.wait()
        return (found { $0 }.sorted { $0.dir.path < $1.dir.path }, realRoot.pathComponents.count)
    }

    /// Reads every track of every folder in one concurrent batch; small per-folder batches gain nothing on a NAS.
    private static func readTags(_ dirs: [AudioDir], progress: (Int) -> Void) -> [[[String: [String]]]] {
        let all = Tags.readAll(dirs.flatMap(\.tracks), progress: progress)
        var start = 0
        return dirs.map { d in defer { start += d.tracks.count }; return Array(all[start..<start + d.tracks.count]) }
    }

    /// A folder's track indices grouped by ALBUM tag, in track order; more than one group is a split folder.
    private static func albumGroups(_ tags: [[String: [String]]]) -> [(album: String, indices: [Int])] {
        Dictionary(grouping: tags.indices) { tags[$0]["ALBUM"]?.first ?? "" }
            .map { (album: $0.key, indices: $0.value) }
            .sorted { $0.indices[0] < $1.indices[0] }
    }

    /// All albums with their cover state. Renames `cover.jpeg` / `folder.jpeg` on the way.
    public static func scanCovers(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Album] {
        var albums: [Album] = []
        let dirs = audioDirs(root).dirs
        for (d, tags) in zip(dirs, readTags(dirs, progress: progress)) {
            let images = d.files.filter { imageExts.contains($0.pathExtension.lowercased()) }.map(fixJpeg)
            // ponytail: reads every track's tags to detect singles; sample a few tracks if NAS scans get slow.
            // Tracks without ALBUM are loose songs, each its own album when the folder holds more than one.
            let groups = albumGroups(tags).flatMap { g in g.album.isEmpty ? g.indices.map { (album: "", indices: [$0]) } : [g] }
            let split = groups.count > 1
            for g in groups {
                let t = tags[g.indices[0]]
                let base = albumBase(t["ALBUM"]?.first ?? "")
                albums.append(Album(
                    dir: d.dir, split: split, tracks: g.indices.map { d.tracks[$0] },
                    // A folder image would show on every album of a split folder, so only embedded art counts there.
                    cover: coverState(images: split ? [] : images, embeddedArt: t["PICTURE"] != nil),
                    title: t["ALBUM"]?.first ?? (split ? t["TITLE"]?.first : nil) ?? d.dir.lastPathComponent,
                    artist: (t["ALBUMARTIST"] ?? t["ARTIST"])?.first ?? "",
                    searchName: base.isEmpty ? t["TITLE"]?.first ?? "" : base))
            }
        }
        return albums
    }

    /// Folders whose tracks carry different ALBUM tags, which MinimServer shows as separate albums.
    public static func scanSplits(_ root: URL, progress: (Int) -> Void = { _ in }) -> [AlbumSplit] {
        var splits: [AlbumSplit] = []
        let dirs = audioDirs(root).dirs
        for (d, tags) in zip(dirs, readTags(dirs, progress: progress)) {
            let groups = albumGroups(tags)
            guard groups.count > 1 else { continue }
            let variants = groups.map { AlbumSplit.Variant(album: $0.album, tracks: $0.indices.map { d.tracks[$0] }) }
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

    static func discNumber(_ folder: String) -> Int? {
        guard let m = discPattern.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) else { return nil }
        return (1...2).lazy.compactMap { Range(m.range(at: $0), in: folder).flatMap { Int(folder[$0]) } }.first
    }

    /// Strips every trailing disc marker, so "Album [Disc 1] [Disc 2]" and a bare "[Disc 1]" reduce to "Album" and "".
    static func albumBase(_ album: String) -> String {
        var s = album.trimmingCharacters(in: .whitespaces)
        while case let n = discSuffix.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            .trimmingCharacters(in: .whitespaces), n != s { s = n }
        return s
    }

    /// Proposes DISCNUMBER, DISCTOTAL and ALBUM `X [Disc n]` (MinimServer's disc-heading form) for tracks under
    /// sibling folders named like CD1 / Disc 2 / 碟3 (tracks may sit in a subfolder such as CD1/FLAC).
    /// All discs of a set share the ALBUM base found on the most discs (the parent folder name when no base is on two
    /// discs, e.g. a box set of different albums) and the most common ALBUMARTIST, since MinimServer splits albums on either.
    /// A lone disc folder is skipped: there is nothing to merge it with.
    public static func scanDiscs(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
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
        let discSets = sets.filter { Set($0.value.map(\.n)).count > 1 }.sorted { $0.key.path < $1.key.path }
        let urls = discSets.flatMap { $0.value.flatMap(\.tracks) }
        let tagsOf = Dictionary(uniqueKeysWithValues: zip(urls, Tags.readAll(urls, progress: progress)))
        var changes: [Change] = []
        for (parent, items) in discSets {
            let total = String(Set(items.map(\.n)).count)
            let group = relativePath(parent, rootDepth)
            let tracks = items.flatMap { item in item.tracks.map { (url: $0, n: item.n, tags: tagsOf[$0]!) } }
            let discBases = Dictionary(grouping: tracks, by: \.n).values.flatMap { disc in
                Set(disc.compactMap { $0.tags["ALBUM"]?.first.map(albumBase) }.filter { !$0.isEmpty })
            }
            let base = Dictionary(grouping: discBases, by: { $0 }).filter { $0.value.count > 1 }
                .max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? parent.lastPathComponent
            let artist = mostCommon(tracks.compactMap { $0.tags["ALBUMARTIST"]?.first })
            for (t, n, tags) in tracks {
                func propose(_ key: String, _ new: String) {
                    let old = (tags[key] ?? []).joined(separator: "; ")
                    if old != new { changes.append(Change(kind: .tag(key), url: t, old: old, new: new, values: [new], group: group)) }
                }
                if Int((tags["DISCNUMBER"]?.first ?? "").prefix(while: \.isNumber)) != n { propose("DISCNUMBER", String(n)) }
                propose("DISCTOTAL", total)
                if tags["ALBUM"] != nil { propose("ALBUM", base + " [Disc \(n)]") }
                if let artist { propose("ALBUMARTIST", artist) }
            }
        }
        return changes
    }

    private static func mostCommon(_ values: [String]) -> String? {
        Dictionary(grouping: values, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
    }

    public static func scanChinese(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
        let (dirs, rootDepth) = audioDirs(root)
        let allTags = readTags(dirs, progress: progress)
        var changes: [Change] = [], folderChanges: [Change] = []
        var seenFolders = Set<String>()
        var dirGroup: [String: String] = [:]
        // ponytail: an album of kanji-only names (no kana in any tag, file or folder) still reads as Simplified.
        var japanese = Set<String>()
        for (d, tags) in zip(dirs, allTags) {
            let group = albumGroup(tags[0]) ?? relativePath(d.dir, rootDepth)
            dirGroup[d.dir.path] = group
            let texts = [relativePath(d.dir, rootDepth)] + d.tracks.map(\.lastPathComponent) + tags.flatMap { $0.values.joined() }
            // A lone の is borrowed by Chinese titles for 的.
            if texts.contains(where: { Chinese.hasKana($0.replacingOccurrences(of: "の", with: "")) }) { japanese.insert(group) }

            for (t, tag) in zip(d.tracks, tags) {
                for key in tagKeys {
                    guard let values = tag[key] else { continue }
                    let old = values.joined(separator: "; ")
                    if let new = Chinese.convert(old) {
                        changes.append(Change(kind: .tag(key), url: t, old: old, new: new, values: values.map(Chinese.toTraditional), group: group))
                    }
                }
                if let new = Chinese.convert(t.deletingPathExtension().lastPathComponent) {
                    changes.append(Change(kind: .file, url: t, old: t.lastPathComponent, new: new + "." + t.pathExtension, values: [], group: group))
                }
            }

            var f = d.dir
            while f.pathComponents.count > rootDepth, seenFolders.insert(f.path).inserted {
                if let new = Chinese.convert(f.lastPathComponent) {
                    folderChanges.append(Change(kind: .folder, url: f, old: f.lastPathComponent, new: new, values: []))
                }
                f = f.deletingLastPathComponent()
            }
        }
        // ponytail: O(folders × album dirs) prefix scan, fine for a few thousand albums; use a trie if it gets slow.
        for i in folderChanges.indices {
            let p = folderChanges[i].url.path
            let groups = Set(dirGroup.filter { $0.key == p || $0.key.hasPrefix(p + "/") }.values)
            folderChanges[i].group = groups.count == 1 ? groups.first! : "資料夾：" + relativePath(folderChanges[i].url, rootDepth)
            if groups.isSubset(of: japanese) { japanese.insert(folderChanges[i].group) }
        }
        return (changes + folderChanges).filter { !japanese.contains($0.group) }
    }

    /// File and folder names garbled by being read in the wrong code page (see `Mojibake`), with their repaired
    /// names. A track's TITLE settles which reading is meant when a name could be read more than one way.
    public static func scanMojibake(_ root: URL, progress: (Int) -> Void = { _ in }) -> [Change] {
        let (folders, rootDepth) = listTree(root)
        let suspects = folders.flatMap(\.files).filter { Mojibake.mightBeGarbled($0.lastPathComponent) }
        let tracks = suspects.filter { audioExts.contains($0.pathExtension.lowercased()) }
        let titles = Dictionary(uniqueKeysWithValues: zip(tracks, Tags.readAll(tracks, progress: progress).map { $0["TITLE"]?.first }))
        var changes: [Change] = []
        for f in suspects {
            // A TITLE can be garbled the same way ("¤T¤é¤ë" for 三日月): repaired, it still helps; past repair, it can't.
            let name = f.lastPathComponent, tag = titles[f] ?? nil
            let title = tag.flatMap { Mojibake.repair($0)?.name ?? (Mojibake.mightBeGarbled($0) ? nil : $0) }
            let fixed: (name: String, note: String)
            if let r = Mojibake.repair(name, hint: title) {
                fixed = (r.name, r.encoding)
            } else if Mojibake.isLossy(name), let title, !title.isEmpty {
                fixed = (Mojibake.fromTitle(name, title: title), "依 TITLE 標籤")
            } else {
                continue
            }
            guard fixed.name != name else { continue }
            changes.append(Change(kind: .file, url: f, old: name, new: fixed.name, values: [],
                                  group: relativePath(f.deletingLastPathComponent(), rootDepth), note: fixed.note))
        }
        for d in folders.map(\.dir) where d.pathComponents.count > rootDepth {
            guard let r = Mojibake.repair(d.lastPathComponent) else { continue }
            changes.append(Change(kind: .folder, url: d, old: d.lastPathComponent, new: r.name, values: [],
                                  group: relativePath(d, rootDepth), note: r.encoding))
        }
        return changes
    }

    /// A folder's entries, hidden (dot) ones left out.
    static func contents(of dir: URL) -> [URL] { entries(of: dir).map(\.url) }

    /// A folder's entries and whether each is a folder, hidden (dot) ones left out. On Windows this asks the system
    /// directly: Foundation lists nothing for a folder on a network share (\\server\share) when asked by URL, and
    /// checking each entry for being a folder costs a NAS round trip that a listing already answers.
    static func entries(of dir: URL, prefetching keys: [URLResourceKey]? = nil) -> [(url: URL, isDirectory: Bool)] {
        #if os(Windows)
        let pattern = dir.withUnsafeFileSystemRepresentation { String(cString: $0!) } + "\\*"
        var data = WIN32_FIND_DATAW()
        let find = pattern.withCString(encodedAs: UTF16.self) {
            FindFirstFileExW($0, FindExInfoBasic, &data, FindExSearchNameMatch, nil, DWORD(FIND_FIRST_EX_LARGE_FETCH))
        }
        guard let find, find != INVALID_HANDLE_VALUE else { return [] }
        defer { FindClose(find) }
        var out: [(url: URL, isDirectory: Bool)] = []
        repeat {
            let name = withUnsafeBytes(of: data.cFileName) { raw in
                String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let isDirectory = data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            let url = dir.appendingPathComponent(name, isDirectory: isDirectory)
            out.append((url, isDirectory))
            if !isDirectory {
                // FILETIME counts 100 ns ticks from 1601.
                let ticks = UInt64(data.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(data.ftLastWriteTime.dwLowDateTime)
                let date = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
                let size = Int(UInt64(data.nFileSizeHigh) << 32 | UInt64(data.nFileSizeLow))
                Tags.listed { $0[url.path] = (size, date) }
            }
        } while FindNextFileW(find, &data)
        return out
        #else
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
        #endif
    }

    /// Path below the scanned root; the root's own name for the root itself.
    private static func relativePath(_ u: URL, _ rootDepth: Int) -> String {
        let path = u.pathComponents.dropFirst(rootDepth).joined(separator: "/")
        return path.isEmpty ? u.lastPathComponent : path
    }

    /// Tracks sharing ALBUM + album artist are one album, even across CD1/CD2 folders.
    /// Without an artist, same-named albums can't be told apart, so the caller falls back to the folder.
    static func albumGroup(_ tags: [String: [String]]) -> String? {
        guard let album = tags["ALBUM"]?.first, !album.isEmpty,
              let artist = (tags["ALBUMARTIST"] ?? tags["ARTIST"])?.first, !artist.isEmpty else { return nil }
        return Chinese.toTraditional("\(album) – \(artist)")
    }

    static func coverState(images: [URL], embeddedArt: Bool) -> CoverState {
        if embeddedArt || images.contains(where: isMinimCover) { return .ok }
        return images.isEmpty ? .missing : .unreadable(images.sorted { $0.path < $1.path })
    }

    public static func isMinimCover(_ u: URL) -> Bool {
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
    public static func promote(_ image: URL) throws {
        let ext = image.pathExtension.lowercased() == "jpeg" ? "jpg" : image.pathExtension.lowercased()
        try rename(image, to: image.deletingLastPathComponent().appendingPathComponent("cover." + ext))
    }

    /// Writes `cover.<ext>`, then removes every other `folder.*` / `cover.*` image (MinimServer would pick `folder.*`
    /// first), and/or embeds the image in every track.
    public static func saveCover(_ data: Data, for album: Album, file: Bool, embed: Bool) throws {
        guard (file && !album.split) || embed else { throw failure("請勾選「存成 cover 檔」或「嵌入 metadata」") }
        guard let ext = imageExt(data) else { throw failure("不是 JPEG、PNG 或 WebP 圖片") }
        if file && !album.split {
            let target = album.dir.appendingPathComponent("cover." + ext)
            try data.write(to: target, options: .atomic)
            log("cover", "", target.path)
            for name in coverNames {
                for other in imageExts where "\(name).\(other)" != target.lastPathComponent {
                    let u = album.dir.appendingPathComponent("\(name).\(other)")
                    if (try? FileManager.default.removeItem(at: u)) != nil { log("delete", u.path, "") }
                }
            }
        }
        if embed {
            let mime = "image/" + (ext == "jpg" ? "jpeg" : ext)
            var failed: [String] = []
            for t in album.tracks {
                do {
                    try Tags.embedArt(t, data, mime: mime)
                    log("cover embed", "", t.path)
                } catch {
                    failed.append(t.lastPathComponent)
                }
            }
            if !failed.isEmpty { throw failure("\(failed.count) 個檔案無法嵌入（其餘已完成）：\n" + failed.joined(separator: "\n")) }
        }
    }

    private static func failure(_ message: String) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The cover extension for JPEG, PNG or WebP data; nil for anything else, such as an HTML error page.
    static func imageExt(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: "RIFF".utf8), data.dropFirst(8).starts(with: "WEBP".utf8) { return "webp" }
        return nil
    }

    /// Applies tag writes first, then file renames, then folder renames deepest-first,
    /// so every change's URL is still valid when its turn comes. Returns failure messages.
    /// A tag no longer holding its scanned value is skipped, so a stale list (e.g. CD numbers scanned
    /// before a Simplified→Traditional apply) can't undo a newer edit.
    public static func apply(_ changes: [Change]) -> [String] {
        var failures: [String] = []
        let tagFiles = Dictionary(grouping: changes.filter { if case .tag = $0.kind { true } else { false } }, by: \.url)
        for (url, items) in tagFiles {
            let current = Tags.read(url)
            var fields: [String: [String]] = [:], written: [Change] = []
            for c in items {
                guard case .tag(let key) = c.kind else { continue }
                guard (current[key] ?? []).joined(separator: "; ") == c.old else {
                    failures.append("\(key) 已在掃描後變更或無法讀取，請重新掃描：\(url.path)")
                    continue
                }
                fields[key] = c.values
                written.append(c)
            }
            guard !written.isEmpty else { continue }
            do {
                try Tags.write(url, fields)
                for c in written { log("tag \(c.kind.label)", c.old, c.new, url.path) }
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

    public static func describe(_ error: Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return error.localizedDescription + (underlying.map { "（\($0.localizedDescription)）" } ?? "")
    }

    public static func log(_ fields: String...) {
        let line = ([ISO8601DateFormatter().string(from: Date())] + fields).joined(separator: "\t") + "\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}
