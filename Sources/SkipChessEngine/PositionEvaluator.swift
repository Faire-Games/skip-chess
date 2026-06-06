// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation
import SkipChessModel

/// A static evaluator for chess positions.
///
/// `PositionEvaluator` decouples evaluation from search. Engines can pair a
/// search strategy (alpha-beta, MCTS, ...) with an evaluator
/// (material-only, PeSTO, NNUE, etc.) without changing either independently.
///
/// Evaluators must return scores from the perspective of the side to move:
/// positive = good for the side currently to move, negative = bad. Scores
/// are measured in centipawns (100 = one full pawn).
public protocol PositionEvaluator {
    /// Returns a static evaluation of `board` in centipawns from the
    /// perspective of the side to move. The board is not mutated.
    func evaluate(board: Board) -> Int
}

/// A trivial material-only evaluator useful as a baseline for tests and
/// reference implementations of new engines. Material values are the
/// classical "horse-and-buggy" values (P=100, N=320, B=330, R=500, Q=900).
public final class MaterialOnlyEvaluator: PositionEvaluator {

    public static let pawnValue: Int = 100
    public static let knightValue: Int = 320
    public static let bishopValue: Int = 330
    public static let rookValue: Int = 500
    public static let queenValue: Int = 900

    public init() {}

    public func evaluate(board: Board) -> Int {
        var whiteScore = 0
        var blackScore = 0
        for sq in 0..<64 {
            let code = board.squares[sq]
            if code == 0 {
                continue
            }
            let value = MaterialOnlyEvaluator.value(forKind: PieceCode.kind(code))
            if PieceCode.isWhite(code) {
                whiteScore = whiteScore + value
            } else {
                blackScore = blackScore + value
            }
        }
        let diff = whiteScore - blackScore
        // Convert to side-to-move perspective.
        return board.sideToMove == .white ? diff : -diff
    }

    private static func value(forKind kind: Int) -> Int {
        switch kind {
        case 1: return pawnValue
        case 2: return knightValue
        case 3: return bishopValue
        case 4: return rookValue
        case 5: return queenValue
        default: return 0  // king and empty
        }
    }
}
