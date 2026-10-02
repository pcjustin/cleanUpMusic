import CTagLib
import Foundation

struct TagError: LocalizedError {
    let url: URL
    var errorDescription: String? { "無法寫入標籤：\(url.path)" }
}

enum Tags {
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
        return out
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

    static func hasEmbeddedArt(_ url: URL) -> Bool {
        guard let f = taglib_file_new(url.path) else { return false }
        defer { taglib_file_free(f) }
        guard let keys = taglib_complex_property_keys(f) else { return false }
        defer { taglib_complex_property_free_keys(keys) }
        var i = 0
        while let k = keys[i] {
            if String(cString: k) == "PICTURE" { return true }
            i += 1
        }
        return false
    }
}
