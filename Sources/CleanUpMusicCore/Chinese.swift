import COpenCC
import Foundation

public enum Chinese {
    /// Folder holding OpenCC's `s2tw.json` and its dictionaries; nil uses OpenCC's install location (Homebrew).
    /// Windows ships them next to the app, so the host sets this before the first conversion.
    nonisolated(unsafe) public static var dataDir: URL?

    private static let converter: opencc_t = {
        let config = dataDir.map { $0.appendingPathComponent("s2tw.json").withUnsafeFileSystemRepresentation { String(cString: $0!) } } ?? "s2tw.json"
        #if os(Windows)
        let cc = config.withCString(encodedAs: UTF16.self) { opencc_open_w($0) } // `char *` paths are ANSI there
        #else
        let cc = opencc_open(config)
        #endif
        precondition(cc != UnsafeMutableRawPointer(bitPattern: -1), "OpenCC \(config) not found: brew install opencc")
        return cc!
    }()

    public static func toTraditional(_ s: String) -> String {
        guard let out = opencc_convert_utf8(converter, s, -1) else { return s }
        defer { opencc_convert_utf8_free(out) }
        return String(cString: out)
    }

    /// Returns the Traditional form only when the input contains Simplified characters.
    /// Text with kana is Japanese, whose kanji (恋, 写, 声…) would otherwise read as Simplified.
    public static func convert(_ s: String) -> String? {
        guard !hasKana(s) else { return nil }
        let t = toTraditional(s)
        return t == s ? nil : t
    }

    public static func hasKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) }
    }
}
