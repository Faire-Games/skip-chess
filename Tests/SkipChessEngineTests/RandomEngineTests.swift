// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessEngine
import SkipChessModel

@Suite struct RandomEngineTests {

    @Test func returnsLegalMoveFromStartingPosition() throws {
        let engine = RandomEngine(seed: 1)
        let board = Board.standardStartingPosition()
        let result = engine.findBestMove(from: board, depth: 1)
        let bestMove = try #require(result.bestMove)
        #expect(board.isLegalMove(bestMove))
    }

    @Test func returnsNilForCheckmate() throws {
        // Fool's Mate position — black has just delivered mate.
        let board = try #require(FEN.parse("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"))
        #expect(board.isCheckmate())
        let engine = RandomEngine(seed: 1)
        let result = engine.findBestMove(from: board, depth: 1)
        #expect(result.bestMove == nil)
    }

    @Test func seededEngineIsDeterministic() throws {
        let board = Board.standardStartingPosition()
        let engineA = RandomEngine(seed: 42)
        let engineB = RandomEngine(seed: 42)
        let resultA = engineA.findBestMove(from: board, depth: 1)
        let resultB = engineB.findBestMove(from: board, depth: 1)
        #expect(resultA.bestMove == resultB.bestMove)
    }

    @Test func engineProtocolMetadata() throws {
        let engine = RandomEngine()
        #expect(engine.name == "Random")
        #expect(engine.version == "1.0.0")
    }

    @Test func managedMoveOverManyPositions() throws {
        let engine = RandomEngine(seed: 7)
        let board = Board.standardStartingPosition()
        // Make many random moves; engine should always return a legal move.
        for _ in 0..<50 {
            let moves = board.legalMoves()
            if moves.isEmpty {
                break
            }
            let result = engine.findBestMove(from: board, depth: 1)
            let bestMove = try #require(result.bestMove)
            #expect(board.isLegalMove(bestMove))
            _ = board.makeMove(bestMove)
            // Stop if game over.
            if board.isCheckmate() || board.isStalemate() {
                break
            }
            if board.halfmoveClock >= 100 {
                break
            }
        }
    }
}
