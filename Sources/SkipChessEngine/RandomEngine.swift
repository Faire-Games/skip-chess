// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel

/// A reference ``ChessEngine`` that picks a uniformly random legal move.
/// Useful as a sanity check and as a lower bound when benchmarking other
/// engines. **Not** suitable for play against a human past beginner level.
public final class RandomEngine: ChessEngine {

    public let name: String = "Random"
    public let version: String = "1.0.0"

    /// Optional deterministic seed (useful for tests). When `nil`, the
    /// engine uses ``Int64`` time-based randomness so successive moves
    /// differ.
    public let seed: Int64?

    private var rngState: Int64

    public init(seed: Int64? = nil) {
        self.seed = seed
        if let s = seed {
            self.rngState = s == Int64(0) ? Int64(1) : s
        } else {
            // Use a fixed default seed when none provided so behavior is
            // reproducible by default. Tests can supply a different seed.
            self.rngState = 0x6A09E667
        }
    }

    public func findBestMove(
        from board: Board,
        limits: SearchLimits,
        control: SearchControl?,
        listener: SearchProgressListener?
    ) -> SearchResult {
        let _ = limits  // limits are ignored — search is instantaneous.
        let _ = control

        let moves = board.legalMoves()
        if moves.isEmpty {
            let evaluation: SearchEvaluation
            if board.isCheck() {
                evaluation = SearchEvaluation.mateAgainstCurrentSide(inMoves: 0)
            } else {
                evaluation = SearchEvaluation.score(centipawns: 0)
            }
            let info = SearchInfo(depth: 0, selectiveDepth: 0, nodesSearched: 0, elapsedMilliseconds: 0)
            let result = SearchResult(bestMove: nil, evaluation: evaluation, principalVariation: [], info: info)
            listener?.didCompleteIteration(result: result)
            return result
        }
        let index = Int(nextRandom() % Int64(moves.count))
        let chosen = moves[index < 0 ? -index : index]
        let evaluation = SearchEvaluation.score(centipawns: 0)
        let info = SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: Int64(moves.count), elapsedMilliseconds: 0)
        let result = SearchResult(bestMove: chosen, evaluation: evaluation, principalVariation: [chosen], info: info)
        listener?.didCompleteIteration(result: result)
        return result
    }

    private func nextRandom() -> Int64 {
        var s = rngState
        s = s ^ (s << 13)
        s = s ^ (s >> 7)
        s = s ^ (s << 17)
        rngState = s
        return s
    }
}
