// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation
import SkipChessModel

/// A receiver for incremental search updates ("info" lines in UCI parlance).
///
/// Engines call ``didCompleteIteration(result:)`` after each fully-completed
/// search depth. The returned ``SearchResult`` is always usable on its own,
/// so applications that want only the final move can ignore intermediate
/// updates.
public protocol SearchProgressListener {
    /// Called with the best move and evaluation at the end of each completed
    /// depth iteration.
    func didCompleteIteration(result: SearchResult)
}

/// The contract implemented by chess engine strategies.
///
/// `ChessEngine` is the integration point a chess application uses to
/// obtain best-move recommendations. Concrete implementations may differ in
/// search algorithm (alpha-beta, MCTS, neural network, etc.) — see
/// `SkipChessEngineAlphaBeta` for the bundled alpha-beta + PeSTO
/// implementation.
public protocol ChessEngine {

    /// Human-readable name of the engine (e.g. "AlphaBeta PeSTO").
    var name: String { get }

    /// Engine version string.
    var version: String { get }

    /// Performs a search and returns the best move and associated metadata.
    ///
    /// - Parameters:
    ///   - board: The position to search from. The board is not mutated by
    ///     calls to this method; engines typically clone it internally.
    ///   - limits: Search bounds. Engines should respect every active bound
    ///     (depth, time, nodes) and stop at the first one exceeded.
    ///   - control: Optional cooperative cancellation. If supplied, the
    ///     engine polls ``SearchControl/isStopRequested`` periodically and
    ///     stops at the next safe point.
    ///   - listener: Optional progress receiver invoked once per completed
    ///     iteration.
    func findBestMove(
        from board: Board,
        limits: SearchLimits,
        control: SearchControl?,
        listener: SearchProgressListener?
    ) -> SearchResult
}

extension ChessEngine {
    /// Convenience search with no listener or cancellation control.
    public func findBestMove(from board: Board, limits: SearchLimits) -> SearchResult {
        return findBestMove(from: board, limits: limits, control: nil, listener: nil)
    }

    /// Convenience search with a fixed depth limit.
    public func findBestMove(from board: Board, depth: Int) -> SearchResult {
        return findBestMove(from: board, limits: SearchLimits.depth(depth), control: nil, listener: nil)
    }
}
