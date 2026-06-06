// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChess
import SkipChessModel
import SkipChessEngine
import SkipChessEngineAlphaBeta

@Suite struct SkipChessTests {

    @Test func skipChess() throws {
        #expect(SkipChess.version == "1.0.0")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "SkipChess")
    }

    @Test func umbrellaReExportsModelTypes() throws {
        // Verify that types from SkipChessModel are accessible via just
        // importing SkipChess.
        let board = Board.standardStartingPosition()
        #expect(board.sideToMove == .white)
        let move = try #require(Move.fromUCI("e2e4"))
        #expect(board.isLegalMove(move))
    }

    @Test func umbrellaReExportsEngineTypes() throws {
        // Verify that types from SkipChessEngine are accessible.
        let evaluator = MaterialOnlyEvaluator()
        let board = Board.standardStartingPosition()
        #expect(evaluator.evaluate(board: board) == 0)
        let limits = SearchLimits.depth(2)
        #expect(limits.maxDepth == 2)
    }

    @Test func umbrellaReExportsAlphaBetaTypes() throws {
        // Verify the alpha-beta engine is reachable through SkipChess.
        let engine = AlphaBetaEngine()
        let board = Board.standardStartingPosition()
        let result = engine.findBestMove(from: board, depth: 2)
        let move = try #require(result.bestMove)
        #expect(board.isLegalMove(move))
    }

    @Test func endToEndShortGame() throws {
        // Drive a short engine-vs-engine game through the umbrella module:
        // this exercises every module at once.
        let game = Game()
        let white = AlphaBetaEngine()
        let black = AlphaBetaEngine()
        var halfMovesPlayed = 0
        for _ in 0..<20 {
            if game.board.isCheckmate() || game.board.isStalemate() {
                break
            }
            let engine: ChessEngine = game.board.sideToMove == PieceColor.white ? white : black
            let result = engine.findBestMove(from: game.board, depth: 2)
            let move = try #require(result.bestMove)
            #expect(game.play(move))
            halfMovesPlayed = halfMovesPlayed + 1
        }
        #expect(halfMovesPlayed > 0)
        #expect(game.moveHistory.count == halfMovesPlayed)
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
