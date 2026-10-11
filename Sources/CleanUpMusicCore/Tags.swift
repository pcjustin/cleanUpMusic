import CTagLib
import Foundation

public struct TagError: LocalizedError {
    let url: URL
    public var errorDescription: String? { "無法寫入標籤：\(url.path)" }
}

public enum Tags {
    /// Reads `Library.tagKeys`, plus `"PICTURE": []` when the file has embedded art.
    static func read(_ url: URL) -> [String: [String]] {
        (url.pathExtension.lowercased() == "flac" ? readFLAC(url.path) : nil) ?? readTagLib(url)
    }

    static func readTagLib(_ url: URL) -> [String: [String]] {
        guard let f = openFile(url) else { return [:] }
        defer { taglib_file_free(f) }
        var out: [String: [String]] = [:]
        for key in Library.tagKeys {
            guard let values = taglib_property_get(f, key) else { continue }
            defer { taglib_property_free(values) }
            var list: [String] = []
            var i = 0
            while let v = values[i] { list.append(String(cString: v)); i += 1 }
            if !list.isEmpty { out[key] = list }
        }
        if hasPicture(f) { out["PICTURE"] = [] }
        return out
    }

    /// FLAC tags straight from the metadata blocks: TagLib reads every block whole, cover art and padding included
    /// (hundreds of KB per track over SMB), while this reads 16 KB and seeks past big blocks. Every block header is
    /// still checked; nil leaves the file to TagLib wherever its result could differ: no `fLaC` at the start, a broken
    /// block chain, or no text fields (TagLib then uses an ID3v1 tag).
    static func readFLAC(_ path: String) -> [String: [String]]? {
        #if os(Windows)
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard (try? h.seek(toOffset: UInt64(offset))) != nil, let d = try? h.read(upToCount: count) else { return nil }
            return [UInt8](d)
        }
        let fileSize = { (try? h.seekToEnd()).map(Int.init) ?? -1 }
        #else
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1) // cold NAS reads took ~40% less time than through the page cache
        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: count)
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
            guard n >= 0 else { return nil }
            buf.removeSubrange(n...)
            return buf
        }
        let fileSize = { Int(lseek(fd, 0, SEEK_END)) }
        #endif
        var chunk: [UInt8] = [], chunkStart = 0
        func bytes(_ offset: Int, _ count: Int) -> ArraySlice<UInt8>? {
            if offset < chunkStart || offset + count > chunkStart + chunk.count {
                guard let c = read(offset, max(count, 16 << 10)), c.count >= count else { return nil }
                chunk = c
                chunkStart = offset
            }
            return chunk[(offset - chunkStart)...].prefix(count)
        }
        guard bytes(0, 4) == ArraySlice("fLaC".utf8) else { return nil }
        var offset = 4, comment: ArraySlice<UInt8>?, picture = false, last = false
        while !last {
            guard let h = bytes(offset, 4) else { return nil }
            let type = h[h.startIndex] & 0x7F, length = h.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            last = h[h.startIndex] & 0x80 != 0
            // TagLib's validity rules: STREAMINFO first, only PADDING and SEEKTABLE may be empty.
            guard offset > 4 || type == 0, length > 0 || type == 1 || type == 3 else { return nil }
            if type == 4, comment == nil {
                guard let c = bytes(offset + 4, length) else { return nil }
                comment = c
            }
            picture = picture || type == 6
            offset += 4 + length
        }
        guard offset <= fileSize() else { return nil }
        let pictureFields: Set = ["METADATA_BLOCK_PICTURE", "COVERART"]
        guard let fields = comment.flatMap(vorbisFields), !fields.keys.allSatisfy(pictureFields.contains) else { return nil }
        var out = fields.filter { Library.tagKeys.contains($0.key) }
        if picture || fields.keys.contains(where: pictureFields.contains) { out["PICTURE"] = [] }
        return out
    }

    /// A Vorbis comment's fields as TagLib's XiphComment keeps them: keys upper-cased, fields with an invalid key
    /// or an empty or non-UTF-8 value dropped, values cut at a NUL like the C strings TagLib hands back.
    private static func vorbisFields(_ d: ArraySlice<UInt8>) -> [String: [String]]? {
        var p = d.startIndex
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard d.endIndex - p >= n else { return nil }
            defer { p += n }
            return d[p..<p + n]
        }
        func le32() -> Int? { take(4)?.reversed().reduce(0) { $0 << 8 | Int($1) } }
        guard let vendor = le32(), take(vendor) != nil, let count = le32() else { return nil }
        var fields: [String: [String]] = [:]
        for _ in 0..<count {
            guard let n = le32(), let entry = take(n) else { return nil }
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")), eq > entry.startIndex,
                  entry[..<eq].allSatisfy({ (0x20...0x7D).contains($0) }),
                  let value = String(bytes: entry[(eq + 1)...], encoding: .utf8), !value.isEmpty else { continue }
            fields[String(decoding: entry[..<eq], as: UTF8.self).uppercased(), default: []].append(String(value.prefix { $0 != "\0" }))
        }
        return fields
    }

    /// Tags by path with the size and modification date they were read at.
    private static let cache = Locked<[String: (size: Int?, date: Date, tags: [String: [String]])]>([:])

    /// Reads many files, 32 at a time: NAS round trips, not CPU, are the limit. A file whose size and modification
    /// date (prefetched by the folder walk) still match the cache isn't read again, so rescans only read changes.
    static func readAll(_ urls: [URL], progress: (Int) -> Void = { _ in }) -> [[String: [String]]] {
        let done = Locked(0)
        return urls.concurrentMap { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let cached = cache { $0[url.path] }.flatMap { $0.date == v?.contentModificationDate && $0.size == v?.fileSize ? $0.tags : nil }
            let tags = cached ?? read(url)
            if let date = v?.contentModificationDate { cache { $0[url.path] = (v?.fileSize, date, tags) } }
            let n = done { $0 += 1; return $0 }
            if n % 100 == 0 || n == urls.count { progress(n) }
            return tags
        }
    }

    /// Writes made here can land within the NAS listing cache's lifetime, so the folder walk may still report the
    /// old modification date; dropping the entry makes the next scan read the file again.
    private static func forget(_ url: URL) {
        cache { _ = $0.removeValue(forKey: url.path) }
    }

    static func write(_ url: URL, _ fields: [String: [String]]) throws {
        defer { forget(url) }
        guard let f = openFile(url), cum_file_is_valid(f) != 0 else { throw TagError(url: url) }
        defer { taglib_file_free(f) }
        for (key, values) in fields {
            taglib_property_set(f, key, values.first)
            for v in values.dropFirst() { taglib_property_set_append(f, key, v) }
        }
        guard cum_file_save(f) != 0 else { throw TagError(url: url) }
    }

    /// TagLib's `char *` file names are ANSI on Windows, which can't name most Chinese paths; wide ones can.
    private static func openFile(_ url: URL) -> UnsafeMutablePointer<TagLib_File>? {
        #if os(Windows)
        url.withUnsafeFileSystemRepresentation { p in
            p.flatMap { String(cString: $0) }.flatMap { $0.withCString(encodedAs: UTF16.self) { taglib_file_new_wchar($0) } }
        }
        #else
        taglib_file_new(url.path)
        #endif
    }

    private static func hasPicture(_ f: UnsafeMutablePointer<TagLib_File>) -> Bool {
        guard let keys = taglib_complex_property_keys(f) else { return false }
        defer { taglib_complex_property_free_keys(keys) }
        var i = 0
        while let k = keys[i] {
            if String(cString: k) == "PICTURE" { return true }
            i += 1
        }
        return false
    }

    static func embedArt(_ url: URL, _ data: Data, mime: String) throws {
        defer { forget(url) }
        guard let f = openFile(url), cum_file_is_valid(f) != 0 else { throw TagError(url: url) }
        defer { taglib_file_free(f) }
        let ok = data.withUnsafeBytes { raw in
            cum_set_picture(f, raw.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(data.count), mime) != 0
        }
        guard ok, cum_file_save(f) != 0 else { throw TagError(url: url) }
    }

    static func embeddedArt(_ url: URL) -> Data? {
        guard let f = openFile(url) else { return nil }
        defer { taglib_file_free(f) }
        guard let props = taglib_complex_property_get(f, "PICTURE") else { return nil }
        defer { taglib_complex_property_free(props) }
        var pic = TagLib_Complex_Property_Picture_Data()
        taglib_picture_from_complex_property(props, &pic)
        return pic.data.map { Data(bytes: $0, count: Int(pic.size)) }
    }
}

/// A value shared by concurrent NAS calls; calling it runs the closure on the value under the lock.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func callAsFunction<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}

extension Array {
    /// `map` on up to 32 threads. NAS calls mostly wait on the network, so one thread per core leaves it idle.
    /// Serial queues always get a thread; global queues may not, when callers blocked in Swift tasks hold the pool.
    func concurrentMap<T>(_ transform: (Element) -> T) -> [T] {
        let state = Locked((results: [T?](repeating: nil, count: count), next: 0))
        let finished = DispatchGroup()
        withoutActuallyEscaping(transform) { transform in
            for _ in 0..<Swift.min(32, count) {
                DispatchQueue(label: "nas").async(group: finished) {
                    func claim() -> Int? { state { s in guard s.next < count else { return nil }; defer { s.next += 1 }; return s.next } }
                    while let i = claim() {
                        let r = transform(self[i])
                        state { $0.results[i] = r }
                    }
                }
            }
            finished.wait()
        }
        return state { $0.results.map { $0! } }
    }
}
