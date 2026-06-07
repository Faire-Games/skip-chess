// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine

@Suite struct WireEnvelopeTests {

    @Test func encodeBareTypeOnly() throws {
        let env = WireEnvelope(type: "resync")
        #expect(WireCodec.encode(env) == "{\"t\":\"resync\"}")
    }

    @Test func encodeWithVersion() throws {
        let env = WireEnvelope(type: "move", version: 42)
        #expect(WireCodec.encode(env) == "{\"t\":\"move\",\"v\":42}")
    }

    @Test func encodeWithPayload() throws {
        let payload: JSONValue = .object([
            ("uci", .string("e2e4")),
            ("san", .string("e4")),
        ])
        let env = WireEnvelope(type: "move", data: payload, version: 1)
        #expect(WireCodec.encode(env) == "{\"t\":\"move\",\"v\":1,\"d\":{\"uci\":\"e2e4\",\"san\":\"e4\"}}")
    }

    @Test func encodeAckMessage() throws {
        let env = WireEnvelope(type: "ack", data: .integer(7))
        #expect(WireCodec.encode(env) == "{\"t\":\"ack\",\"d\":7}")
    }

    @Test func encodeClientPingWithLag() throws {
        // Every 10th client ping carries an `l` lag estimate.
        let env = WireEnvelope(type: "p", lag: 42)
        #expect(WireCodec.encode(env) == "{\"t\":\"p\",\"l\":42}")
    }

    @Test func decodeBarePingPong() throws {
        let ping = try #require(WireCodec.decode("p"))
        #expect(ping.type == "p")
        #expect(ping.data == .null)
        let pong = try #require(WireCodec.decode("0"))
        #expect(pong.type == "0")
    }

    @Test func decodeMoveFromServer() throws {
        let raw = "{\"t\":\"move\",\"v\":1,\"d\":{\"uci\":\"e2e4\",\"san\":\"e4\",\"fen\":\"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1\",\"ply\":1,\"clock\":{\"white\":180,\"black\":180,\"lag\":3}}}"
        let env = try #require(WireCodec.decode(raw))
        #expect(env.type == "move")
        #expect(env.version == 1)
        #expect(env.ackId == nil)
        #expect(env.data["uci"]?.stringValue == "e2e4")
        #expect(env.data["fen"]?.stringValue?.hasPrefix("rnbqkbnr") == true)
    }

    @Test func decodeMoveFromClient() throws {
        // Client → server moves are usually un-versioned and use `u` for
        // the UCI string.
        let raw = "{\"t\":\"move\",\"d\":{\"u\":\"e2e4\"}}"
        let env = try #require(WireCodec.decode(raw))
        #expect(env.type == "move")
        #expect(env.version == nil)
        #expect(env.data["u"]?.stringValue == "e2e4")
    }

    @Test func decodeClientPingWithLag() throws {
        let env = try #require(WireCodec.decode("{\"t\":\"p\",\"l\":42}"))
        #expect(env.type == "p")
        #expect(env.lag == 42)
    }

    @Test func decodeAck() throws {
        let env = try #require(WireCodec.decode("{\"t\":\"ack\",\"d\":7}"))
        #expect(env.type == "ack")
        #expect(env.data.intValue == 7)
    }

    @Test func decodeRejectsMissingType() throws {
        #expect(WireCodec.decode("{\"d\":1}") == nil)
        #expect(WireCodec.decode("") == nil)
        #expect(WireCodec.decode("{") == nil)
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = WireEnvelope(
            type: "move",
            data: .object([("uci", .string("g1f3"))]),
            version: 3,
            ackId: 5,
            lag: 12,
        )
        let wire = WireCodec.encode(original)
        let decoded = try #require(WireCodec.decode(wire))
        #expect(decoded == original)
    }

    @Test func nullDataOmittedFromOutput() throws {
        let env = WireEnvelope(type: "resign")
        // ``encode`` skips a `.null` `d` field to keep messages tight.
        let wire = WireCodec.encode(env)
        #expect(!wire.contains("\"d\""))
    }
}
