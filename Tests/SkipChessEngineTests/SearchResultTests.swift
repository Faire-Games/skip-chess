// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine
import SkipChessModel

@Suite struct SearchResultTests {

    @Test func evaluationIsMate() throws {
        let normal = SearchEvaluation.score(centipawns: 100)
        let win = SearchEvaluation.mateForCurrentSide(inMoves: 3)
        let loss = SearchEvaluation.mateAgainstCurrentSide(inMoves: 5)
        #expect(!normal.isMate)
        #expect(win.isMate)
        #expect(loss.isMate)
    }

    @Test func evaluationCentipawnApproximation() throws {
        #expect(SearchEvaluation.score(centipawns: 250).centipawnApproximation() == 250)
        #expect(SearchEvaluation.mateForCurrentSide(inMoves: 1).centipawnApproximation() > 0)
        #expect(SearchEvaluation.mateAgainstCurrentSide(inMoves: 1).centipawnApproximation() < 0)
    }

    @Test func searchInfoNodesPerSecond() throws {
        let info = SearchInfo(depth: 5, selectiveDepth: 10, nodesSearched: 1_000_000, elapsedMilliseconds: 1000)
        #expect(info.nodesPerSecond == 1_000_000)
    }

    @Test func searchInfoZeroTime() throws {
        let info = SearchInfo(depth: 5, selectiveDepth: 10, nodesSearched: 1000, elapsedMilliseconds: 0)
        #expect(info.nodesPerSecond == 0)
    }

    @Test func searchResultConstruction() throws {
        let move = Move(from: Square.parse("e2"), to: Square.parse("e4"))
        let info = SearchInfo(depth: 4, selectiveDepth: 6, nodesSearched: 10000, elapsedMilliseconds: 100)
        let result = SearchResult(
            bestMove: move,
            evaluation: SearchEvaluation.score(centipawns: 25),
            principalVariation: [move],
            info: info
        )
        #expect(result.bestMove == move)
        #expect(result.evaluation == SearchEvaluation.score(centipawns: 25))
        #expect(result.principalVariation.count == 1)
        #expect(result.info.depth == 4)
    }
}
