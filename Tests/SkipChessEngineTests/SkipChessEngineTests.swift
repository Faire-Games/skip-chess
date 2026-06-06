// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import OSLog
import Foundation
@testable import SkipChessEngine
import SkipChessModel

let logger: Logger = Logger(subsystem: "SkipChessEngine", category: "Tests")

@Suite struct SkipChessEngineTests {

    @Test func skipChessEngine() throws {
        logger.log("running testSkipChessEngine")
        #expect(SkipChessEngine.version == "1.0.0")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "SkipChessEngine")
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
