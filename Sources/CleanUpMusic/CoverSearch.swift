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
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
