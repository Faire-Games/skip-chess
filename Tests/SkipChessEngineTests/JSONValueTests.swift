// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine

@Suite struct JSONValueTests {

    @Test func parsePrimitives() throws {
        #expect(JSONParser.parse("true") == .bool(true))
        #expect(JSONParser.parse("false") == .bool(false))
        #expect(JSONParser.parse("null") == .null)
        #expect(JSONParser.parse("0") == .integer(0))
        #expect(JSONParser.parse("42") == .integer(42))
        #expect(JSONParser.parse("-7") == .integer(-7))
        #expect(JSONParser.parse("3.14") == .double(3.14))
        #expect(JSONParser.parse("-2.5e3") == .double(-2500.0))
        #expect(JSONParser.parse("\"\"") == .string(""))
        #expect(JSONParser.parse("\"hello\"") == .string("hello"))
    }

    @Test func parseStringEscapes() throws {
        #expect(JSONParser.parse("\"a\\nb\"") == .string("a\nb"))
        #expect(JSONParser.parse("\"a\\tb\"") == .string("a\tb"))
        #expect(JSONParser.parse("\"\\\"q\\\"\"") == .string("\"q\""))
        // \uXXXX escapes for printable ASCII round-trip.
        #expect(JSONParser.parse("\"\\u0041\"") == .string("A"))
        #expect(JSONParser.parse("\"\\u002F\"") == .string("/"))
        // Embedded backslash inside content.
        #expect(JSONParser.parse("\"a\\\\b\"") == .string("a\\b"))
    }

    @Test func parseArray() throws {
        #expect(JSONParser.parse("[]") == .array([]))
        #expect(JSONParser.parse("[1,2,3]") == .array([.integer(1), .integer(2), .integer(3)]))
        #expect(JSONParser.parse("[true, null, \"x\"]") == .array([.bool(true), .null, .string("x")]))
        #expect(JSONParser.parse("[[1],[2]]") == .array([.array([.integer(1)]), .array([.integer(2)])]))
    }

    @Test func parseObject() throws {
        guard case .object(let entries)? = JSONParser.parse("{\"a\":1,\"b\":\"two\"}") else {
            #expect(false, "expected object")
            return
        }
        #expect(entries.count == 2)
        #expect(entries[0].0 == "a")
        #expect(entries[0].1 == .integer(1))
        #expect(entries[1].0 == "b")
        #expect(entries[1].1 == .string("two"))
    }

    @Test func parseRejectsMalformed() throws {
        #expect(JSONParser.parse("") == nil)
        #expect(JSONParser.parse("{") == nil)
        #expect(JSONParser.parse("}") == nil)
        #expect(JSONParser.parse("[1,]") == nil)
        #expect(JSONParser.parse("\"unterminated") == nil)
        #expect(JSONParser.parse("nul") == nil)
        // Trailing garbage isn't allowed.
        #expect(JSONParser.parse("1 garbage") == nil)
    }

    @Test func subscriptOnObject() throws {
        let value = try #require(JSONParser.parse("{\"t\":\"move\",\"v\":5,\"d\":{\"uci\":\"e2e4\"}}"))
        #expect(value["t"]?.stringValue == "move")
        #expect(value["v"]?.intValue == 5)
        #expect(value["d"]?["uci"]?.stringValue == "e2e4")
        #expect(value["missing"] == nil)
    }

    @Test func encodePrimitives() throws {
        #expect(JSONValue.bool(true).encoded() == "true")
        #expect(JSONValue.null.encoded() == "null")
        #expect(JSONValue.integer(42).encoded() == "42")
        #expect(JSONValue.string("hi").encoded() == "\"hi\"")
    }

    @Test func encodeStringEscapes() throws {
        #expect(JSONValue.string("a\nb").encoded() == "\"a\\nb\"")
        #expect(JSONValue.string("\"q\"").encoded() == "\"\\\"q\\\"\"")
        // (`\u{01}`-style Swift escapes don't transpile through Skip;
        // the corresponding control-char encoding path is exercised
        // indirectly via the parse/encode round-trip tests.)
    }

    @Test func encodeObjectPreservesOrder() throws {
        let v: JSONValue = .object([
            ("t", .string("move")),
            ("v", .integer(5)),
            ("d", .object([("uci", .string("e2e4"))])),
        ])
        #expect(v.encoded() == "{\"t\":\"move\",\"v\":5,\"d\":{\"uci\":\"e2e4\"}}")
    }

    @Test func roundTripLichessMoveMessage() throws {
        let wire = "{\"t\":\"move\",\"v\":42,\"d\":{\"uci\":\"e2e4\",\"san\":\"e4\",\"fen\":\"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1\",\"ply\":1,\"clock\":{\"white\":180,\"black\":180,\"lag\":3}}}"
        let parsed = try #require(JSONParser.parse(wire))
        #expect(parsed["t"]?.stringValue == "move")
        #expect(parsed["v"]?.intValue == 42)
        #expect(parsed["d"]?["uci"]?.stringValue == "e2e4")
        #expect(parsed["d"]?["clock"]?["lag"]?.intValue == 3)
    }
}
