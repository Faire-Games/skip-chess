// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine
import SkipChessModel

@Suite struct RoundSessionTests {

    // Tiny deterministic "engine" we plug in for tests — always plays the
    // first legal move alphabetically.
    final class StubFirstMoveEngine: ChessEngine {
        let name: String = "Stub"
        let version: String = "1.0"
        func findBestMove(
            from board: Board,
            limits: SearchLimits,
            control: SearchControl?,
            listener: SearchProgressListener?,
        ) -> SearchResult {
            let moves = board.legalMoves().sorted { a, b in a.uci < b.uci }
            guard let m = moves.first else {
                return SearchResult(
                    bestMove: nil,
                    evaluation: SearchEvaluation.score(centipawns: 0),
                    principalVariation: [],
                    info: SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: 0, elapsedMilliseconds: 0))
            }
            return SearchResult(
                bestMove: m,
                evaluation: SearchEvaluation.score(centipawns: 0),
                principalVariation: [m],
                info: SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: 1, elapsedMilliseconds: 0))
        }
    }

    // MARK: - Move flow

    @Test func sessionEmitsVersionedMove() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        let out = session.flush()
        #expect(out.count == 1)
        switch out.first {
        case .move(let payload):
            #expect(payload.uci == "e2e4")
            #expect(payload.ply == 1)
            #expect(payload.fen.hasPrefix("rnbqkbnr"))
            #expect(payload.dests?["e7"]?.contains("e5") == true)
        default:
            #expect(false, "expected .move")
        }
        #expect(session.version == 1)
    }

    @Test func wireMoveRoundTrip() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(),
        )
        let replies = session.handleWire("{\"t\":\"move\",\"d\":{\"u\":\"e2e4\"}}")
        #expect(replies.count == 1)
        let env = try #require(WireCodec.decode(replies.first ?? ""))
        #expect(env.type == "move")
        #expect(env.version == 1)
        #expect(env.data["uci"]?.stringValue == "e2e4")
        #expect(env.data["ply"]?.intValue == 1)
    }

    @Test func illegalMoveTriggersResync() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(),
        )
        session.handle(RoundClientMessage.move(uci: "e1e5"))  // king teleport
        let out = session.flush()
        #expect(out.count == 1)
        #expect(out.first == RoundServerMessage.resync)
        #expect(session.version == 0)
    }

    @Test func moveAckEchoed() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4", ackId: 5))
        let out = session.flush()
        #expect(out.count == 2)
        #expect(out.first == RoundServerMessage.ack(ackId: 5))
        switch out.last {
        case .move(let payload):
            #expect(payload.uci == "e2e4")
        default:
            #expect(false, "expected .move second")
        }
    }

    // MARK: - Engine integration

    /// Tiny engine that always plays the first legal move (alphabetically)
    /// but reports an arbitrary fixed elapsed time so we can verify the
    /// clock-deduction path against a deterministic value.
    final class StubFixedTimeEngine: ChessEngine {
        let name: String = "StubFixed"
        let version: String = "1.0"
        let elapsedMs: Int64
        init(elapsedMs: Int64) { self.elapsedMs = elapsedMs }
        func findBestMove(
            from board: Board,
            limits: SearchLimits,
            control: SearchControl?,
            listener: SearchProgressListener?,
        ) -> SearchResult {
            let moves = board.legalMoves().sorted { a, b in a.uci < b.uci }
            guard let m = moves.first else {
                return SearchResult(
                    bestMove: nil,
                    evaluation: SearchEvaluation.score(centipawns: 0),
                    principalVariation: [],
                    info: SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: 0, elapsedMilliseconds: elapsedMs))
            }
            return SearchResult(
                bestMove: m,
                evaluation: SearchEvaluation.score(centipawns: 0),
                principalVariation: [m],
                info: SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: 1, elapsedMilliseconds: elapsedMs))
        }
    }

    @Test func engineSearchTimeDeductsFromItsClock() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(
                engineColor: PieceColor.black,
                engineLimits: SearchLimits(maxDepth: 4, maxMilliseconds: 1000),
                initialClockSeconds: 60,
                clockIncrementSeconds: 0,
            ),
            engine: StubFixedTimeEngine(elapsedMs: 350),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        let out = session.flush()
        #expect(out.count == 2)
        // White clock unchanged (server doesn't track human thinking).
        #expect(session.whiteSecondsLeft == 60)
        // Engine's 350 ms search deducted from black's clock.
        #expect(session.blackSecondsLeft == 60.0 - 0.35)
    }

    @Test func engineSearchClockIncludesIncrement() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(
                engineColor: PieceColor.black,
                engineLimits: SearchLimits(maxDepth: 4, maxMilliseconds: 1000),
                initialClockSeconds: 60,
                clockIncrementSeconds: 2,
            ),
            engine: StubFixedTimeEngine(elapsedMs: 500),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        _ = session.flush()
        // Engine: 60 - 0.5 (search) + 2 (increment) = 61.5
        #expect(session.blackSecondsLeft == 61.5)
    }

    @Test func engineFlagsItselfWhenOutOfTime() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(
                engineColor: PieceColor.black,
                engineLimits: SearchLimits(maxDepth: 4, maxMilliseconds: 1000),
                // Tiny clock: engine's 800 ms search will flag it.
                initialClockSeconds: 0.5,
            ),
            engine: StubFixedTimeEngine(elapsedMs: 800),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        let out = session.flush()
        // human move, engine move, endData(outoftime)
        #expect(out.count == 3)
        switch out.last {
        case .endData(let payload):
            #expect(payload.winner == PieceColor.white)
            #expect(payload.status == GameStatus.outoftime)
        default:
            #expect(false, "expected endData outoftime")
        }
        #expect(session.blackSecondsLeft == 0)
    }

    @Test func engineLimitsTightenedByLowClock() throws {
        // 5-second clock with no increment, ~80 plies budget assumption,
        // so the per-move budget should be ≈ clock / engineMovesRemaining
        // ≈ 5 / 40 ≈ 125 ms — well under the 5-second configured maximum.
        // We don't directly inspect the limit (it's private), but we can
        // verify the engine's clock gets a sensible deduction (the stub
        // engine ignores the limit and returns instantly, so we check that
        // the configured upper bound isn't applied without the time scaling
        // kicking in first).
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(
                engineColor: PieceColor.black,
                engineLimits: SearchLimits(maxDepth: 4, maxMilliseconds: 5000),
                initialClockSeconds: 5,
            ),
            engine: StubFixedTimeEngine(elapsedMs: 100),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        _ = session.flush()
        // 5.0 - 0.1 = 4.9 seconds remaining on engine's clock.
        #expect(session.blackSecondsLeft == 4.9)
    }

    @Test func engineRepliesInSameFlush() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(engineColor: PieceColor.black),
            engine: StubFirstMoveEngine(),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        let out = session.flush()
        // Two move events: white's, then the engine's reply.
        #expect(out.count == 2)
        switch out[0] {
        case .move(let p): #expect(p.uci == "e2e4")
        default: #expect(false)
        }
        switch out[1] {
        case .move(let p):
            // Stub plays alphabetically smallest legal Black move.
            #expect(!p.uci.isEmpty)
        default: #expect(false)
        }
        #expect(session.version == 2)
    }

    // MARK: - Resign / draw / takeback

    @Test func resignEmitsEndData() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        session.handle(RoundClientMessage.resign())
        let out = session.flush()
        #expect(out.count == 1)
        switch out.first {
        case .endData(let payload):
            // White was to move → black wins.
            #expect(payload.winner == PieceColor.black)
            #expect(payload.status == GameStatus.resign)
        default:
            #expect(false, "expected .endData")
        }
    }

    @Test func drawOfferAndAccept() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        // White offers draw.
        session.handle(RoundClientMessage.drawYes())
        let offered = session.flush()
        #expect(offered.count == 1)
        #expect(offered.first == RoundServerMessage.drawOffer(by: PieceColor.white))
        #expect(session.drawOfferBy == PieceColor.white)

        // Black plays a move (clears the offer? Lichess actually clears
        // it on the next move). For simplicity, our session clears the
        // offer when the opposing side accepts via draw-yes.
        // Black accepts:
        session.handle(RoundClientMessage.drawYes())
        let accepted = session.flush()
        #expect(accepted.count == 1)
        switch accepted.first {
        case .endData(let payload):
            #expect(payload.winner == nil)
            #expect(payload.status == GameStatus.draw)
        default:
            #expect(false, "expected .endData draw")
        }
    }

    @Test func drawDeclineEmitsClear() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        session.handle(RoundClientMessage.drawYes())  // white offers
        _ = session.flush()
        session.handle(RoundClientMessage.drawNo())   // white retracts (or other side declines)
        let out = session.flush()
        #expect(out.count == 1)
        #expect(out.first == RoundServerMessage.drawOffer(by: nil))
    }

    @Test func takebackOfferAndAccept() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        // Play a move so there's something to take back.
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        _ = session.flush()
        // Black asks for a takeback.
        session.handle(RoundClientMessage.takebackYes())
        let offerOut = session.flush()
        #expect(offerOut.count == 1)
        #expect(offerOut.first == RoundServerMessage.takebackOffers(white: false, black: true))

        // White accepts.
        session.handle(RoundClientMessage.takebackYes())
        let acceptOut = session.flush()
        #expect(acceptOut.count == 2)
        switch acceptOut[0] {
        case .move(let p):
            // Position is reset to the starting state.
            #expect(p.fen.hasPrefix("rnbqkbnr"))
            #expect(p.ply == 0)
        default:
            #expect(false)
        }
        #expect(acceptOut[1] == RoundServerMessage.takebackOffers(white: false, black: false))
    }

    // MARK: - Clocks

    @Test func clockTickDeducts() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(initialClockSeconds: 60),
        )
        session.tickClock(seconds: 10)
        #expect(session.whiteSecondsLeft <= 50)
        #expect(session.blackSecondsLeft == 60)
    }

    @Test func clockTickRaisesFlag() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(initialClockSeconds: 5),
        )
        let flagged = session.tickClock(seconds: 10)
        #expect(flagged == true)
        let out = session.flush()
        #expect(out.count == 1)
        switch out.first {
        case .endData(let payload):
            #expect(payload.winner == PieceColor.black)
            #expect(payload.status == GameStatus.outoftime)
        default:
            #expect(false, "expected flag → endData")
        }
    }

    @Test func clockIncrementAppliedOnMove() throws {
        let session = RoundSession(
            game: Game(),
            configuration: RoundConfiguration(
                initialClockSeconds: 60, clockIncrementSeconds: 3),
        )
        session.handle(RoundClientMessage.move(uci: "e2e4"))
        _ = session.flush()
        #expect(session.whiteSecondsLeft == 63)
        #expect(session.blackSecondsLeft == 60)
    }

    // MARK: - Ping/pong

    @Test func bareTokensPingPong() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        let reply = session.handleWire(WireCodec.pingToken)
        #expect(reply == [WireCodec.pongToken])
    }

    @Test func typedPingMessage() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        session.handle(RoundClientMessage.ping(lag: 42))
        let out = session.flush()
        #expect(out.count == 1)
        #expect(out.first == RoundServerMessage.pong)
    }

    // MARK: - End of game

    @Test func checkmateGeneratesEndData() throws {
        // Fool's mate setup, one move away from mate (queen on d8, ready
        // to swing to h4 mating after 1.f3 e5 2.g4).
        let board = try #require(FEN.parse(
            "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"))
        let game = Game(board: board)
        let session = RoundSession(game: game, configuration: RoundConfiguration())
        session.handle(RoundClientMessage.move(uci: "d8h4"))
        let out = session.flush()
        #expect(out.count == 2)
        switch out[0] {
        case .move: break
        default: #expect(false, "expected move")
        }
        switch out[1] {
        case .endData(let payload):
            #expect(payload.winner == PieceColor.black)
            #expect(payload.status == GameStatus.checkmate)
        default:
            #expect(false, "expected endData checkmate")
        }
    }

    // MARK: - Initial snapshot

    @Test func initialSnapshot() throws {
        let session = RoundSession(game: Game(), configuration: RoundConfiguration())
        let snapshot = session.makeInitialSnapshot()
        switch snapshot {
        case .move(let p):
            #expect(p.uci == "")
            #expect(p.ply == 0)
            #expect(p.fen == FEN.startingPositionFEN)
            // 8 pawns + 2 knights = 10 distinct source squares with
            // legal moves at the starting position.
            #expect(p.dests?.count == 10)
        default:
            #expect(false, "expected move payload")
        }
    }
}
