import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An image the album shows now: a MinimServer cover file or the first track's embedded art.
public struct CurrentCover: Sendable {
    public let name: String
    public let data: Data
}

/// The cover pane of the selected album: what it has now, search results, and the ways to set a cover.
@Observable
public final class CoverPickerController: @unchecked Sendable {
    public let id: URL
    @ObservationIgnored private unowned let app: AppController

    public var query = ""
    public private(set) var results: [CoverCandidate] = []
    public private(set) var searching = false
    public private(set) var current: [CurrentCover] = []
    /// `folder.*` / `cover.*` files, which in a folder of singles would show on every one of them.
    public private(set) var folderCovers: [URL] = []
    /// Images in the parent folder, often the cover of a CD1/CD2 set.
    public private(set) var parentImages: [URL] = []
    public var toFile = UserDefaults.standard.object(forKey: "coverToFile") as? Bool ?? true {
        didSet { UserDefaults.standard.set(toFile, forKey: "coverToFile") }
    }
    public var toEmbed = UserDefaults.standard.bool(forKey: "coverToEmbed") {
        didSet { UserDefaults.standard.set(toEmbed, forKey: "coverToEmbed") }
    }
    @ObservationIgnored private var searchRun = 0
    @ObservationIgnored private var loadedRevision = -1

    init(id: URL, app: AppController) {
        self.id = id
        self.app = app
        initial = app.albums.first { $0.id == id }!
        let album = initial
        var parts: [String] = []
        for p in [album.searchName, album.artist] where !p.isEmpty {
            if !parts.contains(where: { $0.localizedCaseInsensitiveContains(p) }) { parts.append(p) }
        }
        query = parts.joined(separator: " ")
        search()
        let parent = album.dir.deletingLastPathComponent()
        DispatchQueue.global().async { [ui = app.ui] in
            let images = Library.contents(of: parent)
                .filter { Library.imageExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            ui { self.parentImages = images }
        }
        reload()
    }

    /// The album as the app has it now (its cover state changes after a fix).
    public var album: Album { app.albums.first { $0.id == id } ?? initial }
    @ObservationIgnored private let initial: Album

    public var unreadable: [URL] {
        if !album.split, case .unreadable(let imgs) = album.cover { return imgs }
        return []
    }

    /// Re-reads the current covers; the app calls it whenever cover files may have changed.
    func reload() {
        guard loadedRevision != app.coverRevision else { return }
        loadedRevision = app.coverRevision
        let a = album, revision = loadedRevision
        DispatchQueue.global().async { [ui = app.ui] in
            let files = Library.contents(of: a.dir)
                .filter(Library.isMinimCover).sorted { $0.path < $1.path }
            var out = files.compactMap { u in (try? Data(contentsOf: u)).map { CurrentCover(name: u.lastPathComponent, data: $0) } }
            if let d = Tags.embeddedArt(a.tracks[0]) { out.append(CurrentCover(name: "內嵌", data: d)) }
            let current = out
            ui {
                guard revision == self.loadedRevision else { return }
                (self.folderCovers, self.current) = (files, current)
            }
        }
    }

    public func search() {
        searchRun += 1
        let run = searchRun, q = query
        searching = true
        Task.detached { [ui = app.ui] in
            async let slow = CoverSearch.musicBrainz(q)
            let found = await CoverSearch.search(q)
            ui { if run == self.searchRun { self.results = found } }
            let more = await slow
            ui {
                guard run == self.searchRun else { return }
                self.results += more.filter { c in !self.results.contains { $0.full == c.full } }
                self.searching = false
            }
        }
    }

    /// Saves a cover from a search result, a pasted URL, or a picked or dropped file.
    public func save(from url: URL) {
        let album = album, file = toFile, embed = toEmbed
        app.fixCover(id) {
            let data = url.isFileURL ? try Data(contentsOf: url) : try await URLSession.shared.data(from: url).0
            try Library.saveCover(data, for: album, file: file, embed: embed)
        }
    }

    /// Saves from the URL field's text; ignored when it isn't a URL.
    public func save(fromText text: String) {
        if let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme != nil { save(from: u) }
    }

    public func deleteFolderCovers() {
        let files = folderCovers
        app.fixCover(id, covered: false) {
            for u in files { try FileManager.default.removeItem(at: u); Library.log("delete", u.path, "") }
        }
    }

    /// Renames an image MinimServer can't see to `cover.*`.
    public func promote(_ image: URL) {
        app.fixCover(id) { try Library.promote(image) }
    }

    /// Copies an image from the parent folder as this album's cover.
    public func copyParent(_ image: URL) {
        save(from: image)
    }
}
