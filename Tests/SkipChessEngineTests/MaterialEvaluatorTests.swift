// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessEngine
import SkipChessModel

@Suite struct MaterialEvaluatorTests {

    @Test func startingPositionIsBalanced() throws {
        let board = Board.standardStartingPosition()
        let evaluator = MaterialOnlyEvaluator()
        #expect(evaluator.evaluate(board: board) == 0)
    }

    @Test func extraQueenForCurrentSide() throws {
        // White to move, white has an extra queen.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/3QK3 w - - 0 1"))
        let evaluator = MaterialOnlyEvaluator()
        let score = evaluator.evaluate(board: board)
        #expect(score == MaterialOnlyEvaluator.queenValue)
    }

    @Test func extraQueenAgainstCurrentSide() throws {
        // Black to move, white has an extra queen — score should be -Q for
        // black.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/3QK3 b - - 0 1"))
        let evaluator = MaterialOnlyEvaluator()
        let score = evaluator.evaluate(board: board)
        #expect(score == -MaterialOnlyEvaluator.queenValue)
    }

    @Test func materialValuesAreClassical() throws {
        #expect(MaterialOnlyEvaluator.pawnValue == 100)
        #expect(MaterialOnlyEvaluator.knightValue == 320)
        #expect(MaterialOnlyEvaluator.bishopValue == 330)
        #expect(MaterialOnlyEvaluator.rookValue == 500)
        #expect(MaterialOnlyEvaluator.queenValue == 900)
    }
}
