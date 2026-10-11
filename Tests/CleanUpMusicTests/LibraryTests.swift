import Foundation
import Testing
@testable import CleanUpMusicCore

/// Keeps test runs out of the real change log; every test touching files calls `tempDir()` first.
private let testLog: Void = {
    Library.logURL = FileManager.default.temporaryDirectory.appendingPathComponent("CleanUpMusicTests.log")
    Tags.cacheURL = nil
}()

private func tempDir() throws -> URL {
    _ = testLog
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// One second of silence: a FLAC with only STREAMINFO, or 38 silent MPEG-1 Layer III frames (128 kbps, 44.1 kHz,
/// mono); enough for TagLib to read and write tags, without needing an encoder.
private func makeAudio(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data: [UInt8]
    if url.pathExtension == "mp3" {
        data = (0..<38).flatMap { _ in [0xFF, 0xFB, 0x90, 0xC0] + [UInt8](repeating: 0, count: 413) }
    } else {
        let info: UInt64 = 44100 << 44 | 15 << 36 | 44100 // sample rate, 16 bits - 1, total samples
        data = Array("fLaC".utf8) + [0x80, 0, 0, 34] + [0x10, 0x00, 0x10, 0x00, 0, 0, 0, 0, 0, 0]
            + (0..<8).reversed().map { UInt8(info >> ($0 * 8) & 0xFF) } + [UInt8](repeating: 0, count: 16)
    }
    try Data(data).write(to: url)
}

private func touch(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF]))
}

@Test func simplifiedToTraditional() {
    #expect(Chinese.toTraditional("头发") == "頭髮")
    #expect(Chinese.convert("發展") == nil)
    #expect(Chinese.toTraditional("恋の歌") != "恋の歌")
    #expect(Chinese.convert("恋の歌") == nil)
    #expect(Chinese.convert("迈克尔・杰克逊") == "邁克爾・傑克遜")
}

@Test func tagRoundTrip() throws {
    let root = try tempDir()
    for ext in ["flac", "mp3"] {
        let f = root.appendingPathComponent("t.\(ext)")
        try makeAudio(f)
        try Tags.write(f, ["TITLE": ["后来"], "ARTIST": ["刘若英", "陈升"]])
        #expect(Tags.read(f)["TITLE"] == ["后来"])
        #expect(Tags.read(f)["ARTIST"] == ["刘若英", "陈升"])
        #expect(Tags.read(f)["PICTURE"] == nil)
        try Tags.embedArt(f, Data([0xFF, 0xD8, 0xFF, 0xD9]), mime: "image/jpeg")
        #expect(Tags.read(f)["PICTURE"] != nil)
        #expect(Tags.embeddedArt(f) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }
}

@Test func coverDetectionAndChanges() throws {
    let root = try tempDir()
    let ok = root.appendingPathComponent("A/有封面")
    let jpeg = root.appendingPathComponent("A/jpeg")
    let front = root.appendingPathComponent("A/front")
    let missing = root.appendingPathComponent("B/缺封面")
    for d in [ok, jpeg, front, missing] { try makeAudio(d.appendingPathComponent("01.flac")) }
    touch(ok.appendingPathComponent("Folder.png"))
    touch(jpeg.appendingPathComponent("cover.jpeg"))
    touch(front.appendingPathComponent("front.jpg"))
    touch(missing.appendingPathComponent("._01.flac"))
    let songDir = root.appendingPathComponent("刘若英/后来")
    let song = songDir.appendingPathComponent("后来.flac")
    try makeAudio(song)
    try Tags.write(song, ["TITLE": ["后来"]])

    let albums = Library.scanCovers(root)
    let changes = Library.scanChinese(root)
    let state = Dictionary(uniqueKeysWithValues: albums.map { ($0.dir.lastPathComponent, $0.cover) })
    #expect(state["有封面"] == .ok)
    #expect(state["jpeg"] == .ok)
    #expect(FileManager.default.fileExists(atPath: jpeg.appendingPathComponent("cover.jpg").path))
    guard case .unreadable(let imgs) = state["front"] else { Issue.record("front not unreadable"); return }
    #expect(imgs.map(\.lastPathComponent) == ["front.jpg"])
    #expect(state["缺封面"] == .missing)
    #expect(albums.first { $0.dir.lastPathComponent == "缺封面" }?.tracks.count == 1)

    #expect(Set(changes.map(\.new)) == ["後來", "後來.flac", "劉若英"])

    #expect(Library.apply(changes).isEmpty)
    let renamed = root.appendingPathComponent("劉若英/後來/後來.flac")
    #expect(Tags.read(renamed)["TITLE"] == ["後來"])
    #expect(Library.scanChinese(root).isEmpty)
}

@Test func imageExtFromMagic() {
    #expect(Library.imageExt(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])) == "png")
    #expect(Library.imageExt(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "webp")
    #expect(Library.imageExt(Data([0xFF, 0xD8, 0xFF])) == "jpg")
    #expect(Library.imageExt(Data("<html>".utf8)) == nil)
}

@Test func groupsMultiDiscAlbumWithItsFolders() throws {
    let root = try tempDir()
    let artist = root.appendingPathComponent("刘若英")
    for disc in ["CD1", "CD2"] {
        let f = artist.appendingPathComponent("后来/\(disc)/01.flac")
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": ["后来"], "ARTIST": [disc == "CD1" ? "刘若英" : "劉若英"]])
    }
    let other = artist.appendingPathComponent("冷门/01.flac")
    try makeAudio(other)
    try Tags.write(other, ["ALBUM": ["冷门"]])

    let changes = Library.scanChinese(root)
    let group = { (old: String) in changes.first { $0.kind == .folder && $0.old == old }?.group }
    #expect(group("后来") == "後來 – 劉若英")
    #expect(group("冷门") == "刘若英/冷门")
    #expect(group("刘若英") == "資料夾：刘若英")
    #expect(Set(changes.filter { $0.kind == .tag("ALBUM") }.map(\.group)) == ["後來 – 劉若英", "刘若英/冷门"])
}

@Test func skipsJapaneseAlbums() throws {
    let root = try tempDir()
    for (album, title) in [("写真", "あなた"), ("初恋", "初恋")] {
        let f = root.appendingPathComponent("中岛美雪/\(album)/\(title).flac")
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": [album], "TITLE": [title], "ARTIST": ["中島みゆき"]])
    }
    let zh = root.appendingPathComponent("后来/后来の歌.flac")
    try makeAudio(zh)
    try Tags.write(zh, ["ALBUM": ["后来"], "TITLE": ["后来の歌"]])

    #expect(Set(Library.scanChinese(root).map(\.old)) == ["后来"])
}

@Test func coverSearchNameFallsBackToTitle() throws {
    let root = try tempDir()
    for (dir, tags) in [("a", ["TITLE": ["Song"]]), ("b", ["ALBUM": ["Album [Disc 1]"], "TITLE": ["Song"]])] {
        let f = root.appendingPathComponent("\(dir)/01.flac")
        try makeAudio(f)
        try Tags.write(f, tags)
    }
    #expect(Library.scanCovers(root).map(\.searchName).sorted() == ["Album", "Song"])
}

@Test func singlesInOneFolderAreSeparateAlbums() throws {
    let root = try tempDir()
    for name in ["a", "b"] {
        let f = root.appendingPathComponent("\(name).flac")
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": [name]])
    }
    let albums = Library.scanCovers(root)
    #expect(albums.count == 2)
    #expect(albums.allSatisfy { $0.split && $0.tracks.count == 1 })
    #expect(Set(albums.map(\.id)).count == 2)
}

@Test func songsWithoutAlbumAreSeparateAlbums() throws {
    let root = try tempDir()
    for name in ["a", "b"] {
        let f = root.appendingPathComponent("\(name).flac")
        try makeAudio(f)
        try Tags.write(f, ["TITLE": [name]])
    }
    touch(root.appendingPathComponent("cover.jpg"))
    let albums = Library.scanCovers(root)
    #expect(albums.allSatisfy { $0.split && $0.tracks.count == 1 && $0.cover == .missing })
    #expect(albums.map(\.title).sorted() == ["a", "b"])
    #expect(albums.map(\.searchName).sorted() == ["a", "b"])
}

@Test func albumSplits() throws {
    let root = try tempDir()
    let near = root.appendingPathComponent("near")
    let far = root.appendingPathComponent("far")
    let same = root.appendingPathComponent("same")
    for (dir, albums) in [(near, ["Love Songs", "Love  Songs "]), (far, ["A", "B"]), (same, ["X", "X"])] {
        for (i, album) in albums.enumerated() {
            let f = dir.appendingPathComponent("\(i).flac")
            try makeAudio(f)
            try Tags.write(f, ["ALBUM": [album]])
        }
    }
    let splits = Library.scanSplits(root)
    #expect(splits.map(\.dir.lastPathComponent) == ["near", "far"])
    #expect(splits.map(\.similar) == [true, false])
}

@Test func discNumbers() throws {
    #expect(["CD1", "Disc 02", "disk3", "碟 4", "Discovery", "ABCD1"].map(Library.discNumber) == [1, 2, 3, 4, nil, nil])
    let root = try tempDir()
    for n in 1...2 {
        let f = root.appendingPathComponent("Album/CD\(n)/t.flac")
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": ["Album (Disc \(n))"]])
    }
    let lone = root.appendingPathComponent("Other/CD1/t.flac")
    try makeAudio(lone)
    let changes = Library.scanDiscs(root)
    #expect(changes.map(\.new) == ["1", "2", "Album [Disc 1]", "2", "2", "Album [Disc 2]"])
    #expect(Library.apply(changes).isEmpty)
    #expect(Library.scanDiscs(root).isEmpty)
    #expect(["Album CD1", "Album - Disc 02", "Album 碟3", "Album", "CD1"].map(Library.albumBase) == ["Album", "Album", "Album", "Album", ""])
}

@Test func discsInSubfoldersShareAlbumBase() throws {
    let root = try tempDir()
    let tracks: [(String, [String: [String]])] = [
        ("Set/CD1/FLAC/a.flac", ["ALBUM": ["Show 1_2"]]),
        ("Set/CD1/stray.flac", ["ALBUM": ["Show 1_2"]]),
        ("Set/CD2/FLAC/b.flac", ["ALBUM": ["Show"], "ALBUMARTIST": ["Zimmer"]]),
        ("Set/CD2/FLAC/c.flac", ["ALBUM": ["Show"], "ALBUMARTIST": ["Zimmer"]]),
        ("Set/CD3/d.flac", ["ALBUM": ["Show"], "ALBUMARTIST": ["齊默"]]),
    ]
    for (path, tags) in tracks {
        let f = root.appendingPathComponent(path)
        try makeAudio(f)
        try Tags.write(f, tags)
    }
    let changes = Library.scanDiscs(root)
    #expect(Set(changes.filter { $0.kind == .tag("ALBUM") }.map(\.new)) == ["Show [Disc 1]", "Show [Disc 2]", "Show [Disc 3]"])
    #expect(changes.filter { $0.kind == .tag("ALBUMARTIST") }.map(\.new) == ["Zimmer", "Zimmer", "Zimmer"])
    #expect(Library.apply(changes).isEmpty)
    #expect(Library.scanDiscs(root).isEmpty)
}

@Test func markerOnlyAlbumConvergesToParentFolderName() throws {
    let root = try tempDir()
    for (path, album) in [("OST/[Disc 1]/a.flac", " [Disc 1]"), ("OST/[Disc 2]/b.flac", " [Disc 1] [Disc 2]")] {
        let f = root.appendingPathComponent(path)
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": [album]])
    }
    #expect(Library.albumBase(" [Disc 1] [Disc 2]") == "")
    let changes = Library.scanDiscs(root)
    #expect(Set(changes.filter { $0.kind == .tag("ALBUM") }.map(\.new)) == ["OST [Disc 1]", "OST [Disc 2]"])
    #expect(Library.apply(changes).isEmpty)
    #expect(Library.scanDiscs(root).isEmpty)
}

@Test func boxSetOfDistinctAlbumsUsesParentFolderName() throws {
    let root = try tempDir()
    for (path, album) in [("Box/Disc 1/a.flac", "Nausicaa"), ("Box/Disc 2/b.flac", "Ponyo"), ("Box/Disc 2/c.flac", "Ponyo")] {
        let f = root.appendingPathComponent(path)
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": [album]])
    }
    let changes = Library.scanDiscs(root)
    #expect(Set(changes.filter { $0.kind == .tag("ALBUM") }.map(\.new)) == ["Box [Disc 1]", "Box [Disc 2]"])
}

@Test func embedContinuesPastUnreadableTrack() throws {
    let root = try tempDir()
    let broken = root.appendingPathComponent("a.flac"), good = root.appendingPathComponent("b.flac")
    FileManager.default.createFile(atPath: broken.path, contents: Data())
    try makeAudio(good)
    let album = Album(dir: root, tracks: [broken, good], cover: .missing, title: "", artist: "")
    #expect(throws: (any Error).self) { try Library.saveCover(Data([0xFF, 0xD8, 0xFF, 0xD9]), for: album, file: false, embed: true) }
    #expect(Tags.read(good)["PICTURE"] != nil)
}

@Test func embeddedArtLookupClosesTheFile() throws {
    let f = try tempDir().appendingPathComponent("t.flac")
    try makeAudio(f)
    let openFiles = { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
    let before = openFiles()
    for _ in 0..<200 { _ = Tags.embeddedArt(f) }
    #expect(openFiles() - before < 100)
}

@Test func saveCoverRejectsNonImagesAndKeepsOldCoverWhenWriteFails() throws {
    let dir = try tempDir()
    let album = Album(dir: dir, tracks: [dir.appendingPathComponent("01.flac")], cover: .ok, title: "", artist: "")
    let old = dir.appendingPathComponent("cover.png")
    touch(old)
    #expect(throws: (any Error).self) { try Library.saveCover(Data("<html>404</html>".utf8), for: album, file: true, embed: false) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cover.jpg").path))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("cover.jpg"), withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try Library.saveCover(Data([0xFF, 0xD8, 0xFF, 0xD9]), for: album, file: true, embed: false) }
    #expect(FileManager.default.fileExists(atPath: old.path))
}

@Test func savedCoverReplacesFolderAndCoverFiles() throws {
    let dir = try tempDir()
    let album = Album(dir: dir, tracks: [dir.appendingPathComponent("01.flac")], cover: .ok, title: "", artist: "")
    for name in ["folder.jpg", "folder.png", "cover.webp", "front.jpg"] { touch(dir.appendingPathComponent(name)) }
    try Library.saveCover(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), for: album, file: true, embed: false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["cover.png", "front.jpg"])
}

@Test func rootLevelTracksAreGroupedUnderTheRootName() throws {
    let root = try tempDir()
    let f = root.appendingPathComponent("后来.flac")
    try makeAudio(f)
    try Tags.write(f, ["TITLE": ["后来"]])
    let changes = Library.scanChinese(root)
    #expect(!changes.isEmpty)
    #expect(changes.allSatisfy { $0.group == root.lastPathComponent })
}

@Test func multiValuedTagsConvertPerValue() throws {
    let f = try tempDir().appendingPathComponent("t.flac")
    try makeAudio(f)
    try Tags.write(f, ["ARTIST": ["刘若英", "陈升"]])
    #expect(Library.apply(Library.scanChinese(f.deletingLastPathComponent())).isEmpty)
    #expect(Tags.read(f)["ARTIST"] == ["刘若英", "陈升"].map(Chinese.toTraditional))
}

@Test func staleTagChangesAreSkipped() throws {
    let root = try tempDir()
    let tracks = (1...2).map { root.appendingPathComponent("后来/CD\($0)/t.flac") }
    for f in tracks {
        try makeAudio(f)
        try Tags.write(f, ["ALBUM": ["后来"]])
    }
    let discs = Library.scanDiscs(root)
    #expect(Library.apply(Library.scanChinese(root).filter { $0.kind == .tag("ALBUM") }).isEmpty)
    #expect(Library.apply(discs).count == 2)
    #expect(Tags.read(tracks[0])["ALBUM"] == ["後來"])
    #expect(Tags.read(tracks[0])["DISCNUMBER"] == ["1"])
}

private func flac(_ blocks: [(type: UInt8, data: [UInt8])]) -> Data {
    var out = Data("fLaC".utf8)
    for (i, b) in blocks.enumerated() {
        let n = b.data.count
        out += [b.type | (i == blocks.count - 1 ? 0x80 : 0), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + b.data
    }
    return out
}

private func vorbisComment(_ entries: [[UInt8]]) -> [UInt8] {
    func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> ($0 * 8) & 0xFF) } }
    return le32(0) + le32(entries.count) + entries.flatMap { le32($0.count) + $0 }
}

@Test func flacFastPathMatchesTagLib() throws {
    let dir = try tempDir()
    func be32(_ n: Int) -> [UInt8] { (0..<4).reversed().map { UInt8(n >> ($0 * 8) & 0xFF) } }
    let art = [UInt8](repeating: 0xAB, count: 100_000)
    let picture = be32(3) + be32(10) + Array("image/jpeg".utf8) + [be32(0), be32(0), be32(0), be32(0), be32(0), be32(art.count)].flatMap { $0 } + art
    let streamInfo = [UInt8](repeating: 0, count: 34)
    let comment = vorbisComment([
        Array("title=后来".utf8), Array("ARTIST=A".utf8), Array("ARTIST=B".utf8), Array("ALBUM=".utf8),
        Array("ALBUMARTIST=X".utf8) + [0] + Array("junk".utf8), Array("DISCNUMBER=".utf8) + [0xC3, 0x28],
    ])
    let f = dir.appendingPathComponent("t.flac")
    try flac([(0, streamInfo), (6, picture), (4, comment), (1, [UInt8](repeating: 0, count: 8192))]).write(to: f)
    #expect(Tags.readFLAC(f.path) == ["TITLE": ["后来"], "ARTIST": ["A", "B"], "ALBUMARTIST": ["X"], "PICTURE": []])
    #expect(Tags.readFLAC(f.path) == Tags.readTagLib(f))

    let empty = dir.appendingPathComponent("e.flac")
    try flac([(0, streamInfo), (4, vorbisComment([]))]).write(to: empty)
    #expect(Tags.readFLAC(empty.path) == nil)

    // Zero bytes after the cover read as an empty block, which TagLib rejects; the scan must too.
    let broken = dir.appendingPathComponent("b.flac")
    try flac([(0, streamInfo), (4, comment), (6, picture), (0, [])]).write(to: broken)
    #expect(Tags.readFLAC(broken.path) == nil)
    #expect(Tags.read(broken) == Tags.readTagLib(broken))
}

@Test func rescanSeesTagsWrittenEvenIfListingShowsOldDate() throws {
    let f = try tempDir().appendingPathComponent("t.flac")
    try makeAudio(f)
    try Tags.write(f, ["ALBUM": ["A"]])
    let fm = FileManager.default, old = Date(timeIntervalSince1970: 1_700_000_000)
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
    let scan = { Tags.readAll([URL(fileURLWithPath: f.path)])[0]["ALBUM"] }
    #expect(scan() == ["A"])
    let size = try fm.attributesOfItem(atPath: f.path)[.size] as? Int
    try Tags.write(f, ["ALBUM": ["B"]])
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
    #expect(try fm.attributesOfItem(atPath: f.path)[.size] as? Int == size)
    #expect(scan() == ["B"])
}

@Test func repairsNamesReadInTheWrongCodepage() {
    let cases: [(String, String, String)] = [
        ("ƒ}ƒˆƒCƒK.flac", "マヨイガ.flac", "Shift-JIS"),
        ("ºóÀ´µÄÎÒÃÇ.flac", "后来的我们.flac", "GBK"),
        ("«á¨Óªº§Ú\u{AD}Ì.flac", "後來的我們.flac", "Big5"),
        ("┴⌡╚⌠╙ó ║≤└┤.flac", "刘若英 后来.flac", "GBK"),
        ("⌐P¬N¡█ ¡S»SªΦ.flac", "周杰倫 范特西.flac", "Big5"),
        ("CafÃ© å¾Œä¾†.flac", "Café 後來.flac", "UTF-8"),
        ("Æåôçé▌éΣé½ Ä₧æπ.flac", "中島みゆき 時代.flac", "Shift-JIS"),
        // From a real library: Big5 brackets, and Japanese saved on a Korean PC then read as Shift-JIS.
        ("025-SAN-KEN¡uThe Three SAGES¡v.flac", "025-SAN-KEN「The Three SAGES」.flac", "Big5"),
        ("06 - A Thousand Dreams of You (from \u{AD}·¤ë).flac", "06 - A Thousand Dreams of You (from 風月).flac", "Big5"),
        ("02 ｫｵｫｯｫ鬮筬ﾁ.mp3", "02 サクラモチ.mp3", "Korean (CP949)"),
    ]
    for (garbled, name, encoding) in cases {
        #expect(Mojibake.repair(garbled) == Mojibake.Repair(name: name, encoding: encoding), "\(garbled)")
    }
}

@Test func leavesRealNamesAlone() {
    // From a real library: accents, Greek, Cyrillic, symbols and half-width katakana that are meant to be there.
    for name in ["01. Décolleté.flac", "01 - A Song for ××.flac", "01. träumerei.flac", "01 Weiβ ～幻想への誘い～.flac",
                 "01. Колечко.flac", "06 もしも････.flac", "PLASMIC FIRE KOTOKO×ALTIMA", "Raison d'être 交差する宿命.flac",
                 "01-Open α Door.flac", "04 安藤裕子 - 360°サラウンド.flac", "後來.flac", "plain.flac",
                 "[2012.02.22] LOVER“S”MiL", "[2010.04.14] Rock’n’Roll Circus", "Don’t Stop — Live…",
                 "1.04. Pièces de clavessin avec une méthode pour la méchanique des doigts No. 4, Deuxième gigue en rondeau.flac",
                 "01. Gil Shaham, Göran Söllscher - Paganini Sonata Concertata In A Major.flac", "Kevin Penkin - Sëgûr.flac",
                 "04. Allegro Di Molto_ »Alles, Was Odem Hat, Lobe Den Herrn«__.flac", "Lumière - Nuit sur Lumière.flac",
                 "Meirav Ben David-Harel, Yaïr Harel, Nima Ben David, Michèle Claude - Yedid Nefesh",
                 "Carmen (Frasquita, Mercédès, Micaëla).flac"] {
        #expect(Mojibake.repair(name) == nil, "\(name)")
    }
    // Bytes lost on the way (・ where Shift-JIS had no character) leave nothing to read back.
    #expect(Mojibake.repair("03 ｪｪ・・ｪﾇﾘﾇ.mp3") == nil)
    #expect(Mojibake.isLossy("03 ｪｪ・・ｪﾇﾘﾇ.mp3"))
    #expect(Mojibake.fromTitle("03 ｪｪ・・ｪﾇﾘﾇ.mp3", title: "お花畑で週末") == "03 お花畑で週末.mp3")
    #expect(Mojibake.fromTitle("09. ﾒｻｷｬ､ﾎｱｦﾎ・(Yui ver.).flac", title: "一番の宝物 (Yui ver.)") == "09. 一番の宝物 (Yui ver.).flac")
    #expect(Mojibake.fromTitle("1-02 ｱｲ・.flac", title: "A/B: C?") == "1-02 A_B_ C_.flac")
    // A plain-ASCII TITLE is in every reading of the name, so it confirms nothing.
    #expect(Mojibake.repair("01. Göran Söllscher - Sonata Concertata.flac", hint: "Sonata Concertata") == nil)
}

@Test func scansAndRepairsGarbledNames() throws {
    let root = try tempDir()
    let album = root.appendingPathComponent("ºóÀ´") // 后来, GBK read as cp1252
    let track = album.appendingPathComponent("01. ƒ}ƒˆƒCƒK.flac") // マヨイガ, Shift-JIS read as cp1252
    try makeAudio(track)
    try Tags.write(track, ["TITLE": ["マヨイガ"]])
    touch(album.appendingPathComponent("┴⌡╚⌠╙ó.cue")) // 刘若英, GBK read as cp437 (a ZIP without the UTF-8 flag)
    try makeAudio(root.appendingPathComponent("fine/後來.flac"))

    let changes = Library.scanMojibake(root)
    #expect(Set(changes.map(\.new)) == ["后来", "01. マヨイガ.flac", "刘若英.cue"])
    #expect(changes.first { $0.kind == .folder }?.note == "GBK")
    #expect(Library.apply(changes).isEmpty)
    let fixed = root.appendingPathComponent("后来")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixed.path).sorted() == ["01. マヨイガ.flac", "刘若英.cue"])
    #expect(Library.scanMojibake(root).isEmpty)
}

@Test func garbledPastReadingIsRenamedFromItsTitle() throws {
    let root = try tempDir()
    let tracks = [("03 ｪｪ・・ｪﾇﾘﾇ.flac", "お花畑で週末"), ("05. ､T､鬢・.flac", "¤T¤é¤ë"), ("09. ﾒｻｷｬ､ﾎｱｦﾎ・.flac", "ﾒｻｷｬ､ﾎｱｦﾎ・")]
    for (name, title) in tracks {
        let f = root.appendingPathComponent(name)
        try makeAudio(f)
        try Tags.write(f, ["TITLE": [title]])
    }
    // The second TITLE is itself garbled (Big5 read as cp1252) and is repaired first; the third is past repair too.
    #expect(Set(Library.scanMojibake(root).map(\.new)) == ["03 お花畑で週末.flac", "05. 三日月.flac"])
}

@Test func tagCacheSurvivesARestart() throws {
    _ = testLog
    let dir = try tempDir()
    let f = dir.appendingPathComponent("t.flac")
    try makeAudio(f)
    try Tags.write(f, ["ALBUM": ["A"]])
    let file = dir.appendingPathComponent("tags.json")
    Tags.cacheURL = file
    defer { Tags.cacheURL = nil }
    #expect(Tags.readAll([f])[0]["ALBUM"] == ["A"])
    // What a new run loads: the entry, with a date that still matches the file's exactly.
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(saved?[f.path] != nil)
    #expect(try Tags.cachedTagsForTesting(file, f) == ["ALBUM": ["A"]])
}
