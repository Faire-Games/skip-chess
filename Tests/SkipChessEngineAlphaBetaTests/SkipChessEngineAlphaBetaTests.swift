// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngineAlphaBeta
import SkipChessModel
import SkipChessEngine

@Suite struct SkipChessEngineAlphaBetaTests {

    @Test func skipChessEngineAlphaBeta() throws {
        #expect(SkipChessEngineAlphaBeta.version == "1.0.0")
    }
}
