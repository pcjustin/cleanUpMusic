import CTagLib
import Foundation

struct TagError: LocalizedError {
    let url: URL
    var errorDescription: String? { "無法寫入標籤：\(url.path)" }
}

enum Tags {
    /// Reads `Library.tagKeys`, plus `"PICTURE": []` when the file has embedded art.
    static func read(_ url: URL) -> [String: [String]] {
        guard let f = taglib_file_new(url.path) else { return [:] }
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

    /// Reads many files at once; NAS latency dominates, so concurrency is a large win.
    static func readAll(_ urls: [URL], progress: (Int) -> Void = { _ in }) -> [[String: [String]]] {
        let box = Box(count: urls.count)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in progress(box.set(i, read(urls[i]))) }
        return box.values
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [[String: [String]]]
        init(count: Int) { values = Array(repeating: [:], count: count) }
        private var done = 0
        func set(_ i: Int, _ v: [String: [String]]) -> Int { lock.lock(); defer { lock.unlock() }; values[i] = v; done += 1; return done }
    }

    static func write(_ url: URL, _ fields: [String: [String]]) throws {
        guard let f = taglib_file_new(url.path), taglib_file_is_valid(f) != 0 else { throw TagError(url: url) }
        defer { taglib_file_free(f) }
        for (key, values) in fields {
            taglib_property_set(f, key, values.first)
            for v in values.dropFirst() { taglib_property_set_append(f, key, v) }
        }
        guard taglib_file_save(f) != 0 else { throw TagError(url: url) }
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
        guard let f = taglib_file_new(url.path), taglib_file_is_valid(f) != 0 else { throw TagError(url: url) }
        defer { taglib_file_free(f) }
        let ok = data.withUnsafeBytes { raw in
            cum_set_picture(f, raw.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(data.count), mime) != 0
        }
        guard ok, taglib_file_save(f) != 0 else { throw TagError(url: url) }
    }

    static func embeddedArt(_ url: URL) -> Data? {
        guard let f = taglib_file_new(url.path) else { return nil }
        defer { taglib_file_free(f) }
        guard let props = taglib_complex_property_get(f, "PICTURE") else { return nil }
        defer { taglib_complex_property_free(props) }
        var pic = TagLib_Complex_Property_Picture_Data()
        taglib_picture_from_complex_property(props, &pic)
        return pic.data.map { Data(bytes: $0, count: Int(pic.size)) }
    }
}
