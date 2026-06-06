// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessEngineAlphaBeta
import SkipChessModel
import SkipChessEngine

@Suite struct PestoEvaluatorTests {

    @Test func materialValuesMatchPublishedTables() throws {
        // Verbatim from chessprogramming.org PeSTO tables.
        #expect(PestoTables.materialMg == [82, 337, 365, 477, 1025, 0])
        #expect(PestoTables.materialEg == [94, 281, 297, 512, 936, 0])
    }

    @Test func gamePhaseIncrementsMatchTables() throws {
        // From PeSTO: pawn=0, knight=1, bishop=1, rook=2, queen=4, king=0.
        #expect(PestoTables.gamePhaseInc == [0, 1, 1, 2, 4, 0])
        #expect(PestoTables.maxGamePhase == 24)
    }

    @Test func startingPositionIsBalanced() throws {
        let board = Board.standardStartingPosition()
        let evaluator = PestoEvaluator()
        let score = evaluator.evaluate(board: board)
        // Position is symmetric, so the score should be 0 from either side.
        #expect(score == 0)
    }

    @Test func extraQueenIsHugeAdvantage() throws {
        // White has an extra queen; from white's perspective the score
        // should be substantially positive.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/3QK3 w - - 0 1"))
        let evaluator = PestoEvaluator()
        let score = evaluator.evaluate(board: board)
        #expect(score > 500)
    }

    @Test func extraQueenForOpponentIsHugeDisadvantage() throws {
        // Black to move; white has an extra queen — score from black's
        // perspective should be very negative.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/3QK3 b - - 0 1"))
        let evaluator = PestoEvaluator()
        let score = evaluator.evaluate(board: board)
        #expect(score < -500)
    }

    @Test func centralKnightBetterThanCornerKnight() throws {
        // Knight on e4 vs knight on a1 (otherwise symmetric position).
        let center = try #require(FEN.parse("4k3/8/8/8/4N3/8/8/4K3 w - - 0 1"))
        let corner = try #require(FEN.parse("4k3/8/8/8/8/8/8/N3K3 w - - 0 1"))
        let evaluator = PestoEvaluator()
        #expect(evaluator.evaluate(board: center) > evaluator.evaluate(board: corner))
    }

    @Test func mirroredPositionsHaveOppositeSignsFromSideToMove() throws {
        // Same physical position with side to move swapped should give
        // opposite scores.
        let whiteToMove = try #require(FEN.parse("r3k2r/pppqppbp/2n2np1/3p4/3P4/2N2NP1/PPPQPPBP/R3K2R w KQkq - 0 1"))
        let blackToMove = try #require(FEN.parse("r3k2r/pppqppbp/2n2np1/3p4/3P4/2N2NP1/PPPQPPBP/R3K2R b KQkq - 0 1"))
        let evaluator = PestoEvaluator()
        let scoreWhite = evaluator.evaluate(board: whiteToMove)
        let scoreBlack = evaluator.evaluate(board: blackToMove)
        // From white's perspective scoreWhite = X; from black's perspective
        // scoreBlack = -X.
        #expect(scoreWhite == -scoreBlack)
    }

    @Test func whitePawnTableMatchesPestoAtRank7() throws {
        // PeSTO raw value for pawn at index 8 (rank 7 file 0 = a7) is 98.
        // For a white pawn on a7 (our sq=48), we should look up index 8.
        // The precomputed whiteMg[pawnIdx=0][sq=48] should equal rawPawnMg[8] = 98.
        let pawnIdx = PieceKind.pawn.rawValue - 1
        let sq = Square.make(file: 0, rank: 6)  // a7
        #expect(PestoTables.whiteMg[pawnIdx][sq] == 98)
    }

    @Test func blackPawnTableMatchesPestoAtRank2() throws {
        // Symmetric: black pawn on a2 (our sq=8) should also be valued 98
        // in middlegame (about to promote from black's perspective).
        let pawnIdx = PieceKind.pawn.rawValue - 1
        let sq = Square.make(file: 0, rank: 1)  // a2
        #expect(PestoTables.blackMg[pawnIdx][sq] == 98)
    }

    @Test func allTablesHaveSixtyFourEntries() throws {
        for kindIdx in 0..<6 {
            #expect(PestoTables.whiteMg[kindIdx].count == 64)
            #expect(PestoTables.whiteEg[kindIdx].count == 64)
            #expect(PestoTables.blackMg[kindIdx].count == 64)
            #expect(PestoTables.blackEg[kindIdx].count == 64)
        }
    }
}
