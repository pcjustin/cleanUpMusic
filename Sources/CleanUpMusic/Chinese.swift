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
    /// Text with kana is Japanese, whose kanji (恋, 写, 声…) would otherwise read as Simplified.
    static func convert(_ s: String) -> String? {
        guard !hasKana(s) else { return nil }
        let t = toTraditional(s)
        return t == s ? nil : t
    }

    static func hasKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) }
    }
}
