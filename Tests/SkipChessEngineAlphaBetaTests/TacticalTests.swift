// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngineAlphaBeta
import SkipChessModel
import SkipChessEngine

@Suite struct TacticalTests {

    @Test func mateInOneFromQuiet() throws {
        // White to move, Qxh7#.
        // 6rk/5N1p/8/8/8/8/8/6K1 w - - 0 1 — knight on f7 forks king and rook.
        // Easier: rook on a1 → a8 mate (back rank).
        let board = try #require(FEN.parse("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 4)
        let move = try #require(result.bestMove)
        _ = board.makeMove(move)
        #expect(board.isCheckmate())
    }

    @Test func avoidsStalematingItselfWhenWinning() throws {
        // K+Q vs K — white must not stalemate the lone king. After several
        // engine moves the black king should still have legal moves until
        // mate is delivered.
        let board = try #require(FEN.parse("8/8/8/8/8/3k4/3q4/3K4 b - - 0 1"))
        // It's actually black's turn here and black has a winning K+Q vs K.
        // Run the engine for a few moves and verify it never stalemates.
        let engine = AlphaBetaEngine()
        var stalemated = false
        for _ in 0..<10 {
            if board.isCheckmate() {
                break
            }
            if board.isStalemate() {
                stalemated = true
                break
            }
            let result = engine.findBestMove(from: board, depth: 4)
            guard let move = result.bestMove else {
                break
            }
            #expect(board.isLegalMove(move))
            _ = board.makeMove(move)
            if board.halfmoveClock >= 100 {
                break
            }
        }
        #expect(!stalemated, "engine stalemated the lone king")
    }

    @Test func engineIsDeterministic() throws {
        // Two identical engines from the same position should return the
        // same best move.
        let engineA = AlphaBetaEngine()
        let engineB = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let resultA = engineA.findBestMove(from: board, depth: 3)
        let resultB = engineB.findBestMove(from: board, depth: 3)
        #expect(resultA.bestMove == resultB.bestMove)
    }

    @Test func handlesEndgameKQvsK() throws {
        // White K+Q vs Black K. White's first move should be sensible
        // (improving king position or restricting the black king).
        let board = try #require(FEN.parse("8/8/8/3k4/8/8/8/3QK3 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 4)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func avoidsBlunderInOpening() throws {
        // After 1. e4 e5, white shouldn't play Qh5 hoping for a Scholar's
        // mate trick — the engine should pick a developing move. We're not
        // asserting the specific move, just that it's a legal move and
        // doesn't blunder material.
        let board = Board.standardStartingPosition()
        _ = board.makeMove(Move(from: Square.parse("e2"), to: Square.parse("e4")))
        _ = board.makeMove(Move(from: Square.parse("e7"), to: Square.parse("e5")))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 4)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))

        // Material count before vs after move should be balanced (no piece
        // was lost for nothing).
        let beforeMaterial = whiteMaterial(board: board) - blackMaterial(board: board)
        _ = board.makeMove(move)
        // After best black response too, white shouldn't be down material.
        if let blackResult = engine.findBestMove(from: board, depth: 3).bestMove {
            _ = board.makeMove(blackResult)
        }
        let afterMaterial = whiteMaterial(board: board) - blackMaterial(board: board)
        // We expect roughly the same material (within a small fudge for any
        // equal exchanges the engine might find favorable).
        let delta = afterMaterial - beforeMaterial
        #expect(delta >= -100, "engine blundered material: delta=\(delta)")
    }

    @Test func underpromotionIsLegal() throws {
        // White pawn on a7 can promote to N, B, R, or Q. The promotion to
        // knight is sometimes correct (e.g. for a check that's stronger than
        // queen). Verify that the engine never proposes an illegal
        // underpromotion target.
        let board = try #require(FEN.parse("4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 3)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
        if move.promotion != 0 {
            // Promotion to one of N/B/R/Q only.
            #expect(move.promotion >= PieceKind.knight.rawValue)
            #expect(move.promotion <= PieceKind.queen.rawValue)
        }
    }

    @Test func capturesUndefendedPawn() throws {
        // White knight on c3, black pawn on b5 (undefended). Engine should
        // capture.
        let board = try #require(FEN.parse("4k3/8/8/1p6/8/2N5/8/4K3 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 3)
        let move = try #require(result.bestMove)
        // The engine should grab the free pawn (Nxb5).
        #expect(move.to == Square.parse("b5"))
    }

    @Test func doesNotMoveIntoLossOfMaterial() throws {
        // White knight on d4 has a choice of squares including f5 (safe) and
        // e6 (defended by a pawn — trade for nothing).
        // Position: knight on d4, black pawn on d7 defending e6 / c6.
        let board = try #require(FEN.parse("4k3/3p4/8/8/3N4/8/8/4K3 w - - 0 1"))
        let engine = AlphaBetaEngine()
        let result = engine.findBestMove(from: board, depth: 4)
        let move = try #require(result.bestMove)
        // The knight should NOT move to c6 or e6 where it gets captured.
        if move.from == Square.parse("d4") {
            #expect(move.to != Square.parse("c6"))
            #expect(move.to != Square.parse("e6"))
        }
    }

    // MARK: - Helpers

    private func whiteMaterial(board: Board) -> Int {
        var total = 0
        for sq in 0..<64 {
            let p = board.pieceCode(at: sq)
            if p != 0 && PieceCode.isWhite(p) {
                total = total + pieceValue(of: p)
            }
        }
        return total
    }

    private func blackMaterial(board: Board) -> Int {
        var total = 0
        for sq in 0..<64 {
            let p = board.pieceCode(at: sq)
            if p != 0 && PieceCode.isBlack(p) {
                total = total + pieceValue(of: p)
            }
        }
        return total
    }

    private func pieceValue(of code: Int) -> Int {
        switch PieceCode.kind(code) {
        case 1: return 100
        case 2: return 320
        case 3: return 330
        case 4: return 500
        case 5: return 900
        case 6: return 0
        default: return 0
        }
    }
}
