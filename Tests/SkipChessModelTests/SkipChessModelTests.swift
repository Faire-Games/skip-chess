// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

@Suite struct SkipChessModelTests {

    @Test func skipChessModel() throws {
        #expect(SkipChessModel.version == "1.0.0")
    }
}
