// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation

@_exported import SkipChessModel
@_exported import SkipChessEngine
@_exported import SkipChessEngineAlphaBeta

/// `SkipChess` is the umbrella module that re-exports the three constituent
/// SkipChess modules in one import:
///
/// * `SkipChessModel` — chess rules, board state, move generation, FEN.
/// * `SkipChessEngine` — generic protocols for plug-in engines.
/// * `SkipChessEngineAlphaBeta` — bundled alpha-beta + PeSTO engine.
///
/// Most applications only need `import SkipChess` to access every public
/// type from any of the three modules.
public enum SkipChess {
    public static let version: String = "1.0.0"
}
