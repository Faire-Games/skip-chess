// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import OSLog
import Foundation
@testable import SkipChessEngineAlphaBeta
import SkipChessModel
import SkipChessEngine

let logger: Logger = Logger(subsystem: "SkipChessEngineAlphaBeta", category: "Tests")

@Suite struct SkipChessEngineAlphaBetaTests {

    @Test func skipChessEngineAlphaBeta() throws {
        logger.log("running testSkipChessEngineAlphaBeta")
        #expect(SkipChessEngineAlphaBeta.version == "1.0.0")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "SkipChessEngineAlphaBeta")
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
