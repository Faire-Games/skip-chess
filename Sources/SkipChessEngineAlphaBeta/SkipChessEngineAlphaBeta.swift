// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel
import SkipChessEngine

/// `SkipChessEngineAlphaBeta` provides ``AlphaBetaEngine``, a negamax-based
/// chess engine with iterative deepening, a transposition table, killer
/// and history move ordering, MVV-LVA capture ordering, and a quiescence
/// search. Static positions are scored by ``PestoEvaluator`` using the
/// integer tables published at
/// https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function .
public enum SkipChessEngineAlphaBeta {
    public static let version: String = "1.0.0"
}
