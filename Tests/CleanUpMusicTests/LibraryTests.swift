import Foundation
import Testing
@testable import CleanUpMusic

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func makeAudio(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    p.arguments = ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", url.path]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

private func touch(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF]))
}

@Test func simplifiedToTraditional() {
    #expect(Chinese.toTraditional("头发") == "頭髮")
    #expect(Chinese.convert("發展") == nil)
}

@Test func tagRoundTrip() throws {
    let root = try tempDir()
    for ext in ["flac", "mp3"] {
        let f = root.appendingPathComponent("t.\(ext)")
        try makeAudio(f)
        try Tags.write(f, ["TITLE": ["后来"], "ARTIST": ["刘若英", "陈升"]])
        #expect(Tags.read(f)["TITLE"] == ["后来"])
        #expect(Tags.read(f)["ARTIST"] == ["刘若英", "陈升"])
        #expect(!Tags.hasEmbeddedArt(f))
        try Tags.embedArt(f, Data([0xFF, 0xD8, 0xFF, 0xD9]), mime: "image/jpeg")
        #expect(Tags.hasEmbeddedArt(f))
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

    var all = changes
    for i in all.indices { all[i].selected = true }
    #expect(Library.apply(all).isEmpty)
    let renamed = root.appendingPathComponent("劉若英/後來/後來.flac")
    #expect(Tags.read(renamed)["TITLE"] == ["後來"])
    #expect(Library.scanChinese(root).isEmpty)
}

@Test func imageExtFromMagic() {
    #expect(Library.imageExt(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])) == "png")
    #expect(Library.imageExt(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "webp")
    #expect(Library.imageExt(Data([0xFF, 0xD8, 0xFF])) == "jpg")
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
