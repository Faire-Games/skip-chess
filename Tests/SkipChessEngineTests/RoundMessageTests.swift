// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine
import SkipChessModel

@Suite struct RoundMessageTests {

    // MARK: - Client → Server

    @Test func clientMoveToEnvelope() throws {
        let msg = RoundClientMessage.move(uci: "e2e4")
        let env = msg.toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"move\",\"d\":{\"u\":\"e2e4\"}}")
    }

    @Test func clientMoveWithAck() throws {
        let msg = RoundClientMessage.move(uci: "e2e4", ackId: 5)
        let env = msg.toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"move\",\"a\":5,\"d\":{\"u\":\"e2e4\"}}")
    }

    @Test func clientResignAndDrawCommands() throws {
        let resignWire = WireCodec.encode(RoundClientMessage.resign().toEnvelope())
        #expect(resignWire == "{\"t\":\"resign\"}")
        let drawYesWire = WireCodec.encode(RoundClientMessage.drawYes().toEnvelope())
        #expect(drawYesWire == "{\"t\":\"draw-yes\"}")
        let drawNoWire = WireCodec.encode(RoundClientMessage.drawNo().toEnvelope())
        #expect(drawNoWire == "{\"t\":\"draw-no\"}")
        let tbYesWire = WireCodec.encode(RoundClientMessage.takebackYes().toEnvelope())
        #expect(tbYesWire == "{\"t\":\"takeback-yes\"}")
    }

    @Test func clientFlagEncodesColor() throws {
        let env = RoundClientMessage.flag(color: .black).toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"flag\",\"d\":\"black\"}")
    }

    @Test func clientFromEnvelopeRoundTrip() throws {
        let move = try #require(WireCodec.decode("{\"t\":\"move\",\"a\":7,\"d\":{\"u\":\"g1f3\"}}"))
        switch RoundClientMessage.fromEnvelope(move) {
        case .move(let uci, let ackId):
            #expect(uci == "g1f3")
            #expect(ackId == 7)
        default:
            #expect(false, "expected .move")
        }

        let resign = try #require(WireCodec.decode("{\"t\":\"resign\"}"))
        switch RoundClientMessage.fromEnvelope(resign) {
        case .resign(let ackId):
            #expect(ackId == nil)
        default:
            #expect(false, "expected .resign")
        }

        let flag = try #require(WireCodec.decode("{\"t\":\"flag\",\"d\":\"white\"}"))
        switch RoundClientMessage.fromEnvelope(flag) {
        case .flag(let color):
            #expect(color == PieceColor.white)
        default:
            #expect(false, "expected .flag")
        }
    }

    @Test func clientUnknownPassesThrough() throws {
        let env = try #require(WireCodec.decode("{\"t\":\"berserk\"}"))
        switch RoundClientMessage.fromEnvelope(env) {
        case .unknown(let type, _):
            #expect(type == "berserk")
        default:
            #expect(false, "expected .unknown")
        }
    }

    // MARK: - Server → Client

    @Test func serverMoveEncoding() throws {
        let payload = RoundServerMessage.MovePayload(
            uci: "e2e4",
            san: "e4",
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
            ply: 1,
            clock: ClockState(white: 180.5, black: 180.0, lag: 3),
            check: false,
            dests: ["e7": ["e6", "e5"], "g8": ["f6", "h6"]],
        )
        let env = RoundServerMessage.move(payload).toEnvelope()
        // We won't pin the exact string because dictionary ordering is
        // sorted by key, but we can verify key parts.
        let wire = WireCodec.encode(env)
        #expect(wire.hasPrefix("{\"t\":\"move\",\"d\":{"))
        #expect(wire.contains("\"uci\":\"e2e4\""))
        #expect(wire.contains("\"san\":\"e4\""))
        #expect(wire.contains("\"ply\":1"))
        #expect(wire.contains("\"clock\":{\"white\":180.5,\"black\":180"))
        #expect(wire.contains("\"dests\":{\"e7\":[\"e6\",\"e5\"]"))
    }

    @Test func serverMoveWithVersionAndCheck() throws {
        let payload = RoundServerMessage.MovePayload(
            uci: "d1h5",
            fen: "rnbqkbnr/ppp1pppp/8/3p3Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2",
            ply: 3,
            check: true,
        )
        var env = RoundServerMessage.move(payload).toEnvelope()
        env = WireEnvelope(
            type: env.type, data: env.data, version: 3, ackId: env.ackId, lag: env.lag)
        let wire = WireCodec.encode(env)
        #expect(wire.contains("\"v\":3"))
        #expect(wire.contains("\"check\":true"))
    }

    @Test func serverMoveDecoding() throws {
        let raw = "{\"t\":\"move\",\"v\":1,\"d\":{\"uci\":\"e2e4\",\"san\":\"e4\",\"fen\":\"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1\",\"ply\":1,\"check\":false,\"clock\":{\"white\":180,\"black\":180}}}"
        let env = try #require(WireCodec.decode(raw))
        switch RoundServerMessage.fromEnvelope(env) {
        case .move(let payload):
            #expect(payload.uci == "e2e4")
            #expect(payload.san == "e4")
            #expect(payload.ply == 1)
            #expect(payload.check == false)
            #expect(payload.clock?.white == 180.0)
        default:
            #expect(false, "expected .move payload")
        }
    }

    @Test func serverEndDataEncoding() throws {
        let env = RoundServerMessage.endData(.init(winner: PieceColor.white, status: GameStatus.checkmate)).toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"endData\",\"d\":{\"winner\":\"white\",\"status\":\"mate\"}}")

        let drawEnv = RoundServerMessage.endData(.init(winner: nil, status: GameStatus.stalemate)).toEnvelope()
        #expect(WireCodec.encode(drawEnv) == "{\"t\":\"endData\",\"d\":{\"status\":\"stalemate\"}}")
    }

    @Test func serverDrawOfferEncoding() throws {
        let env = RoundServerMessage.drawOffer(by: PieceColor.white).toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"drawOffer\",\"d\":\"white\"}")

        let nilEnv = RoundServerMessage.drawOffer(by: nil).toEnvelope()
        // `.null` data is omitted by the codec.
        #expect(WireCodec.encode(nilEnv) == "{\"t\":\"drawOffer\"}")
    }

    @Test func serverAckEncoding() throws {
        let env = RoundServerMessage.ack(ackId: 42).toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"ack\",\"d\":42}")
    }

    @Test func serverResyncEncoding() throws {
        let env = RoundServerMessage.resync.toEnvelope()
        #expect(WireCodec.encode(env) == "{\"t\":\"resync\"}")
    }

    // MARK: - GameStatus mapping

    @Test func gameStatusFromGameResult() throws {
        #expect(GameStatus.fromGameResult(nil) == nil)
        #expect(GameStatus.fromGameResult(.whiteWins(reason: .checkmate)) == .checkmate)
        #expect(GameStatus.fromGameResult(.blackWins(reason: .checkmate)) == .checkmate)
        #expect(GameStatus.fromGameResult(.draw(reason: .stalemate)) == .stalemate)
        #expect(GameStatus.fromGameResult(.draw(reason: .insufficientMaterial)) == .insufficientMaterial)
        #expect(GameStatus.fromGameResult(.draw(reason: .threefoldRepetition)) == .threefoldRepetition)
        #expect(GameStatus.fromGameResult(.draw(reason: .fiftyMoveRule)) == .fiftyMoves)
    }
}
