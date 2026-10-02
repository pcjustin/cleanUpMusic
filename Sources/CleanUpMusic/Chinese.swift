import COpenCC
import Foundation

enum Chinese {
    private static let converter: opencc_t = {
        let cc = opencc_open("s2tw.json")
        precondition(cc != UnsafeMutableRawPointer(bitPattern: -1), "OpenCC s2tw.json not found: brew install opencc")
        return cc!
    }()

    static func toTraditional(_ s: String) -> String {
        guard let out = opencc_convert_utf8(converter, s, -1) else { return s }
        defer { opencc_convert_utf8_free(out) }
        return String(cString: out)
    }

    /// Returns the Traditional form only when the input contains Simplified characters.
    static func convert(_ s: String) -> String? {
        let t = toTraditional(s)
        return t == s ? nil : t
    }
}
