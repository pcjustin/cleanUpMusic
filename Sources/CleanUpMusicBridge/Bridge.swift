import CleanUpMusicCore
import Foundation
import Observation

// The C ABI the WinUI app (windows/CleanUpMusic) calls. The app owns the UI thread: Swift asks it to run closures
// there through `post`, and it hands them back with `cum_run`. Each section of the window is a JSON document; when
// one changes, `changed` names it and the app fetches it with `cum_get`. Commands come in as JSON through `cum_send`.

public typealias PostFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
public typealias ChangedFn = @convention(c) (UnsafePointer<CChar>?) -> Void

private final class Job {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

nonisolated(unsafe) private var post: PostFn?
nonisolated(unsafe) private var changed: ChangedFn?
nonisolated(unsafe) private var app: AppController!
/// Last JSON of each section, so the app only hears about sections whose content changed.
nonisolated(unsafe) private var documents: [Section: String] = [:]

@_cdecl("cum_start")
public func cumStart(_ p: PostFn, _ c: ChangedFn, _ dataDir: UnsafePointer<CChar>) {
    post = p
    changed = c
    Chinese.dataDir = URL(fileURLWithPath: String(cString: dataDir))
    app = AppController { f in post?(Unmanaged.passRetained(Job(f)).toOpaque()) }
    for s in Section.allCases { track(s) }
}

@_cdecl("cum_run")
public func cumRun(_ job: UnsafeMutableRawPointer) {
    Unmanaged<Job>.fromOpaque(job).takeRetainedValue().run()
}

/// The section's JSON; the caller frees it with `cum_free`.
@_cdecl("cum_get")
public func cumGet(_ section: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    Section(rawValue: String(cString: section)).flatMap { documents[$0] }.flatMap { _strdup($0) }
}

@_cdecl("cum_free")
public func cumFree(_ p: UnsafeMutablePointer<CChar>?) {
    free(p)
}

@_cdecl("cum_send")
public func cumSend(_ json: UnsafePointer<CChar>) {
    guard let c = try? JSONDecoder().decode(Command.self, from: Data(String(cString: json).utf8)) else { return }
    c.perform()
}

/// Recomputes a section whenever anything it reads changes, and tells the app when its JSON differs.
private func track(_ s: Section) {
    let json = withObservationTracking { s.json() } onChange: { app.ui { track(s) } }
    guard documents[s] != json else { return }
    documents[s] = json
    s.rawValue.withCString { changed?($0) }
}

private enum Section: String, CaseIterable {
    case status, covers, picker, pickerCurrent, chinese, chineseSelection, splits, discs, discsSelection

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data?
        switch self {
        case .status: data = try? encoder.encode(Status())
        case .covers: data = try? encoder.encode(Covers())
        case .picker: data = try? encoder.encode(app.picker.map(Picker.init))
        case .pickerCurrent: data = try? encoder.encode(app.picker.map(PickerCurrent.init))
        case .chinese: data = try? encoder.encode(Groups(groups: app.chineseGroups, filter: app.chineseFilter))
        case .chineseSelection: data = try? encoder.encode(Selection(ids: app.selectedChanges, count: app.selectedChanges.count))
        case .splits: data = try? encoder.encode(app.splits.map(Split.init))
        case .discs: data = try? encoder.encode(Groups(groups: app.discGroups, filter: ""))
        case .discsSelection: data = try? encoder.encode(Selection(ids: app.selectedDiscs, count: app.selectedDiscAlbums))
        }
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

// MARK: Documents

private struct Status: Encodable {
    var root = app.root?.path
    var scanning = app.scanning
    var progress = app.progress
    var message = app.message
    var albums = app.albums.count
    var changes = app.changes.count
    var splits = app.splits.count
    var discs = app.discs.count
}

private struct Covers: Encodable {
    struct Item: Encodable {
        let id: String, title: String, artist: String, path: String, state: String, unreadable: Int
    }
    var onlyMissing = app.onlyMissing
    var filter = app.coverFilter
    var selection = app.coverSelection?.path
    var items = app.shownAlbums.map { a in
        var state = "missing", unreadable = 0
        switch a.cover {
        case .ok: state = "ok"
        case .missing: break
        case .unreadable(let imgs): (state, unreadable) = ("unreadable", imgs.count)
        }
        return Item(id: a.id.path, title: a.title, artist: a.artist, path: a.dir.path, state: state, unreadable: unreadable)
    }
}

private struct Picker: Encodable {
    struct Result: Encodable { let full: String, thumb: String, title: String, source: String }
    let id: String, split: Bool, query: String, searching: Bool, toFile: Bool, toEmbed: Bool
    let folderCovers: [String], unreadable: [String], parentImages: [String], results: [Result]

    init(_ p: CoverPickerController) {
        (id, split, query, searching, toFile, toEmbed) = (p.id.path, p.album.split, p.query, p.searching, p.toFile, p.toEmbed)
        folderCovers = p.folderCovers.map(\.lastPathComponent)
        unreadable = p.unreadable.map(\.path)
        parentImages = p.parentImages.map(\.path)
        results = p.results.map { Result(full: $0.full.absoluteString, thumb: $0.thumb.absoluteString, title: $0.title, source: $0.source) }
    }
}

/// Kept apart from `Picker` so typing a search doesn't resend the images.
private struct PickerCurrent: Encodable {
    struct Image: Encodable { let name: String, data: Data }
    let id: String, images: [Image]

    init(_ p: CoverPickerController) {
        id = p.id.path
        images = p.current.map { Image(name: $0.name, data: $0.data) }
    }
}

private struct Groups: Encodable {
    struct Item: Encodable { let id: String, label: String, old: String, new: String, path: String, folder: String, file: String }
    struct Group: Encodable { let name: String, summary: String, tracks: Int, changes: [Item] }
    let groups: [Group], filter: String

    init(groups: [ChangeGroup], filter: String) {
        self.filter = filter
        self.groups = groups.map { g in
            Group(name: g.name, summary: AppController.summary(g.changes), tracks: AppController.trackCount(g.changes), changes: g.changes.map { c in
                Item(id: c.id.uuidString, label: c.kind.label, old: c.old, new: c.new, path: c.url.path,
                     folder: c.url.deletingLastPathComponent().lastPathComponent, file: c.url.lastPathComponent)
            })
        }
    }
}

private struct Selection: Encodable {
    let ids: [String], count: Int
    init(ids: Set<UUID>, count: Int) { (self.ids, self.count) = (ids.map(\.uuidString).sorted(), count) }
}

private struct Split: Encodable {
    struct Variant: Encodable { let album: String, tracks: [String] }
    let name: String, path: String, similar: Bool, variants: [Variant]

    init(_ s: AlbumSplit) {
        (name, path, similar) = (s.dir.lastPathComponent, s.dir.path, s.similar)
        variants = s.variants.map { Variant(album: $0.album, tracks: $0.tracks.map(\.lastPathComponent)) }
    }
}

// MARK: Commands

private struct Command: Decodable {
    let op: String
    var value: Bool?
    var text: String?
    var path: String?
    var ids: [String]?

    func perform() {
        let url = path.map { URL(fileURLWithPath: $0) }
        let ids = Set((ids ?? []).compactMap(UUID.init(uuidString:)))
        let p = app.picker
        switch op {
        case "choose": if let url { app.choose(url) }
        case "scanCovers": app.scanCovers()
        case "scanChinese": app.scanChinese()
        case "scanSplits": app.scanSplits()
        case "scanDiscs": app.scanDiscs()
        case "applyChanges": app.applyChanges()
        case "applyDiscs": app.applyDiscs()
        case "dismissMessage": app.message = nil
        case "setOnlyMissing": app.onlyMissing = value ?? true
        case "setCoverFilter": app.coverFilter = text ?? ""
        case "selectAlbum": app.coverSelection = app.albums.first { $0.id.path == path }?.id
        case "setChineseFilter": app.chineseFilter = text ?? ""
        case "selectChanges": app.setSelected(app.changes.filter { ids.contains($0.id) }, value ?? false)
        case "selectShownChanges": app.setSelected(app.chineseGroups.flatMap(\.changes), value ?? false)
        case "selectDiscs": app.setDiscsSelected(app.discs.filter { ids.contains($0.id) }, value ?? false)
        case "selectAllDiscs": app.setDiscsSelected(app.discs, value ?? false)
        case "setQuery": p?.query = text ?? ""
        case "search": p?.search()
        case "setToFile": p?.toFile = value ?? true
        case "setToEmbed": p?.toEmbed = value ?? false
        case "saveURL": p?.save(fromText: text ?? "")
        case "saveFile": if let url { p?.save(from: url) }
        case "deleteFolderCovers": p?.deleteFolderCovers()
        case "promote": if let url { p?.promote(url) }
        case "copyParent": if let url { p?.copyParent(url) }
        default: break
        }
    }
}
