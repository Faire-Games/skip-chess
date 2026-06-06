// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation
import SkipChessModel

/// The `SkipChessEngine` module declares the generic contract for chess
/// engine implementations. Concrete engines (such as
/// `SkipChessEngineAlphaBeta`) plug into the same ``ChessEngine`` protocol
/// so that applications can swap or compare strategies without touching
/// their UI/game-loop code.
///
/// To implement a custom engine, conform to ``ChessEngine`` and return a
/// ``SearchResult`` that describes the engine's chosen move, evaluation,
/// principal variation, and search statistics. See ``RandomEngine`` for a
/// minimal reference implementation.
public enum SkipChessEngine {
    public static let version: String = "1.0.0"
}
