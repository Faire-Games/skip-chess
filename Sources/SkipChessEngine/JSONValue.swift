// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// A small purpose-built JSON value/parser/encoder used by the wire
// protocol layer. We can't lean on `Foundation.JSONSerialization` /
// `JSONEncoder` because this module deliberately avoids Foundation (it
// has to transpile through Skip and compile to wasm32-unknown-wasi,
// neither of which carries Foundation's JSON code paths for free).
//
// The parser is a permissive recursive-descent implementation; it
// accepts the strict subset of JSON used by the Lichess
// `{t, d, v, a, l}` envelope and the typed round payloads we send /
// receive. It is *not* intended as a general-purpose JSON library.

/// A dynamic JSON value used internally by ``WireEnvelope`` and
/// ``RoundMessage`` decoding.
///
/// Object entries are kept as parallel arrays (rather than a Dictionary)
/// to preserve insertion order on the wire — Lichess clients are
/// sensitive to field ordering for things like canonical equality checks
/// in tests, and the upstream Scala serializer always emits `t` first.
public indirect enum JSONValue {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    // MARK: - Convenience accessors

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let n): return Int(n)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .integer(let n): return n
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let n): return Double(n)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectEntries: [(String, JSONValue)]? {
        if case .object(let entries) = self { return entries }
        return nil
    }

    /// Look up a key inside an object value.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let entries) = self else { return nil }
        for entry in entries where entry.0 == key {
            return entry.1
        }
        return nil
    }
}

// MARK: - Equatable

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        // Single-value pattern matches (Skip's transpiler refuses
        // tuple-pattern matches in `switch (lhs, rhs)`).
        switch lhs {
        case .string(let a):
            if case .string(let b) = rhs { return a == b }
            return false
        case .integer(let a):
            if case .integer(let b) = rhs { return a == b }
            return false
        case .double(let a):
            if case .double(let b) = rhs { return a == b }
            return false
        case .bool(let a):
            if case .bool(let b) = rhs { return a == b }
            return false
        case .null:
            if case .null = rhs { return true }
            return false
        case .array(let a):
            guard case .array(let b) = rhs else { return false }
            if a.count != b.count { return false }
            for i in 0..<a.count where a[i] != b[i] { return false }
            return true
        case .object(let a):
            guard case .object(let b) = rhs else { return false }
            if a.count != b.count { return false }
            for i in 0..<a.count {
                if a[i].0 != b[i].0 { return false }
                if a[i].1 != b[i].1 { return false }
            }
            return true
        }
    }
}

// MARK: - Encoding

extension JSONValue {

    /// Serializes this value to a compact JSON string.
    public func encoded() -> String {
        var out = ""
        Self.append(self, into: &out)
        return out
    }

    private static func append(_ value: JSONValue, into out: inout String) {
        switch value {
        case .string(let s):
            out += "\""
            out += escapeString(s)
            out += "\""
        case .integer(let n):
            out += String(n)
        case .double(let d):
            // The Lichess wire never carries non-finite floats; if a
            // pathological caller hands us one, emit `null` rather than
            // breaking the JSON output.
            if d.isNaN || d.isInfinite {
                out += "null"
            } else {
                out += String(d)
            }
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        case .array(let arr):
            out += "["
            var first = true
            for v in arr {
                if !first { out += "," }
                append(v, into: &out)
                first = false
            }
            out += "]"
        case .object(let entries):
            out += "{"
            var first = true
            for entry in entries {
                if !first { out += "," }
                out += "\""
                out += escapeString(entry.0)
                out += "\":"
                append(entry.1, into: &out)
                first = false
            }
            out += "}"
        }
    }

    private static func escapeString(_ s: String) -> String {
        var out = ""
        for c in s {
            // Compare against ASCII byte values rather than literal escape
            // sequences — Skip's transpiler can't faithfully reproduce
            // Swift `"\u{08}"`-style case labels in Kotlin source.
            // The fallback is wrapped in `UInt8(...)` so the Kotlin output
            // keeps the type as UByte (the bare `255` literal would be Int).
            let ascii: UInt8 = c.asciiValue ?? UInt8(255)
            let code: Int = Int(ascii)
            switch code {
            case 0x22:           // "
                out += "\\\""
            case 0x5C:           // \\
                out += "\\\\"
            case 0x0A:           // \n
                out += "\\n"
            case 0x0D:           // \r
                out += "\\r"
            case 0x09:           // \t
                out += "\\t"
            case 0x08:           // \b
                out += "\\b"
            case 0x0C:           // \f
                out += "\\f"
            default:
                if code < 0x20 {
                    out += "\\u"
                    out += hex4(code)
                } else {
                    out += String(c)
                }
            }
        }
        return out
    }

    private static func hex4(_ n: Int) -> String {
        let digits = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
        let d0 = digits[(n >> 12) & 0xF]
        let d1 = digits[(n >> 8) & 0xF]
        let d2 = digits[(n >> 4) & 0xF]
        let d3 = digits[n & 0xF]
        return d0 + d1 + d2 + d3
    }
}

// MARK: - Parsing

/// Recursive-descent JSON parser. Accepts the strict JSON we send / receive
/// over the wire; does *not* try to be a tolerant JSON5-style implementation.
public enum JSONParser {

    /// Lookup table for printable ASCII characters (0x20 ' ' through 0x7E
    /// '~'). Used by the `\uXXXX` escape handler — Skip's transpiler
    /// rejects direct `UnicodeScalar(UInt8(code))` construction, so we
    /// fall back to an indexed string table.
    private static let asciiPrintables: [String] = [
        " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",",
        "-", ".", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        ":", ";", "<", "=", ">", "?", "@", "A", "B", "C", "D", "E", "F",
        "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S",
        "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", "`",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
        "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "{", "|", "}", "~",
    ]

    /// Parses a single JSON value. Returns `nil` if the input is malformed.
    public static func parse(_ input: String) -> JSONValue? {
        var chars: [Character] = []
        chars.reserveCapacity(input.count)
        for c in input { chars.append(c) }
        var index = 0
        skipWhitespace(chars, &index)
        guard let value = parseValue(chars, &index) else { return nil }
        skipWhitespace(chars, &index)
        if index != chars.count { return nil }
        return value
    }

    // MARK: Tokens

    private static func skipWhitespace(_ chars: [Character], _ index: inout Int) {
        while index < chars.count {
            let c = chars[index]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                index += 1
            } else {
                return
            }
        }
    }

    private static func parseValue(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        skipWhitespace(chars, &index)
        if index >= chars.count { return nil }
        let c = chars[index]
        switch c {
        case "\"":
            // Explicit JSONValue prefix — Skip's transpiler chokes on the
            // implicit `.string` short-hand here.
            if let s = parseString(chars, &index) {
                return JSONValue.string(s)
            }
            return nil
        case "{": return parseObject(chars, &index)
        case "[": return parseArray(chars, &index)
        case "t", "f": return parseBool(chars, &index)
        case "n": return parseNull(chars, &index)
        default:
            if c == "-" || (c >= "0" && c <= "9") {
                return parseNumber(chars, &index)
            }
            return nil
        }
    }

    private static func parseString(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count, chars[index] == "\"" else { return nil }
        index += 1
        var out = ""
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                index += 1
                return out
            }
            if c == "\\" {
                index += 1
                if index >= chars.count { return nil }
                let esc = chars[index]
                switch esc {
                case "\"": out += "\""
                case "\\": out += "\\"
                case "/": out += "/"
                case "n": out += "\n"
                case "r": out += "\r"
                case "t": out += "\t"
                case "u":
                    // \uXXXX — 4 hex digits. We consume the digits but
                    // only emit the result for the printable-ASCII range
                    // (0x20–0x7E); anything outside that is silently
                    // dropped. (a) Lichess wire payloads are ASCII-only,
                    // so this is sufficient in practice, and (b) the more
                    // general UnicodeScalar / Character construction
                    // paths don't transpile cleanly through Skip.
                    var code = 0
                    for _ in 0..<4 {
                        index += 1
                        if index >= chars.count { return nil }
                        guard let digit = hexDigit(chars[index]) else { return nil }
                        code = (code << 4) | digit
                    }
                    if code >= 0x20 && code <= 0x7E {
                        let alphabetIdx = code - 0x20
                        out += asciiPrintables[alphabetIdx]
                    }
                default:
                    // `\b` and `\f` are accepted by the JSON spec but
                    // never appear on the Lichess wire; rejecting them
                    // here keeps the codec ASCII-clean.
                    return nil
                }
                index += 1
            } else {
                out += String(c)
                index += 1
            }
        }
        return nil  // unterminated
    }

    private static func hexDigit(_ c: Character) -> Int? {
        let ascii: UInt8 = c.asciiValue ?? UInt8(0)
        let code: Int = Int(ascii)
        if code >= 0x30 && code <= 0x39 {
            return code - 0x30
        }
        if code >= 0x61 && code <= 0x66 {
            return code - 0x57
        }
        if code >= 0x41 && code <= 0x46 {
            return code - 0x37
        }
        return nil
    }

    private static func parseNumber(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        let start = index
        if chars[index] == "-" { index += 1 }
        while index < chars.count, chars[index] >= "0" && chars[index] <= "9" {
            index += 1
        }
        var isDouble = false
        if index < chars.count, chars[index] == "." {
            isDouble = true
            index += 1
            while index < chars.count, chars[index] >= "0" && chars[index] <= "9" {
                index += 1
            }
        }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            isDouble = true
            index += 1
            if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            while index < chars.count, chars[index] >= "0" && chars[index] <= "9" {
                index += 1
            }
        }
        var text = ""
        for i in start..<index { text += String(chars[i]) }
        if isDouble {
            guard let d = Double(text) else { return nil }
            return .double(d)
        }
        guard let n = Int64(text) else { return nil }
        return .integer(n)
    }

    private static func parseBool(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        if matchKeyword(chars, &index, "true") { return .bool(true) }
        if matchKeyword(chars, &index, "false") { return .bool(false) }
        return nil
    }

    private static func parseNull(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        if matchKeyword(chars, &index, "null") { return .null }
        return nil
    }

    private static func matchKeyword(_ chars: [Character], _ index: inout Int, _ word: String) -> Bool {
        var i = index
        for w in word {
            if i >= chars.count || chars[i] != w { return false }
            i += 1
        }
        index = i
        return true
    }

    private static func parseArray(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        guard index < chars.count, chars[index] == "[" else { return nil }
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace(chars, &index)
        if index < chars.count, chars[index] == "]" {
            index += 1
            return .array(elements)
        }
        while index < chars.count {
            guard let value = parseValue(chars, &index) else { return nil }
            elements.append(value)
            skipWhitespace(chars, &index)
            if index >= chars.count { return nil }
            let c = chars[index]
            if c == "," {
                index += 1
                continue
            }
            if c == "]" {
                index += 1
                return .array(elements)
            }
            return nil
        }
        return nil
    }

    private static func parseObject(_ chars: [Character], _ index: inout Int) -> JSONValue? {
        guard index < chars.count, chars[index] == "{" else { return nil }
        index += 1
        var entries: [(String, JSONValue)] = []
        skipWhitespace(chars, &index)
        if index < chars.count, chars[index] == "}" {
            index += 1
            return .object(entries)
        }
        while index < chars.count {
            skipWhitespace(chars, &index)
            guard let key = parseString(chars, &index) else { return nil }
            skipWhitespace(chars, &index)
            if index >= chars.count || chars[index] != ":" { return nil }
            index += 1
            guard let value = parseValue(chars, &index) else { return nil }
            entries.append((key, value))
            skipWhitespace(chars, &index)
            if index >= chars.count { return nil }
            let c = chars[index]
            if c == "," {
                index += 1
                continue
            }
            if c == "}" {
                index += 1
                return .object(entries)
            }
            return nil
        }
        return nil
    }
}
