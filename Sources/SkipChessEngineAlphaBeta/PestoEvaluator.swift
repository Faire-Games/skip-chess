// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel
import SkipChessEngine

/// PeSTO-style tapered evaluator.
///
/// The evaluator walks the 64-square board once, accumulating separate
/// middlegame and endgame scores for both sides as well as a "game phase"
/// counter based on the remaining major and minor material. The final score
/// linearly interpolates between the middlegame and endgame totals, then is
/// returned from the perspective of the side to move (positive = good for
/// the side currently to move).
public final class PestoEvaluator: PositionEvaluator {

    public init() {}

    public func evaluate(board: Board) -> Int {
        var mgWhite = 0
        var egWhite = 0
        var mgBlack = 0
        var egBlack = 0
        var gamePhase = 0

        let materialMg = PestoTables.materialMg
        let materialEg = PestoTables.materialEg
        let gamePhaseInc = PestoTables.gamePhaseInc
        let whiteMg = PestoTables.whiteMg
        let whiteEg = PestoTables.whiteEg
        let blackMg = PestoTables.blackMg
        let blackEg = PestoTables.blackEg

        for sq in 0..<64 {
            let code = board.squares[sq]
            if code == 0 {
                continue
            }
            let kind = PieceCode.kind(code)
            let kindIdx = kind - 1
            gamePhase = gamePhase + gamePhaseInc[kindIdx]
            if PieceCode.isWhite(code) {
                mgWhite = mgWhite + materialMg[kindIdx] + whiteMg[kindIdx][sq]
                egWhite = egWhite + materialEg[kindIdx] + whiteEg[kindIdx][sq]
            } else {
                mgBlack = mgBlack + materialMg[kindIdx] + blackMg[kindIdx][sq]
                egBlack = egBlack + materialEg[kindIdx] + blackEg[kindIdx][sq]
            }
        }

        let mgScore = mgWhite - mgBlack
        let egScore = egWhite - egBlack
        // Clamp game phase in case of early promotion to many queens.
        var mgPhase = gamePhase
        if mgPhase > PestoTables.maxGamePhase {
            mgPhase = PestoTables.maxGamePhase
        }
        let egPhase = PestoTables.maxGamePhase - mgPhase
        let blended = (mgScore * mgPhase + egScore * egPhase) / PestoTables.maxGamePhase

        // Return from side-to-move perspective: positive = good for mover.
        return board.sideToMove == .white ? blended : -blended
    }
}
