// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine
import SkipChessModel

@Suite struct SkipChessEngineTests {

    @Test func skipChessEngine() throws {
        #expect(SkipChessEngine.version == "1.0.0")
    }
}
