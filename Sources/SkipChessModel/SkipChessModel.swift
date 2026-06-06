// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0


/// The `SkipChessModel` module provides a complete model of the rules of
/// chess: piece encodings, board state, FEN serialization, move generation
/// covering every legal-move rule (including castling, en passant, pawn
/// promotion, threefold repetition, fifty-move rule, and insufficient
/// material), plus undoable move application via Zobrist-keyed positions.
///
/// The model is designed to be a foundation for a chess engine and uses
/// compact integer encodings on a flat 64-square ``Board`` so the inner
/// loops of move generation and search remain free of object allocations
/// after transpiling to Kotlin.
public enum SkipChessModel {
    public static let version: String = "1.0.0"
}
