import Foundation
#if os(Windows)
import WinSDK
#endif

/// The code pages file names get garbled through: bytes written in one and shown in another.
enum Codepage: String, CaseIterable, Sendable {
    case cp1252 = "Western (cp1252)", cp437 = "DOS (cp437)", shiftJIS = "Shift-JIS", gbk = "GBK", big5 = "Big5", cp949 = "Korean (CP949)", utf8 = "UTF-8"

    #if os(Windows)
    private var windowsCodepage: UINT {
        switch self {
        case .cp1252: 1252
        case .cp437: 437
        case .shiftJIS: 932
        case .gbk: 936
        case .big5: 950
        case .cp949: 949
        case .utf8: UINT(CP_UTF8)
        }
    }
    #else
    private var encoding: String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .cp1252: return .windowsCP1252
        case .cp437: return cf(.dosLatinUS)
        case .shiftJIS: return cf(.dosJapanese)
        case .gbk: return cf(.dosChineseSimplif)
        case .big5: return cf(.dosChineseTrad)
        case .cp949: return cf(.dosKorean)
        case .utf8: return .utf8
        }
    }
    #endif

    /// The text these bytes spell, or nil when they aren't valid here.
    func decode(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return "" }
        #if os(Windows)
        let flags = DWORD(MB_ERR_INVALID_CHARS)
        let n = bytes.withUnsafeBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CHAR.self, capacity: b.count) {
                MultiByteToWideChar(windowsCodepage, flags, $0, Int32(b.count), nil, 0)
            }
        }
        guard n > 0 else { return nil }
        var wide = [WCHAR](repeating: 0, count: Int(n))
        _ = bytes.withUnsafeBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CHAR.self, capacity: b.count) {
                MultiByteToWideChar(windowsCodepage, flags, $0, Int32(b.count), &wide, n)
            }
        }
        return String(decoding: wide, as: UTF16.self)
        #else
        return String(data: Data(bytes), encoding: encoding)
        #endif
    }

    /// The bytes for this text, or nil when a character has no exact counterpart here.
    func encode(_ s: String) -> [UInt8]? {
        #if os(Windows)
        let wide = Array(s.utf16)
        guard !wide.isEmpty else { return [] }
        var lossy: WindowsBool = false
        let usesDefault = self != .utf8 // CP_UTF8 rejects the "used default char" check
        let flags = DWORD(usesDefault ? WC_NO_BEST_FIT_CHARS : WC_ERR_INVALID_CHARS)
        return withUnsafeMutablePointer(to: &lossy) { lossyPointer in
            let lossy = usesDefault ? lossyPointer : nil
            let n = WideCharToMultiByte(windowsCodepage, flags, wide, Int32(wide.count), nil, 0, nil, lossy)
            guard n > 0, lossy?.pointee.boolValue != true else { return nil }
            var out = [CHAR](repeating: 0, count: Int(n))
            _ = WideCharToMultiByte(windowsCodepage, flags, wide, Int32(wide.count), &out, n, nil, lossy)
            guard lossy?.pointee.boolValue != true else { return nil }
            return out.map { UInt8(bitPattern: $0) }
        }
        #else
        return s.data(using: encoding, allowLossyConversion: false).map { [UInt8]($0) }
        #endif
    }
}

/// Repairs names whose bytes were read in the wrong code page: Shift-JIS, GBK, Big5, Korean or UTF-8 shown as
/// Western (cp1252) or DOS (cp437, how ZIP tools read names without the UTF-8 flag), or GBK/Big5/Korean shown as
/// Shift-JIS (half-width katakana mixed with kanji, e.g. Japanese saved on a Korean PC).
public enum Mojibake {
    public struct Repair: Equatable, Sendable {
        public let name: String
        /// How the bytes were meant to be read, e.g. "Shift-JIS".
        public let encoding: String
    }

    /// The repaired name, or nil when the name reads fine. `hint` (e.g. the track's TITLE) settles which reading
    /// is meant when it appears in one of them.
    public static func repair(_ name: String, hint: String? = nil) -> Repair? {
        guard !isLossy(name) else { return nil }
        var best: (repair: Repair, score: Double)?
        for (repaired, source, target) in candidates(name) {
            var score = target == .utf8 ? 2 : commonShare(source.encode(name)!, target)
            // Real Japanese has kana; another page's reading of the same bytes is mostly random kanji.
            if target != .utf8, repaired.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { score += 0.5 }
            // The hint must be what changed: a TITLE in plain ASCII is in every reading of the name.
            if let hint, !hint.isEmpty, repaired.contains(hint), !name.contains(hint) { score += 10 }
            if score > (best?.score ?? 0) { best = (Repair(name: repaired, encoding: target.rawValue), score) }
        }
        // UTF-8 that decodes cleanly is unmistakable; a double-byte reading needs most of its characters common.
        guard let best, best.score >= 0.75 else { return nil }
        return best.repair
    }

    /// Whether the name has a clean reading in another code page at all, or is garbled past reading; cheap enough to
    /// run on every name before reading tags for the hint.
    public static func mightBeGarbled(_ name: String) -> Bool { isLossy(name) || !candidates(name).isEmpty }

    /// Garbled through Shift-JIS with bytes lost on the way: Windows writes ・ for each byte sequence Shift-JIS
    /// has no character for, so no reading can bring the name back. Only a tag can.
    public static func isLossy(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return scalars.filter(isHalfwidthKana).count >= 2 && scalars.contains { $0 == "\u{30FB}" || $0 == "\u{FFFD}" }
    }

    /// A name rebuilt from the track's TITLE for a name garbled past reading: its leading track number, the title
    /// (characters Windows forbids replaced) and its extension, e.g. "03 ｪｪ・・ｪﾇﾘﾇ.mp3" with TITLE お花畑で週末 gives
    /// "03 お花畑で週末.mp3".
    public static func fromTitle(_ name: String, title: String) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let number = stem.prefix { $0.isNumber || " .-_".contains($0) }
        let safe = title.map { "\\/:*?\"<>|".contains($0) ? "_" : $0 }
        return String(number) + String(safe).trimmingCharacters(in: .whitespaces) + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
    }

    /// Every clean reading of the name's bytes in another code page.
    private static func candidates(_ name: String) -> [(String, Codepage, Codepage)] {
        let scalars = name.unicodeScalars
        // Real CJK means the name was read right; garbling through a single-byte page leaves Latin, symbols and box
        // drawing, and GBK/Big5 through Shift-JIS leaves half-width katakana mixed in.
        let halfwidthKana = scalars.filter(isHalfwidthKana).count
        let sources: [Codepage]
        if halfwidthKana >= 2 {
            sources = [.shiftJIS]
        } else if scalars.contains(where: isCJK) || !scalars.contains(where: { $0.value >= 0x80 }) {
            return []
        } else {
            // Curly quotes and dashes ("Rock’n’Roll") and a few accented letters in plain words ("Pièces", "Göran
            // Söllscher") are just real names, yet in cp1252 and cp437 they are Shift-JIS lead bytes. Garbling
            // leaves symbols (º ´ µ ¨ § ƒ ˆ), box drawing or Greek, or makes most letters accented ("ÖÐÎÄ").
            let unusual = scalars.filter { !$0.isASCII && !typographic.contains($0) }
            let odd = unusual.filter { !((0xC0...0x24F).contains($0.value) && $0.properties.isAlphabetic) }
            let letters = scalars.filter { $0.properties.isAlphabetic }.count
            guard !odd.isEmpty || unusual.count * 2 >= letters else { return [] }
            sources = [.cp1252, .cp437]
        }
        var out: [(String, Codepage, Codepage)] = []
        for source in sources {
            guard let bytes = source.encode(name) else { continue }
            for target in [Codepage.utf8, .shiftJIS, .gbk, .big5, .cp949] where target != source {
                guard let text = target.decode(bytes), text != name, isClean(text) else { continue }
                // A double-byte reading must turn at least two byte pairs into CJK, or one stray accented letter
                // next to another (e.g. "××") would count.
                if target != .utf8, text.unicodeScalars.filter(isCJK).count < 2 { continue }
                if target == .utf8, !text.unicodeScalars.contains(where: { $0.value >= 0x80 }) { continue }
                out.append((text, source, target))
            }
        }
        return out
    }

    /// Share of the double-byte characters in the code page's everyday range: kana and level-1 kanji for
    /// Shift-JIS, GB2312 level-1 hanzi for GBK, the frequent-character block for Big5, symbols, kana and Hangul for
    /// Korean. Garbage readings of other pages' bytes land mostly outside it.
    private static func commonShare(_ bytes: [UInt8], _ page: Codepage) -> Double {
        var pairs = 0, common = 0, i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b >= 0x80, i + 1 < bytes.count else { i += 1; continue }
            // Shift-JIS half-width katakana are single bytes.
            if page == .shiftJIS, (0xA1...0xDF).contains(b) { i += 1; continue }
            let t = bytes[i + 1]
            pairs += 1
            switch page {
            case .shiftJIS: if b == 0x81 || b == 0x82 || b == 0x83 || (0x88...0x98).contains(b) { common += 1 }
            case .gbk: if (0xA1...0xA3).contains(b) || ((0xB0...0xD7).contains(b) && t >= 0xA1) { common += 1 }
            case .big5: if (0xA1...0xC6).contains(b) { common += 1 }
            case .cp949: if (0xA1...0xAC).contains(b) || ((0xB0...0xC8).contains(b) && t >= 0xA1) { common += 1 }
            default: break
            }
            i += 2
        }
        return pairs == 0 ? 0 : Double(common) / Double(pairs)
    }

    private static func isClean(_ s: String) -> Bool {
        !s.unicodeScalars.contains { s in
            s.properties.generalCategory == .control || s.properties.generalCategory == .privateUse
                || s.value == 0xFFFD || isHalfwidthKana(s) || (0x2500...0x259F).contains(s.value)
                // Accented letters are fine in a repaired name ("Café" from UTF-8); the symbols around them are not.
                || (0x80...0x24F).contains(s.value) && !s.properties.isAlphabetic
        }
    }

    private static let typographic = Set("‘’‚“”„–—…•′″‹›«»·×°".unicodeScalars)

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x3000...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value)
    }

    private static func isHalfwidthKana(_ s: Unicode.Scalar) -> Bool { (0xFF61...0xFF9F).contains(s.value) }
}
