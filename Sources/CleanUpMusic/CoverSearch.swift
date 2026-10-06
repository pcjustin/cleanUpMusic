import Foundation

struct CoverCandidate: Identifiable, Hashable {
    let full: URL
    let thumb: URL
    let title: String
    let source: String
    var id: URL { full }
}

enum CoverSearch {
    static func search(_ query: String) async -> [CoverCandidate] {
        // HK matched TW in tests and CN returns nothing; JP finds Japanese albums missing from TW.
        async let tw = itunes(query, country: "tw")
        async let jp = itunes(query, country: "jp")
        async let dz = deezer(query)
        var seen = Set<URL>()
        return await (tw + jp + dz).filter { seen.insert($0.full).inserted }
    }

    private struct ITunes: Decodable {
        struct R: Decodable { let artworkUrl100: String?; let collectionName: String?; let artistName: String? }
        let results: [R]
    }

    private struct Deezer: Decodable {
        struct Artist: Decodable { let name: String }
        struct R: Decodable { let title: String; let cover_medium: String?; let cover_xl: String?; let artist: Artist? }
        let data: [R]
    }

    private struct MusicBrainz: Decodable {
        struct Credit: Decodable { let name: String; let joinphrase: String? }
        struct R: Decodable {
            let id: String, title: String, credits: [Credit]?
            enum CodingKeys: String, CodingKey { case id, title, credits = "artist-credit" }
        }
        let groups: [R]
        enum CodingKeys: String, CodingKey { case groups = "release-groups" }
    }

    private struct CoverArtArchive: Decodable {
        struct Image: Decodable { let front: Bool; let image: String; let thumbnails: [String: String] }
        let images: [Image]
    }

    /// Cover Art Archive answers in seconds, sometimes tens of seconds, so callers show `search` results first.
    static func musicBrainz(_ q: String) async -> [CoverCandidate] {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release-group")!
        c.queryItems = [.init(name: "query", value: q), .init(name: "limit", value: "10"), .init(name: "fmt", value: "json")]
        guard let r: MusicBrainz = await fetch(c.url!) else { return [] }
        let found = await withTaskGroup(of: (Int, CoverCandidate?).self) { g in
            for (i, x) in r.groups.enumerated() {
                g.addTask {
                    guard let a: CoverArtArchive = await fetch(URL(string: "https://coverartarchive.org/release-group/\(x.id)")!),
                          let img = a.images.first(where: \.front) else { return (i, nil) }
                    let https = { (s: String) in URL(string: s.replacingOccurrences(of: "http://", with: "https://")) }
                    guard let thumb = https(img.thumbnails["500"] ?? img.thumbnails["large"] ?? img.image),
                          let full = https(img.thumbnails["1200"] ?? img.image) else { return (i, nil) }
                    let artist = x.credits?.map { $0.name + ($0.joinphrase ?? "") }.joined() ?? ""
                    let source = img.thumbnails["1200"] == nil ? "MusicBrainz 原圖" : "MusicBrainz 1200px"
                    return (i, CoverCandidate(full: full, thumb: thumb, title: "\(x.title) – \(artist)", source: source))
                }
            }
            return await g.reduce(into: []) { $0.append($1) }
        }
        return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }

    private static func itunes(_ q: String, country: String) async -> [CoverCandidate] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: q), .init(name: "entity", value: "album"),
                        .init(name: "country", value: country), .init(name: "limit", value: "20")]
        guard let r: ITunes = await fetch(c.url!) else { return [] }
        return r.results.compactMap { x in
            guard let s = x.artworkUrl100, let thumb = URL(string: s.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
                  let full = URL(string: s.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) else { return nil }
            return CoverCandidate(full: full, thumb: thumb, title: "\(x.collectionName ?? "") – \(x.artistName ?? "")", source: "iTunes 1200px")
        }
    }

    private static func deezer(_ q: String) async -> [CoverCandidate] {
        var c = URLComponents(string: "https://api.deezer.com/search/album")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "limit", value: "20")]
        guard let r: Deezer = await fetch(c.url!) else { return [] }
        return r.data.compactMap { x in
            guard let t = x.cover_medium.flatMap(URL.init), let f = x.cover_xl.flatMap(URL.init) else { return nil }
            return CoverCandidate(full: f, thumb: t, title: "\(x.title) – \(x.artist?.name ?? "")", source: "Deezer 1000px")
        }
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("CleanUpMusic/1.0", forHTTPHeaderField: "User-Agent") // MusicBrainz asks clients to name themselves
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
