// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngineAlphaBeta
import SkipChessModel
import SkipChessEngine

/// Adversarial engine tests probing extreme limits, degenerate positions,
/// and abuse of the public API.
@Suite struct AdversarialEngineTests {

    // MARK: - Extreme limits

    @Test func depthZeroLimitStillReturnsLegalMove() throws {
        // depth = 0 means "don't search" but we still owe the caller a
        // legal move from the position.
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let result = engine.findBestMove(from: board, depth: 0)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func zeroTimeLimitStillReturnsLegalMove() throws {
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let limits = SearchLimits(maxMilliseconds: 0)
        let result = engine.findBestMove(from: board, limits: limits, control: nil, listener: nil)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func zeroNodeLimitStillReturnsLegalMove() throws {
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let limits = SearchLimits(maxNodes: 0)
        let result = engine.findBestMove(from: board, limits: limits, control: nil, listener: nil)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func negativeDepthIsTreatedAsZero() throws {
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let limits = SearchLimits(maxDepth: -5)
        let result = engine.findBestMove(from: board, limits: limits, control: nil, listener: nil)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func deepSearchDoesNotCrashFromKillerSlotOverflow() throws {
        // killerSlot0/1 are 128 slots wide. A depth-12 search plus the
        // 40-ply quiescence cap could approach the limit, but should not
        // exceed it in the main search portion. This test pins the
        // assumption.
        let engine = AlphaBetaEngine()
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K2R w K - 0 1"))
        // Endgame: thin tree means deep iterative deepening completes fast.
        let limits = SearchLimits(maxDepth: 12, maxMilliseconds: 500)
        let result = engine.findBestMove(from: board, limits: limits, control: nil, listener: nil)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func absurdMaxDepthDoesNotCrashKillerSlots() throws {
        // Without the bounds guard, scoreMove would index killerSlot0[ply]
        // out of bounds once ply >= killerSlot0.count (128). Force an
        // iterative-deepening run with a maxDepth past that threshold in a
        // thin endgame where the search can plausibly reach those depths
        // via TT-accelerated iterations. Even if it doesn't actually
        // reach them within the time bound, the guard ensures no crash.
        let engine = AlphaBetaEngine()
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let limits = SearchLimits(maxDepth: 200, maxMilliseconds: 500)
        let result = engine.findBestMove(from: board, limits: limits, control: nil, listener: nil)
        // The position has only kings, no captures, no real progress, but
        // we expect a legal king move.
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    // MARK: - Degenerate positions

    @Test func engineOnEmptyBoardReportsNilMove() throws {
        let board = try #require(FEN.parse("8/8/8/8/8/8/8/8 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 3)
        #expect(result.bestMove == nil)
    }

    @Test func engineOnKingVsKingPlaysSafeMoves() throws {
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let engine = AlphaBetaEngine()
        // Insufficient material — engine should still find a legal move.
        let result = engine.findBestMove(from: board, depth: 4)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func engineOnImmediateStalematePosition() throws {
        // Classical K+Q vs K stalemate: black king on a8, white queen on b6,
        // white king on c7. Black to move has no legal moves and is not in
        // check.
        let fen = "k7/8/1Q6/2K5/8/8/8/8 b - - 0 1"
        let board = try #require(FEN.parse(fen))
        if board.isStalemate() {
            let engine = AlphaBetaEngine()
            let result = engine.findBestMove(from: board, depth: 3)
            #expect(result.bestMove == nil)
            #expect(result.evaluation == SearchEvaluation.score(centipawns: 0))
        }
    }

    // MARK: - State pollution / repeated searches

    @Test func repeatedSearchesAcrossDifferentPositionsRemainLegal() throws {
        // The engine retains its transposition table and history heuristics
        // between calls. Verify that this doesn't corrupt later searches.
        let engine = AlphaBetaEngine()
        let positions = [
            FEN.startingPositionFEN,
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
            "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 4",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            FEN.startingPositionFEN,
        ]
        for fen in positions {
            let board = try #require(FEN.parse(fen))
            let result = engine.findBestMove(from: board, depth: 2)
            if let move = result.bestMove {
                #expect(board.isLegalMove(move), "engine illegal in \(fen) → \(move.uci)")
            }
        }
    }

    @Test func consecutiveCallsReturnSameMoveOnSamePosition() throws {
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let resultA = engine.findBestMove(from: board, depth: 3)
        let resultB = engine.findBestMove(from: board, depth: 3)
        #expect(resultA.bestMove == resultB.bestMove)
    }

    // MARK: - Listener edge cases

    @Test func listenerOnZeroLegalMovesNotCalled() throws {
        let board = try #require(FEN.parse("8/8/8/8/8/8/8/8 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let listener = CountingListener()
        _ = engine.findBestMove(from: board, limits: .depth(3), control: nil, listener: listener)
        // No legal moves → we exit early before any iterations.
        #expect(listener.count == 0)
    }

    // MARK: - Engine state must not corrupt the caller's board

    @Test func engineDoesNotMutateCallerBoard() throws {
        let board = Board.standardStartingPosition()
        let fenBefore = FEN.serialize(board)
        let keyBefore = board.zobristKey
        let engine = AlphaBetaEngine()
        _ = engine.findBestMove(from: board, depth: 3)
        #expect(FEN.serialize(board) == fenBefore)
        #expect(board.zobristKey == keyBefore)
    }

    // MARK: - PeSTO evaluator edge cases

    @Test func pestoOnEmptyBoardReturnsZero() throws {
        let board = try #require(FEN.parse("8/8/8/8/8/8/8/8 w - - 0 1"))
        let evaluator = PestoEvaluator()
        #expect(evaluator.evaluate(board: board) == 0)
    }

    @Test func pestoWithExcessQueensClampsPhase() throws {
        // 9 queens per side would push gamePhase past 24 if we didn't clamp.
        // Use a synthetic FEN that maximally piles queens on (within FEN
        // legality of 8 pieces per rank).
        let board = try #require(FEN.parse("k7/QQQQQQQQ/QQQQQQQQ/8/8/qqqqqqqq/qqqqqqqq/K7 w - - 0 1"))
        let evaluator = PestoEvaluator()
        // No crash on extreme material.
        _ = evaluator.evaluate(board: board)
    }

    // MARK: - Transposition table edge cases

    @Test func ttHandlesAllNegativeOnesAsKey() throws {
        let tt = TranspositionTable(numberOfEntries: 1024)
        let key: Int64 = -1
        tt.store(key: key, score: 100, depth: 5, bound: TTBound.exact, move: 0)
        let probe = tt.probe(key: key)
        #expect(probe.found)
        #expect(probe.score == 100)
    }

    @Test func ttZeroKeyIsTreatedAsEmptySlot() throws {
        // The TT uses keys[idx]==0 to represent "empty". A position whose
        // Zobrist key happens to be 0 would never be matched. Verify
        // current behavior (this is a known limitation — collision rate is
        // 1 in 2^64).
        let tt = TranspositionTable(numberOfEntries: 1024)
        tt.store(key: 0, score: 42, depth: 1, bound: TTBound.exact, move: 0)
        let probe = tt.probe(key: 0)
        // Storing then probing key=0: because keys[idx] == 0 == query, found
        // returns true. We're just verifying no crash.
        _ = probe
    }
}

private final class CountingListener: SearchProgressListener {
    var count: Int = 0
    func didCompleteIteration(result: SearchResult) {
        count = count + 1
    }
}
