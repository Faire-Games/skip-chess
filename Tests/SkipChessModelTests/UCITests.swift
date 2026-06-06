// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessModel

@Suite struct UCITests {

    @Test func uciRoundTripNonPromotion() throws {
        let moves = ["e2e4", "g1f3", "a1h8", "h1a8", "e1g1"]
        for uci in moves {
            let m = try #require(Move.fromUCI(uci))
            #expect(m.uci == uci)
        }
    }

    @Test func uciRoundTripPromotion() throws {
        let moves = ["a7a8q", "a7a8r", "a7a8b", "a7a8n"]
        for uci in moves {
            let m = try #require(Move.fromUCI(uci))
            #expect(m.uci == uci)
        }
    }

    @Test func uciInvalidStringsReturnNil() throws {
        #expect(Move.fromUCI("") == nil)
        #expect(Move.fromUCI("e2") == nil)
        #expect(Move.fromUCI("e2e44") == nil)
        #expect(Move.fromUCI("i2i4") == nil)
        #expect(Move.fromUCI("a7a8x") == nil)
    }

    @Test func uciIsCaseInsensitive() throws {
        let m1 = try #require(Move.fromUCI("E2E4"))
        let m2 = try #require(Move.fromUCI("e2e4"))
        #expect(m1 == m2)
    }
}
