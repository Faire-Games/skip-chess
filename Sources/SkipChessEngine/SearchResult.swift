// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel

/// The evaluation reported by a search.
///
/// Centipawn values are signed and reported from the perspective of the
/// side to move at the root of the search: positive = good for side to
/// move, negative = bad. Forced mates use a dedicated case so callers can
/// distinguish them from large numeric scores.
public enum SearchEvaluation: Hashable, Sendable {
    /// Centipawn evaluation (100 = one pawn advantage).
    case score(centipawns: Int)
    /// Mate is forced in `inMoves` full moves (positive = current side wins).
    case mateForCurrentSide(inMoves: Int)
    /// Mate is forced against `inMoves` full moves (current side will be mated).
    case mateAgainstCurrentSide(inMoves: Int)

    /// `true` if the evaluation represents a forced mate (for or against).
    public var isMate: Bool {
        switch self {
        case .score: return false
        case .mateForCurrentSide, .mateAgainstCurrentSide: return true
        }
    }

    /// Centipawn approximation: returns the actual score for ``score`` and
    /// a large clamped value for mate scores.
    public func centipawnApproximation() -> Int {
        switch self {
        case .score(let cp): return cp
        case .mateForCurrentSide: return 30000
        case .mateAgainstCurrentSide: return -30000
        }
    }
}

/// Statistics about a completed (or in-progress) search.
public struct SearchInfo: Sendable {
    /// Plies of the main search (excluding extensions / quiescence).
    public let depth: Int
    /// Maximum ply reached including extensions and quiescence search.
    public let selectiveDepth: Int
    /// Total number of positions visited during the search.
    public let nodesSearched: Int64
    /// Wall-clock duration of the search in milliseconds.
    public let elapsedMilliseconds: Int64

    public init(depth: Int, selectiveDepth: Int, nodesSearched: Int64, elapsedMilliseconds: Int64) {
        self.depth = depth
        self.selectiveDepth = selectiveDepth
        self.nodesSearched = nodesSearched
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// Nodes-per-second, or 0 if no time has elapsed.
    public var nodesPerSecond: Int64 {
        if elapsedMilliseconds <= 0 {
            return 0
        }
        return (nodesSearched * 1000) / elapsedMilliseconds
    }
}

/// Result of a chess engine search.
public struct SearchResult: Sendable {

    /// The best move the engine found, or `nil` if no legal move exists
    /// (i.e. the position is a checkmate or stalemate).
    public let bestMove: Move?

    /// The evaluation of the position from the perspective of the side to
    /// move at the root.
    public let evaluation: SearchEvaluation

    /// The principal variation: the line of play the engine expects from
    /// both sides starting at the root position. The first element is the
    /// same move as ``bestMove`` when a move exists.
    public let principalVariation: [Move]

    /// Search statistics.
    public let info: SearchInfo

    public init(bestMove: Move?, evaluation: SearchEvaluation, principalVariation: [Move], info: SearchInfo) {
        self.bestMove = bestMove
        self.evaluation = evaluation
        self.principalVariation = principalVariation
        self.info = info
    }
}
